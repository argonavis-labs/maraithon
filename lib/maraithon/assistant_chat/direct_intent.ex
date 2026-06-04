defmodule Maraithon.AssistantChat.DirectIntent do
  @moduledoc """
  Deterministic mobile chat actions for explicit, low-risk commands.

  The model runtime still owns general assistant conversation. This module only
  handles commands where the user's requested mutation is already complete in
  the message, so the mobile chat can behave like an instant command pane.
  """

  alias Maraithon.AssistantChat.{CalculationIntent, MobileDelivery}
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.TelegramConversations.Turn
  alias Maraithon.Todos

  @title_max_chars 240
  @create_todo_patterns [
    ~r/^\s*(?:create|make|add)\s+(?:(?:a|an|new)\s+)*todo\s+(?:exactly\s+)?(?:called|named|titled)\s+(.+?)(?:[.!?]\s+|[.!?]?$|$)/iu,
    ~r/^\s*(?:create|make|add)\s+(?:(?:a|an|new)\s+)*todo\s*[:\-]\s*(.+?)(?:[.!?]\s+|[.!?]?$|$)/iu,
    ~r/^\s*add\s+(.+?)\s+to\s+(?:my\s+)?(?:todo|to-do|task)\s+list(?:[.!?]\s*|$)/iu
  ]
  @linked_done_phrases MapSet.new([
                         "done",
                         "it is done",
                         "it's done",
                         "this is done",
                         "mark done",
                         "mark it done",
                         "mark this done",
                         "mark complete",
                         "mark it complete",
                         "mark this complete",
                         "complete this",
                         "completed",
                         "handled",
                         "this is handled",
                         "resolved",
                         "this is resolved"
                       ])
  @linked_dismiss_phrases MapSet.new([
                            "dismiss",
                            "dismiss this",
                            "delete this",
                            "delete this todo",
                            "remove this",
                            "remove this todo",
                            "not relevant",
                            "this is not relevant",
                            "no longer relevant",
                            "this is no longer relevant"
                          ])
  @linked_snooze_phrases MapSet.new([
                           "snooze",
                           "snooze this",
                           "snooze this todo",
                           "remind me tomorrow",
                           "tomorrow",
                           "later"
                         ])

  @fast_chat_replies %{
    greeting: "Ready. What needs attention?",
    acknowledgement: "Got it.",
    thanks: "Anytime."
  }

  @fast_chat_phrases %{
    greeting:
      MapSet.new([
        "hey",
        "hi",
        "hello",
        "yo",
        "gm",
        "good morning",
        "good afternoon",
        "good evening"
      ]),
    acknowledgement:
      MapSet.new([
        "ok",
        "okay",
        "k",
        "kk",
        "got it",
        "sounds good",
        "makes sense",
        "cool"
      ]),
    thanks:
      MapSet.new([
        "thanks",
        "thank you",
        "thx",
        "ty",
        "appreciate it"
      ])
  }

  @context_keyword_patterns [
    ~r/\btodos?\b/u,
    ~r/\bto-dos?\b/u,
    ~r/\btasks?\b/u,
    ~r/\bcontacts?\b/u,
    ~r/\bpeople\b/u,
    ~r/\bpersons?\b/u,
    ~r/\bcrm\b/u,
    ~r/\bfollow\s*-?\s?ups?\b/u,
    ~r/\bwaiting\b/u,
    ~r/\bowe\b/u,
    ~r/\bcalendar\b/u,
    ~r/\bmeetings?\b/u,
    ~r/\bopen\s+loops?\b/u,
    ~r/\bconnected\b/u,
    ~r/\bsources?\b/u,
    ~r/\baccounts?\b/u,
    ~r/\bprojects?\b/u
  ]

  def classify(text) when is_binary(text) do
    case extract_todo_title(text) do
      title when is_binary(title) ->
        {:ok, %{type: :create_todo, title: title}}

      nil ->
        case CalculationIntent.classify(text) do
          {:ok, intent} ->
            {:ok, intent}

          :nomatch ->
            case fast_chat_reply(text) do
              {:ok, kind, reply} ->
                {:ok, %{type: :fast_chat_reply, kind: kind, reply: reply}}

              :nomatch ->
                :nomatch
            end
        end
    end
  end

  def classify(_text), do: :nomatch

  def classify(text, %Conversation{} = conversation) when is_binary(text) do
    case linked_todo_action(text, conversation) do
      {:ok, action} -> {:ok, %{type: :linked_todo_action, action: action}}
      :nomatch -> classify(text)
    end
  end

  def classify(text, _conversation), do: classify(text)

  def execute(
        %Conversation{} = conversation,
        %Run{} = run,
        %Turn{} = user_turn,
        %{type: :linked_todo_action, action: action}
      ) do
    with todo_id when is_binary(todo_id) <- linked_todo_id(conversation),
         {:ok, todo} <- apply_linked_todo_action(conversation.user_id, todo_id, action),
         {:ok, _updated_conversation} <-
           TelegramConversations.update_metadata(conversation, %{
             "linked_todo" => Todos.serialize_for_prompt(todo),
             "linked_todo_status" => todo.status
           }),
         {:ok, _conversation, _turn, _delivery} <-
           MobileDelivery.deliver_turn(
             conversation,
             conversation.chat_id,
             linked_todo_action_reply(action, todo),
             turn_kind: "action_result",
             origin_type: "chat",
             origin_id: user_turn.id,
             structured_data: %{
               "surface" => "mobile",
               "run_id" => run.id,
               "message_class" => "action_result",
               "direct_intent" => "linked_todo_action",
               "linked_todo_action" => Atom.to_string(action),
               "linked_todo" => Todos.serialize_for_prompt(todo)
             }
           ) do
      TelegramAssistant.complete_run(run, %{
        status: "completed",
        result_summary: %{
          surface: "mobile",
          model_tier: "deterministic",
          model_name: "direct_intent",
          model_reasoning_effort: "none",
          task_class: "linked_todo_action",
          route_reason: "direct_intent:linked_todo_action",
          message_class: "action_result",
          direct_intent: "linked_todo_action",
          linked_todo_action: Atom.to_string(action),
          todo_id: todo.id,
          tool_steps: 0,
          llm_turns: 0
        }
      })
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

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
             created_todo_reply(todo.title),
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
          model_tier: "deterministic",
          model_name: "direct_intent",
          model_reasoning_effort: "none",
          task_class: "create_todo",
          route_reason: "direct_intent:create_todo",
          message_class: "action_result",
          direct_intent: "create_todo",
          todo_id: todo.id,
          tool_steps: 0,
          llm_turns: 0
        }
      })
    end
  end

  def execute(
        %Conversation{} = conversation,
        %Run{} = run,
        %Turn{} = user_turn,
        %{type: :fast_chat_reply, kind: kind, reply: reply}
      ) do
    with {:ok, _conversation, _turn, _delivery} <-
           MobileDelivery.deliver_turn(
             conversation,
             conversation.chat_id,
             reply,
             turn_kind: "assistant_reply",
             origin_type: "chat",
             origin_id: user_turn.id,
             structured_data: %{
               "surface" => "mobile",
               "run_id" => run.id,
               "message_class" => "assistant_reply",
               "direct_intent" => "fast_chat_reply",
               "fast_chat_kind" => Atom.to_string(kind)
             }
           ) do
      TelegramAssistant.complete_run(run, %{
        status: "completed",
        result_summary: %{
          surface: "mobile",
          model_tier: "deterministic",
          model_name: "direct_intent",
          model_reasoning_effort: "none",
          task_class: "fast_chat_reply",
          route_reason: "direct_intent:fast_chat_reply",
          message_class: "assistant_reply",
          direct_intent: "fast_chat_reply",
          fast_chat_kind: Atom.to_string(kind),
          tool_steps: 0,
          llm_turns: 0
        }
      })
    end
  end

  def execute(
        %Conversation{} = conversation,
        %Run{} = run,
        %Turn{} = user_turn,
        %{type: :simple_calculation, expression: expression, result: result, reply: reply}
      ) do
    with {:ok, _conversation, _turn, _delivery} <-
           MobileDelivery.deliver_turn(
             conversation,
             conversation.chat_id,
             reply,
             turn_kind: "assistant_reply",
             origin_type: "chat",
             origin_id: user_turn.id,
             structured_data: %{
               "surface" => "mobile",
               "run_id" => run.id,
               "message_class" => "assistant_reply",
               "direct_intent" => "simple_calculation",
               "calculation" => %{
                 "expression" => expression,
                 "result" => result
               }
             }
           ) do
      TelegramAssistant.complete_run(run, %{
        status: "completed",
        result_summary: %{
          surface: "mobile",
          model_tier: "deterministic",
          model_name: "direct_intent",
          model_reasoning_effort: "none",
          task_class: "simple_calculation",
          route_reason: "direct_intent:simple_calculation",
          message_class: "assistant_reply",
          direct_intent: "simple_calculation",
          calculation: %{
            expression: expression,
            result: result
          },
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

  defp fast_chat_reply(text) do
    normalized = normalize_fast_chat_text(text)

    cond do
      normalized == "" ->
        :nomatch

      String.length(normalized) > 48 ->
        :nomatch

      Regex.scan(~r/\S+/u, normalized) |> length() > 6 ->
        :nomatch

      context_request?(normalized) ->
        :nomatch

      true ->
        Enum.find_value(@fast_chat_phrases, :nomatch, fn {kind, phrases} ->
          if MapSet.member?(phrases, normalized) do
            {:ok, kind, Map.fetch!(@fast_chat_replies, kind)}
          end
        end)
    end
  end

  defp normalize_fast_chat_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s'-]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp context_request?(text) do
    Enum.any?(@context_keyword_patterns, &Regex.match?(&1, text))
  end

  defp linked_todo_action(text, %Conversation{} = conversation) do
    if linked_todo_id(conversation) do
      text
      |> normalize_fast_chat_text()
      |> classify_linked_todo_action()
    else
      :nomatch
    end
  end

  defp classify_linked_todo_action(normalized) do
    cond do
      MapSet.member?(@linked_done_phrases, normalized) ->
        {:ok, :done}

      Regex.match?(~r/\b(mark|set|move)\b.*\b(done|complete|completed|handled|resolved)\b/u, normalized) ->
        {:ok, :done}

      Regex.match?(~r/\b(this|it)\b.*\b(is|was)\b.*\b(done|complete|completed|handled|resolved)\b/u, normalized) ->
        {:ok, :done}

      MapSet.member?(@linked_dismiss_phrases, normalized) ->
        {:ok, :dismiss}

      Regex.match?(~r/\b(dismiss|delete|remove)\b.*\b(this|todo|task|work item)\b/u, normalized) ->
        {:ok, :dismiss}

      Regex.match?(~r/\b(no longer relevant|not relevant|irrelevant)\b/u, normalized) ->
        {:ok, :dismiss}

      MapSet.member?(@linked_snooze_phrases, normalized) ->
        {:ok, :snooze}

      Regex.match?(~r/\b(snooze|remind me|later|tomorrow)\b/u, normalized) ->
        {:ok, :snooze}

      true ->
        :nomatch
    end
  end

  defp linked_todo_id(%Conversation{} = conversation) do
    case get_in(conversation.metadata || %{}, ["linked_todo_id"]) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  defp apply_linked_todo_action(user_id, todo_id, :done) do
    Todos.mark_done(user_id, todo_id,
      actor_type: "user",
      actor_id: user_id,
      actor_label: "User",
      note: "Completed from mobile todo chat."
    )
  end

  defp apply_linked_todo_action(user_id, todo_id, :dismiss) do
    Todos.dismiss(user_id, todo_id,
      actor_type: "user",
      actor_id: user_id,
      actor_label: "User",
      source: "mobile_todo_chat",
      note: "Dismissed from mobile todo chat."
    )
  end

  defp apply_linked_todo_action(user_id, todo_id, :snooze) do
    until_datetime =
      DateTime.utc_now()
      |> DateTime.add(24, :hour)
      |> DateTime.truncate(:second)

    Todos.snooze(user_id, todo_id, until_datetime,
      actor_type: "user",
      actor_id: user_id,
      actor_label: "User",
      note: "Snoozed from mobile todo chat."
    )
  end

  defp linked_todo_action_reply(:done, todo), do: "Marked done: #{todo.title}"
  defp linked_todo_action_reply(:dismiss, todo), do: "Dismissed: #{todo.title}"
  defp linked_todo_action_reply(:snooze, todo), do: "Snoozed until tomorrow: #{todo.title}"

  defp todo_attrs(%Conversation{} = conversation, %Run{} = run, %Turn{} = user_turn, title) do
    %{
      "source" => "mobile_assistant",
      "kind" => "general",
      "attention_mode" => "act_now",
      "title" => title,
      "summary" => "Added from this chat so it stays in your active work until handled.",
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

  defp created_todo_reply(title) do
    "Added to open work. It will stay visible until handled: #{title}"
  end
end
