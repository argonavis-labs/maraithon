defmodule Maraithon.AssistantChat.DirectIntent do
  @moduledoc """
  Deterministic mobile chat actions for explicit, low-risk commands.

  The model runtime still owns general assistant conversation. This module only
  handles commands where the user's requested mutation is already complete in
  the message, so the mobile chat can behave like an instant command pane.
  """

  alias Maraithon.AssistantChat.MobileDelivery
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.TelegramConversations.Turn
  alias Maraithon.Todos

  @title_max_chars 240
  @create_todo_patterns [
    ~r/^\s*(?:create|make|add)\s+(?:(?:a|an|new)\s+)*todo\s+(?:exactly\s+)?(?:called|named|titled)\s+(.+?)(?:[.!?]\s+|[.!?]?$|$)/iu,
    ~r/^\s*(?:create|make|add)\s+(?:(?:a|an|new)\s+)*todo\s*[:\-]\s*(.+?)(?:[.!?]\s+|[.!?]?$|$)/iu,
    ~r/^\s*add\s+(.+?)\s+to\s+(?:my\s+)?(?:todo|to-do|task)\s+list(?:[.!?]\s*|$)/iu
  ]

  def classify(text) when is_binary(text) do
    case extract_todo_title(text) do
      title when is_binary(title) ->
        {:ok, %{type: :create_todo, title: title}}

      nil ->
        :nomatch
    end
  end

  def classify(_text), do: :nomatch

  def execute(
        %Conversation{} = conversation,
        %Run{} = run,
        %Turn{} = user_turn,
        %{type: :create_todo, title: title}
      ) do
    attrs = todo_attrs(conversation, run, user_turn, title)

    with {:ok, [todo]} <- Todos.upsert_many(conversation.user_id, [attrs]),
         {:ok, _conversation, _turn, _delivery} <-
           MobileDelivery.deliver_turn(
             conversation,
             conversation.chat_id,
             "Added: #{todo.title}",
             turn_kind: "action_result",
             origin_type: "chat",
             origin_id: user_turn.id,
             structured_data: %{
               "surface" => "mobile",
               "run_id" => run.id,
               "message_class" => "action_result",
               "direct_intent" => "create_todo",
               "linked_todo" => Todos.serialize_for_prompt(todo)
             }
           ) do
      TelegramAssistant.complete_run(run, %{
        status: "completed",
        result_summary: %{
          surface: "mobile",
          message_class: "action_result",
          direct_intent: "create_todo",
          todo_id: todo.id,
          tool_steps: 0,
          llm_turns: 0
        }
      })
    end
  end

  defp extract_todo_title(text) do
    normalized = String.trim(text)

    Enum.find_value(@create_todo_patterns, fn pattern ->
      case Regex.run(pattern, normalized, capture: :all_but_first) do
        [title | _rest] -> normalize_title(title)
        _ -> nil
      end
    end)
  end

  defp normalize_title(title) do
    title =
      title
      |> String.trim()
      |> String.trim_leading(~s("))
      |> String.trim_leading("'")
      |> String.trim_trailing(~s("))
      |> String.trim_trailing("'")
      |> String.trim()
      |> String.slice(0, @title_max_chars)

    if String.length(title) >= 4, do: title, else: nil
  end

  defp todo_attrs(%Conversation{} = conversation, %Run{} = run, %Turn{} = user_turn, title) do
    %{
      "source" => "mobile_assistant",
      "kind" => "general",
      "attention_mode" => "act_now",
      "title" => title,
      "summary" => "Captured from mobile assistant chat.",
      "next_action" => title,
      "priority" => 60,
      "status" => "open",
      "dedupe_key" => "mobile_assistant:#{conversation.id}:#{user_turn.id}",
      "metadata" => %{
        "captured_from" => "mobile_chat",
        "conversation_id" => conversation.id,
        "run_id" => run.id,
        "user_turn_id" => user_turn.id,
        "client_message_id" => user_turn.client_message_id,
        "request_text" => user_turn.text
      }
    }
  end
end
