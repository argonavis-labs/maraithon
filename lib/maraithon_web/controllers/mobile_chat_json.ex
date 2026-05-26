defmodule MaraithonWeb.MobileChatJSON do
  @moduledoc false

  alias Maraithon.TelegramAssistant.{PreparedAction, Run}
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.Repo

  def thread_index(threads) when is_list(threads) do
    %{threads: Enum.map(threads, &thread_summary/1), next_cursor: nil}
  end

  def thread(%Conversation{} = conversation) do
    %{thread: full_thread(conversation)}
  end

  def thread_with_run(%Conversation{} = conversation, %Run{} = run) do
    %{thread: full_thread(conversation, run), run: run(run)}
  end

  def thread_with_run(%Conversation{} = conversation, _run), do: thread(conversation)

  def run(%Run{} = run) do
    %{
      id: run.id,
      thread_id: run.conversation_id,
      status: normalize_run_status(run),
      started_at: json_value(run.started_at),
      finished_at: json_value(run.finished_at),
      error: run.error,
      message_class: summary_value(run.result_summary, :message_class)
    }
  end

  def prepared_action(%PreparedAction{} = prepared_action) do
    %{
      id: prepared_action.id,
      status: prepared_action.status,
      action_type: prepared_action.action_type,
      target_type: prepared_action.target_type,
      preview_text: prepared_action.preview_text,
      expires_at: json_value(prepared_action.expires_at)
    }
  end

  def error(reason), do: %{error: format_error(reason)}

  def action_result(%PreparedAction{} = prepared_action, %Conversation{} = conversation) do
    %{
      prepared_action: prepared_action(prepared_action),
      thread: full_thread(conversation)
    }
  end

  defp thread_summary(%Conversation{} = conversation) do
    latest = latest_turn(conversation)

    %{
      id: conversation.id,
      title: thread_title(conversation),
      status: conversation.status,
      last_turn_at: json_value(conversation.last_turn_at),
      updated_at: json_value(conversation.updated_at),
      message_count: length(conversation.turns || []),
      latest_message: latest && message(latest)
    }
  end

  defp full_thread(%Conversation{} = conversation, run \\ nil) do
    active_run = run || active_run(conversation)

    %{
      id: conversation.id,
      title: thread_title(conversation),
      status: conversation.status,
      pending_run: active_run && run(active_run),
      messages:
        conversation
        |> sorted_turns()
        |> Enum.map(&message/1)
    }
  end

  defp message(%Turn{} = turn) do
    structured_data = turn.structured_data || %{}
    prepared_action_id = structured_data["prepared_action_id"]

    %{
      id: turn.id,
      client_message_id: turn.client_message_id || structured_data["client_message_id"],
      role: turn.role,
      body: turn.text,
      turn_kind: turn.turn_kind,
      message_class: structured_data["message_class"],
      sent_at: json_value(turn.inserted_at),
      delivery_state: turn.delivery_state || "delivered",
      run_id: structured_data["run_id"],
      actions: actions_for(turn, prepared_action_id),
      linked_todo: structured_data["linked_todo"],
      structured_data: structured_data
    }
  end

  defp actions_for(%Turn{turn_kind: "approval_prompt"}, prepared_action_id)
       when is_binary(prepared_action_id) do
    if prepared_action_pending?(prepared_action_id) do
      [
        %{
          id: prepared_action_id,
          kind: "prepared_action_decision",
          label: "Confirm",
          decision: "confirm",
          style: "primary"
        },
        %{
          id: prepared_action_id,
          kind: "prepared_action_decision",
          label: "Cancel",
          decision: "reject",
          style: "destructive"
        }
      ]
    else
      []
    end
  end

  defp actions_for(_turn, _prepared_action_id), do: []

  defp prepared_action_pending?(prepared_action_id) do
    case Repo.get(PreparedAction, prepared_action_id) do
      %PreparedAction{status: "awaiting_confirmation"} -> true
      _ -> false
    end
  end

  defp active_run(%Conversation{} = conversation) do
    case Maraithon.TelegramConversations.active_run_for_conversation(conversation.id) do
      %Run{} = run -> run
      nil -> nil
    end
  end

  defp normalize_run_status(%Run{status: "completed", result_summary: result_summary}) do
    if summary_value(result_summary, :message_class) == "approval_prompt" do
      "waiting_confirmation"
    else
      "completed"
    end
  end

  defp normalize_run_status(%Run{status: status}), do: status

  defp latest_turn(%Conversation{} = conversation) do
    conversation
    |> sorted_turns()
    |> List.last()
  end

  defp sorted_turns(%Conversation{turns: turns}) when is_list(turns) do
    Enum.sort_by(turns, & &1.inserted_at, DateTime)
  end

  defp sorted_turns(_conversation), do: []

  defp thread_title(%Conversation{} = conversation) do
    get_in(conversation.metadata || %{}, ["title"]) ||
      first_user_turn_title(conversation) ||
      conversation.summary ||
      "New conversation"
  end

  defp first_user_turn_title(%Conversation{} = conversation) do
    conversation
    |> sorted_turns()
    |> Enum.find(&(&1.role == "user"))
    |> case do
      %Turn{text: text} when is_binary(text) ->
        text |> String.split(~r/\s+/, trim: true) |> Enum.take(8) |> Enum.join(" ")

      _ ->
        nil
    end
  end

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_value(value), do: value

  defp summary_value(summary, key) when is_map(summary) and is_atom(key) do
    Map.get(summary, key) || Map.get(summary, Atom.to_string(key))
  end

  defp summary_value(_summary, _key), do: nil

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
