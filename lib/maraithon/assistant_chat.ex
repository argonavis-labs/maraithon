defmodule Maraithon.AssistantChat do
  @moduledoc """
  Surface-neutral assistant chat entrypoint for native mobile.
  """

  alias Maraithon.Repo
  alias Maraithon.AssistantChat.{DirectIntent, SecretRequestGuard, ThreadNaming}
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.ModelRouting
  alias Maraithon.TelegramAssistant.{PreparedAction, Run, Runner}
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.{Conversation, Turn}

  @max_message_bytes 16_384
  @max_thread_title_bytes 160

  def list_threads(user_id, opts \\ []) when is_binary(user_id) do
    {:ok, TelegramConversations.list_mobile_threads(user_id, opts)}
  end

  def create_thread(user_id, attrs \\ %{}) when is_binary(user_id) and is_map(attrs) do
    with {:ok, title} <- thread_title(attrs, default: ThreadNaming.default_title()) do
      TelegramConversations.create_mobile_thread(user_id, Map.put(attrs, "title", title))
    end
  end

  def get_thread(user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    case TelegramConversations.get_mobile_thread(user_id, thread_id) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :not_found}
    end
  end

  def update_thread(user_id, thread_id, attrs)
      when is_binary(user_id) and is_binary(thread_id) and is_map(attrs) do
    with %Conversation{} = conversation <-
           TelegramConversations.get_mobile_thread(user_id, thread_id),
         {:ok, title} <- thread_title(attrs),
         {:ok, updated_conversation} <-
           TelegramConversations.update_metadata(conversation, %{"title" => title}) do
      {:ok, reload_thread(updated_conversation)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_message(user_id, thread_id, message_id)
      when is_binary(user_id) and is_binary(thread_id) and is_binary(message_id) do
    with %Conversation{} = conversation <-
           TelegramConversations.get_mobile_thread(user_id, thread_id),
         nil <- TelegramConversations.active_run_for_conversation(conversation.id),
         {:ok, updated_conversation} <-
           TelegramConversations.delete_turn(conversation, message_id) do
      {:ok, reload_thread(updated_conversation)}
    else
      %Run{} -> {:error, :assistant_run_in_progress}
      nil -> {:error, :not_found}
      {:error, :not_found} -> {:error, :message_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_message(user_id, thread_id, attrs)
      when is_binary(user_id) and is_binary(thread_id) and is_map(attrs) do
    with %Conversation{} = conversation <-
           TelegramConversations.get_mobile_thread(user_id, thread_id),
         {:ok, body} <- message_body(attrs),
         {:ok, client_message_id} <- client_message_id(attrs) do
      case TelegramConversations.find_turn_by_client_message_id(
             conversation.id,
             client_message_id
           ) do
        %Turn{} = existing ->
          {:ok,
           %{
             thread: reload_thread(conversation),
             run: TelegramConversations.latest_run_for_conversation(conversation.id),
             message: existing,
             duplicate?: true
           }}

        nil ->
          case TelegramConversations.active_run_for_conversation(conversation.id) do
            %Run{} = run ->
              {:error, :assistant_run_in_progress, run, reload_thread(conversation)}

            nil ->
              insert_message_and_run(conversation, body, client_message_id)
          end
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_run(user_id, run_id) when is_binary(user_id) and is_binary(run_id) do
    case Repo.get_by(Run, id: run_id, user_id: user_id, surface: "mobile") do
      %Run{} = run -> {:ok, run}
      nil -> {:error, :not_found}
    end
  end

  def decide_prepared_action(user_id, prepared_action_id, decision, attrs \\ %{})
      when is_binary(user_id) and is_binary(prepared_action_id) and is_map(attrs) do
    normalized_decision = normalize_decision(decision)

    with decision when decision in [:confirm, :reject] <- normalized_decision,
         %PreparedAction{} = prepared_action <-
           Repo.get_by(PreparedAction,
             id: prepared_action_id,
             user_id: user_id,
             surface: "mobile"
           ),
         %Conversation{} = conversation <-
           Repo.get(Conversation, prepared_action.conversation_id),
         {:ok, client_message_id} <- optional_client_message_id(attrs) do
      if TelegramAssistant.prepared_action_expired?(prepared_action) do
        {:ok, expired_action} = TelegramAssistant.expire_prepared_action(prepared_action)
        {:error, :prepared_action_expired, expired_action, reload_thread(conversation)}
      else
        apply_prepared_action_decision(prepared_action, conversation, decision, client_message_id)
      end
    else
      :invalid -> {:error, :invalid_decision}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def run_queued_request(%{
        run_id: run_id,
        conversation_id: conversation_id,
        user_turn_id: user_turn_id
      }) do
    with %Run{} = run <- Repo.get(Run, run_id),
         %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
         %Turn{} = user_turn <- Repo.get(Turn, user_turn_id) do
      Runner.run_inbound(%{
        user_id: run.user_id,
        chat_id: run.chat_id,
        text: user_turn.text,
        conversation: conversation,
        user_turn: user_turn,
        surface: "mobile",
        run: run,
        started_at: run.started_at
      })
    else
      _ -> {:error, :queued_request_not_found}
    end
  rescue
    error ->
      if run = Repo.get(Run, run_id) do
        {:ok, _run} = TelegramAssistant.fail_run(run, Exception.message(error), "failed")
      end

      {:error, error}
  end

  defp insert_message_and_run(%Conversation{} = conversation, body, client_message_id) do
    now = DateTime.utc_now()
    local_intent = local_intent_for(body)
    route_profile = route_profile_for(body, local_intent)

    with {:ok, {updated_conversation, user_turn}} <-
           TelegramConversations.append_turn(conversation, %{
             "role" => "user",
             "client_message_id" => client_message_id,
             "delivery_state" => "sent",
             "text" => body,
             "turn_kind" => "user_message",
             "origin_type" => "chat",
             "structured_data" => %{
               "surface" => "mobile",
               "client_message_id" => client_message_id
             }
           }),
         {:ok, run} <- create_queued_run(updated_conversation, now, route_profile),
         {:ok, updated_conversation} <-
           TelegramConversations.update_metadata(updated_conversation, %{
             "last_mobile_run_id" => run.id,
             "title" => mobile_title(updated_conversation, body)
           }),
         {:ok, run} <-
           dispatch_user_message(updated_conversation, run, user_turn, body, local_intent) do
      {:ok,
       %{
         thread: reload_thread(updated_conversation),
         run: run,
         message: user_turn,
         duplicate?: false
       }}
    end
  end

  defp local_intent_for(body) do
    case SecretRequestGuard.response(body) do
      {:ok, reply, structured_data} ->
        {:ok,
         %{
           type: :credential_disclosure_guard,
           reply: reply,
           structured_data: structured_data
         }}

      :pass ->
        DirectIntent.classify(body)
    end
  end

  defp dispatch_user_message(
         %Conversation{} = conversation,
         %Run{} = run,
         %Turn{} = user_turn,
         _body,
         {:ok,
          %{
            type: :credential_disclosure_guard,
            reply: reply,
            structured_data: structured_data
          }}
       ) do
    with {:ok, _conversation, _turn, _delivery} <-
           Maraithon.AssistantChat.MobileDelivery.deliver_turn(
             conversation,
             conversation.chat_id,
             reply,
             intent: "credential_disclosure_guard",
             confidence: 1.0,
             turn_kind: "assistant_reply",
             origin_type: "system",
             origin_id: user_turn.id,
             structured_data:
               Map.merge(structured_data, %{
                 "surface" => "mobile",
                 "run_id" => run.id,
                 "message_class" => "assistant_reply",
                 "direct_intent" => "credential_disclosure_guard"
               })
           ) do
      TelegramAssistant.complete_run(run, %{
        status: "completed",
        result_summary: %{
          surface: "mobile",
          model_tier: "deterministic",
          model_name: "secret_request_guard",
          model_reasoning_effort: "none",
          task_class: "credential_disclosure_guard",
          route_reason: "direct_intent:credential_disclosure_guard",
          message_class: "assistant_reply",
          direct_intent: "credential_disclosure_guard",
          tool_steps: 0,
          llm_turns: 0
        }
      })
    end
  end

  defp dispatch_user_message(
         %Conversation{} = conversation,
         %Run{} = run,
         %Turn{} = user_turn,
         _body,
         {:ok, intent}
       ) do
    DirectIntent.execute(conversation, run, user_turn, intent)
  end

  defp dispatch_user_message(
         %Conversation{} = conversation,
         %Run{} = run,
         %Turn{} = user_turn,
         _body,
         :nomatch
       ) do
    with :ok <-
           Maraithon.AssistantChat.ThreadWorker.enqueue(%{
             run_id: run.id,
             conversation_id: conversation.id,
             user_turn_id: user_turn.id
           }) do
      {:ok, Repo.get(Run, run.id)}
    end
  end

  defp create_queued_run(%Conversation{} = conversation, now, route_profile) do
    TelegramAssistant.start_run(%{
      user_id: conversation.user_id,
      chat_id: conversation.chat_id,
      conversation_id: conversation.id,
      surface: "mobile",
      trigger_type: "inbound_message",
      status: "queued",
      model_provider: Map.fetch!(route_profile, :model_provider),
      model_name: route_model_name(route_profile),
      prompt_snapshot: %{},
      result_summary: route_result_summary(route_profile),
      started_at: now
    })
  end

  defp route_profile_for(_body, {:ok, %{type: type}}) do
    type = Atom.to_string(type)

    %{
      tier: :deterministic,
      task_class: type,
      route_reason: "direct_intent:#{type}",
      model_provider: "deterministic",
      model_name: "direct_intent",
      reasoning_effort: "none"
    }
  end

  defp route_profile_for(body, :nomatch) do
    body
    |> then(&ModelRouting.profile_for(%{text: &1}))
    |> Map.put(:model_provider, TelegramAssistant.model_provider_name())
  end

  defp route_result_summary(route_profile) do
    %{
      surface: "mobile",
      model_tier: route_profile |> Map.get(:tier) |> route_value(),
      task_class: route_profile |> Map.get(:task_class) |> route_value(),
      route_reason: route_profile |> Map.get(:route_reason) |> route_value(),
      model_name: route_model_name(route_profile),
      model_reasoning_effort: Map.get(route_profile, :reasoning_effort)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp route_value(value) when is_atom(value), do: Atom.to_string(value)
  defp route_value(value), do: value

  defp route_model_name(route_profile) do
    Map.get(route_profile, :model_name) || Map.get(route_profile, :model)
  end

  defp apply_prepared_action_decision(prepared_action, conversation, :reject, client_message_id) do
    {:ok, updated_action} =
      TelegramAssistant.update_prepared_action(prepared_action, %{status: "rejected", error: nil})

    _ = TelegramConversations.reopen(conversation)
    _ = TelegramAssistant.clear_prepared_action_pointer(conversation)

    {:ok, _conversation, _turn, _result} =
      Maraithon.AssistantChat.MobileDelivery.deliver_turn(
        conversation,
        prepared_action.chat_id,
        "Understood. I cancelled that action.",
        client_message_id: client_message_id,
        turn_kind: "system_notice",
        origin_type: "prepared_action",
        origin_id: updated_action.id,
        structured_data: %{
          "surface" => "mobile",
          "prepared_action_id" => updated_action.id,
          "decision" => "reject"
        }
      )

    {:ok, %{prepared_action: updated_action, thread: reload_thread(conversation)}}
  end

  defp apply_prepared_action_decision(prepared_action, conversation, :confirm, client_message_id) do
    case TelegramAssistant.confirm_and_execute(prepared_action) do
      {:ok, updated_action, result} ->
        _ = TelegramConversations.reopen(conversation)
        _ = TelegramAssistant.clear_prepared_action_pointer(conversation)

        {:ok, _conversation, _turn, _delivery} =
          Maraithon.AssistantChat.MobileDelivery.deliver_turn(
            conversation,
            prepared_action.chat_id,
            prepared_action_result_text(updated_action, result),
            client_message_id: client_message_id,
            turn_kind: "action_result",
            origin_type: "prepared_action",
            origin_id: updated_action.id,
            structured_data: %{
              "surface" => "mobile",
              "prepared_action_id" => updated_action.id,
              "decision" => "confirm",
              "result" => serialize_result(result)
            }
          )

        {:ok, %{prepared_action: updated_action, thread: reload_thread(conversation)}}

      {:error, updated_action, reason} ->
        _ = TelegramConversations.reopen(conversation)
        _ = TelegramAssistant.clear_prepared_action_pointer(conversation)

        {:ok, _conversation, _turn, _delivery} =
          Maraithon.AssistantChat.MobileDelivery.deliver_turn(
            conversation,
            prepared_action.chat_id,
            prepared_action_failure_text(updated_action, reason),
            client_message_id: client_message_id,
            turn_kind: "action_result",
            origin_type: "prepared_action",
            origin_id: updated_action.id,
            structured_data: %{
              "surface" => "mobile",
              "prepared_action_id" => updated_action.id,
              "decision" => "confirm",
              "error" => normalize_error(reason)
            }
          )

        {:ok, %{prepared_action: updated_action, thread: reload_thread(conversation)}}
    end
  end

  defp message_body(attrs) do
    body =
      attrs
      |> read_string("body")
      |> case do
        nil -> attrs |> Map.get("message", %{}) |> read_string("body")
        value -> value
      end

    cond do
      is_nil(body) -> {:error, :empty_message}
      byte_size(body) > @max_message_bytes -> {:error, :message_too_long}
      true -> {:ok, body}
    end
  end

  defp client_message_id(attrs) do
    attrs
    |> read_string("client_message_id")
    |> case do
      nil -> attrs |> Map.get("message", %{}) |> read_string("client_message_id")
      value -> value
    end
    |> case do
      nil -> {:error, :missing_client_message_id}
      value when byte_size(value) <= 128 -> {:ok, value}
      _ -> {:error, :invalid_client_message_id}
    end
  end

  defp thread_title(attrs, opts \\ []) do
    default = Keyword.get(opts, :default)

    title =
      attrs
      |> read_string("title")
      |> case do
        nil -> attrs |> Map.get("thread", %{}) |> read_string("title")
        value -> value
      end
      |> normalize_title(default)

    cond do
      is_nil(title) -> {:error, :empty_thread_title}
      byte_size(title) > @max_thread_title_bytes -> {:error, :thread_title_too_long}
      true -> {:ok, title}
    end
  end

  defp normalize_title(nil, default), do: default

  defp normalize_title(title, _default) when is_binary(title) do
    title
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> case do
      "" -> nil
      value -> ThreadNaming.safe_title(value)
    end
  end

  defp optional_client_message_id(attrs) do
    case read_string(attrs, "client_message_id") do
      nil -> {:ok, nil}
      value when byte_size(value) <= 128 -> {:ok, value}
      _ -> {:error, :invalid_client_message_id}
    end
  end

  defp reload_thread(%Conversation{} = conversation) do
    TelegramConversations.get_mobile_thread(conversation.user_id, conversation.id)
  end

  defp mobile_title(%Conversation{} = conversation, body) do
    current = get_in(conversation.metadata || %{}, ["title"])

    if ThreadNaming.placeholder?(current) do
      ThreadNaming.title_for_message(body)
    else
      current
    end
  end

  defp normalize_decision("confirm"), do: :confirm
  defp normalize_decision("reject"), do: :reject
  defp normalize_decision(:confirm), do: :confirm
  defp normalize_decision(:reject), do: :reject
  defp normalize_decision(_decision), do: :invalid

  defp prepared_action_result_text(prepared_action, result) do
    case Map.get(serialize_result(result), "message") do
      value when is_binary(value) and value != "" -> value
      _ -> "Completed #{prepared_action_label(prepared_action.action_type)}."
    end
  end

  defp prepared_action_failure_text(%PreparedAction{} = prepared_action, reason) do
    "Maraithon could not #{prepared_action_failure_label(prepared_action.action_type)}. " <>
      prepared_action_failure_detail(reason)
  end

  defp prepared_action_label("gmail_send"), do: "the Gmail message"
  defp prepared_action_label("slack_post"), do: "the Slack message"
  defp prepared_action_label("linear_create_issue"), do: "the Linear issue"
  defp prepared_action_label("linear_create_comment"), do: "the Linear comment"
  defp prepared_action_label("linear_update_issue_state"), do: "the Linear issue status update"
  defp prepared_action_label("notaui_complete_task"), do: "the Notaui task"
  defp prepared_action_label("notaui_update_task"), do: "the Notaui task update"
  defp prepared_action_label("agent_create"), do: "the agent creation"
  defp prepared_action_label("agent_update"), do: "the agent update"
  defp prepared_action_label("agent_delete"), do: "the agent removal"
  defp prepared_action_label("project_create"), do: "the project creation"
  defp prepared_action_label("project_update"), do: "the project update"
  defp prepared_action_label(_action_type), do: "that action"

  defp prepared_action_failure_label("gmail_send"), do: "send the Gmail message"
  defp prepared_action_failure_label("slack_post"), do: "send the Slack message"
  defp prepared_action_failure_label("linear_create_issue"), do: "create the Linear issue"
  defp prepared_action_failure_label("linear_create_comment"), do: "add the Linear comment"

  defp prepared_action_failure_label("linear_update_issue_state"),
    do: "update the Linear issue status"

  defp prepared_action_failure_label("notaui_complete_task"), do: "complete the Notaui task"
  defp prepared_action_failure_label("notaui_update_task"), do: "update the Notaui task"
  defp prepared_action_failure_label("agent_create"), do: "create the automation"
  defp prepared_action_failure_label("agent_update"), do: "update the automation"
  defp prepared_action_failure_label("agent_delete"), do: "remove the automation"
  defp prepared_action_failure_label("project_create"), do: "create the project"
  defp prepared_action_failure_label("project_update"), do: "update the project"
  defp prepared_action_failure_label(_action_type), do: "complete that action"

  defp prepared_action_failure_detail(:confirmation_expired),
    do: "The confirmation expired before it could run."

  defp prepared_action_failure_detail(:project_not_found),
    do: "The project it referenced is no longer available."

  defp prepared_action_failure_detail(:agent_not_found),
    do: "The agent it referenced is no longer available."

  defp prepared_action_failure_detail(:gmail_not_connected),
    do: "Gmail is not connected."

  defp prepared_action_failure_detail(:slack_not_connected),
    do: "Slack is not connected."

  defp prepared_action_failure_detail(:linear_not_connected),
    do: "Linear is not connected."

  defp prepared_action_failure_detail(:linear_reauth_required),
    do: "Linear needs to be reconnected before this action can run."

  defp prepared_action_failure_detail(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> prepared_action_failure_detail_from_text()
  end

  defp prepared_action_failure_detail(reason) do
    reason
    |> normalize_error()
    |> String.downcase()
    |> prepared_action_failure_detail_from_text()
  end

  defp prepared_action_failure_detail_from_text(reason) do
    cond do
      String.contains?(reason, "confirmation_expired") ->
        "The confirmation expired before it could run."

      String.contains?(reason, "project_not_found") ->
        "The project it referenced is no longer available."

      String.contains?(reason, "agent_not_found") ->
        "The agent it referenced is no longer available."

      String.contains?(reason, "invalid_user_context") ->
        "Sign in again so the account can be confirmed."

      String.contains?(reason, "reauth") ->
        "The required account needs to be reconnected before this action can run."

      String.contains?(reason, "gmail") or String.contains?(reason, "google_account") ->
        "Gmail is not connected."

      String.contains?(reason, "slack") ->
        "Slack is not connected."

      String.contains?(reason, "linear") ->
        "Linear is not connected."

      String.contains?(reason, "not_connected") ->
        "The required account is not connected."

      true ->
        "Review the action before running it again."
    end
  end

  defp serialize_result(%{} = result), do: stringify_map(result)
  defp serialize_result(result), do: %{"value" => inspect(result)}

  defp stringify_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), stringify_value(value))
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, known_atom_key(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp read_string(_map, _key), do: nil

  defp known_atom_key("body"), do: :body
  defp known_atom_key("client_message_id"), do: :client_message_id
  defp known_atom_key("title"), do: :title
  defp known_atom_key(_key), do: nil

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)
end
