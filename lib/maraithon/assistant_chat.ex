defmodule Maraithon.AssistantChat do
  @moduledoc """
  Surface-neutral assistant chat entrypoint for native mobile.
  """

  alias Maraithon.Repo
  alias Maraithon.AssistantChat.DirectIntent
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.{PreparedAction, Run, Runner}
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.{Conversation, Turn}

  @max_message_bytes 16_384

  def list_threads(user_id, opts \\ []) when is_binary(user_id) do
    {:ok, TelegramConversations.list_mobile_threads(user_id, opts)}
  end

  def create_thread(user_id, attrs \\ %{}) when is_binary(user_id) and is_map(attrs) do
    TelegramConversations.create_mobile_thread(user_id, attrs)
  end

  def get_thread(user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    case TelegramConversations.get_mobile_thread(user_id, thread_id) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :not_found}
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
         %Conversation{} = conversation <- Repo.get(Conversation, prepared_action.conversation_id),
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
         {:ok, run} <- create_queued_run(updated_conversation, now),
         {:ok, updated_conversation} <-
           TelegramConversations.update_metadata(updated_conversation, %{
             "last_mobile_run_id" => run.id,
             "title" => mobile_title(updated_conversation, body)
           }),
         {:ok, run} <- dispatch_user_message(updated_conversation, run, user_turn, body) do
      {:ok,
       %{
         thread: reload_thread(updated_conversation),
         run: run,
         message: user_turn,
         duplicate?: false
       }}
    end
  end

  defp dispatch_user_message(
         %Conversation{} = conversation,
         %Run{} = run,
         %Turn{} = user_turn,
         body
       ) do
    case DirectIntent.classify(body) do
      {:ok, intent} ->
        DirectIntent.execute(conversation, run, user_turn, intent)

      :nomatch ->
        with :ok <-
               Maraithon.AssistantChat.ThreadWorker.enqueue(%{
                 run_id: run.id,
                 conversation_id: conversation.id,
                 user_turn_id: user_turn.id
               }) do
          {:ok, Repo.get(Run, run.id)}
        end
    end
  end

  defp create_queued_run(%Conversation{} = conversation, now) do
    TelegramAssistant.start_run(%{
      user_id: conversation.user_id,
      chat_id: conversation.chat_id,
      conversation_id: conversation.id,
      surface: "mobile",
      trigger_type: "inbound_message",
      status: "queued",
      model_provider: TelegramAssistant.model_provider_name(),
      model_name: TelegramAssistant.model_name(),
      prompt_snapshot: %{},
      result_summary: %{surface: "mobile"},
      started_at: now
    })
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
            "I couldn't complete that yet: #{normalize_error(reason)}",
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

    if current in [nil, "", "New conversation"] do
      body
      |> String.split(~r/\s+/, trim: true)
      |> Enum.take(8)
      |> Enum.join(" ")
      |> case do
        "" -> "New conversation"
        value -> value
      end
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
      _ -> "Completed #{prepared_action.action_type}."
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
  defp known_atom_key(_key), do: nil

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)
end
