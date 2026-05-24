defmodule Maraithon.TelegramAssistant.BriefTodoReview do
  @moduledoc """
  Drives one-at-a-time Telegram review sessions for todos linked to a brief.
  """

  import Ecto.Query

  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.TodoActions
  alias Maraithon.TelegramResponder
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  @callback_prefix "brftd"
  @latest_callback_id "latest"
  @review_key "todo_review"
  @open_statuses ["open", "snoozed"]
  @text_review_limit 12

  def reviewable?(%Brief{} = brief), do: linked_todo_ids(brief) != []
  def reviewable?(_brief), do: false

  def text_review_intent(text) when is_binary(text) do
    text
    |> normalize_text()
    |> classify_text_intent()
  end

  def text_review_intent(_text), do: %{intent: :none, confidence: 0.0, reason: :non_text}

  def text_review_request?(text) when is_binary(text) do
    match?(%{intent: :start_review}, text_review_intent(text))
  end

  def text_review_request?(_text), do: false

  def handle_text_request(attrs) when is_map(attrs) do
    text = read_string(attrs, "text")

    case pending_review_answer(attrs, text) do
      :start ->
        clear_pending_review_clarification(attrs)

        user_id = read_string(attrs, "user_id")
        chat_id = read_id_string(attrs, "chat_id")

        start_latest_review(user_id, chat_id)

      :list ->
        clear_pending_review_clarification(attrs)

        user_id = read_string(attrs, "user_id")
        chat_id = read_id_string(attrs, "chat_id")

        send_todo_list_summary(user_id, chat_id)

      :cancel ->
        clear_pending_review_clarification(attrs)
        chat_id = read_id_string(attrs, "chat_id")
        send_review_canceled(chat_id)

      :unknown ->
        handle_text_intent(attrs, text_review_intent(text))
    end
  end

  def handle_text_request(_attrs), do: :ignored

  defp handle_text_intent(attrs, intent) do
    case intent do
      %{intent: :start_review} ->
        user_id = read_string(attrs, "user_id")
        chat_id = read_id_string(attrs, "chat_id")

        start_latest_review(user_id, chat_id)

      %{intent: :show_list} ->
        user_id = read_string(attrs, "user_id")
        chat_id = read_id_string(attrs, "chat_id")

        send_todo_list_summary(user_id, chat_id)

      %{intent: :clarify_review} = intent ->
        ask_review_mode(attrs, intent)

      _intent ->
        :ignored
    end
  end

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s'-]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp classify_text_intent(""), do: %{intent: :none, confidence: 0.0, reason: :blank}

  defp classify_text_intent(text) do
    todo_subject? = todo_subject?(text)
    sequential? = sequential_review_request?(text)
    review? = review_request?(text)
    direct_list? = direct_list_request?(text)
    read_question? = todo_read_question?(text)
    mutation? = todo_mutation_request?(text)

    cond do
      not todo_subject? ->
        %{intent: :none, confidence: 0.0, reason: :not_todo_related}

      mutation? and not sequential? ->
        %{intent: :none, confidence: 0.92, reason: :todo_write_request}

      sequential? ->
        %{intent: :start_review, confidence: 0.95, reason: :sequential_review_request}

      direct_list? ->
        %{intent: :show_list, confidence: 0.9, reason: :direct_list_request}

      read_question? ->
        %{intent: :none, confidence: 0.88, reason: :todo_read_question}

      review? ->
        %{intent: :clarify_review, confidence: 0.72, reason: :review_mode_ambiguous}

      true ->
        %{intent: :none, confidence: 0.4, reason: :todo_related_but_not_review}
    end
  end

  defp todo_subject?(text) do
    Regex.match?(~r/\b(to-?dos?|tasks?|open loops?|action items?)\b/u, text)
  end

  defp sequential_review_request?(text) do
    Regex.match?(
      ~r/\b(one at a time|1 at a time|one by one|each one|next one|with buttons|action buttons)\b/u,
      text
    ) or
      (review_request?(text) and
         Regex.match?(~r/\b(start|let'?s|let us|walk|go|work|move|take|help me)\b/u, text))
  end

  defp review_request?(text) do
    Regex.match?(
      ~r/\b(review|triage|process|go through|go over|walk through|work through|clear|knock out|handle|decide on|make decisions? on)\b/u,
      text
    )
  end

  defp direct_list_request?(text) do
    Regex.match?(
      ~r/^(list|show|pull up|give me|send me|surface)\b.*\b(to-?dos?|tasks?|open loops?|action items?)\b/u,
      text
    )
  end

  defp todo_read_question?(text) do
    Regex.match?(~r/\b(what'?s|what is|what are|which|anything|status of|overview of)\b/u, text) and
      todo_subject?(text)
  end

  defp todo_mutation_request?(text) do
    Regex.match?(
      ~r/\b(add|create|make|new|save|remember|remind me|delete|remove|mark all|complete all|dismiss all|snooze all)\b/u,
      text
    )
  end

  defp pending_review_answer(attrs, text) do
    if pending_review_clarification?(attrs) do
      text
      |> normalize_text()
      |> classify_pending_review_answer()
    else
      :unknown
    end
  end

  defp classify_pending_review_answer(text) do
    cond do
      Regex.match?(
        ~r/\b(one by one|one at a time|1 at a time|triage|review|buttons|do that|yes|yep|start)\b/u,
        text
      ) ->
        :start

      Regex.match?(~r/\b(list|quick list|show|just show|overview)\b/u, text) ->
        :list

      Regex.match?(~r/\b(cancel|stop|never mind|nevermind|no)\b/u, text) ->
        :cancel

      true ->
        :unknown
    end
  end

  defp pending_review_clarification?(attrs) do
    case Map.get(attrs, :conversation) || Map.get(attrs, "conversation") do
      %{metadata: metadata} when is_map(metadata) ->
        Map.get(metadata, "pending_todo_review_clarification") == true

      _ ->
        false
    end
  end

  defp clear_pending_review_clarification(attrs) do
    case Map.get(attrs, :conversation) || Map.get(attrs, "conversation") do
      %Maraithon.TelegramConversations.Conversation{} = conversation ->
        _ =
          Maraithon.TelegramConversations.update_metadata(conversation, %{
            "pending_clarification" => false,
            "pending_todo_review_clarification" => false,
            "last_clarifying_question" => nil,
            "todo_review_clarification_reason" => nil
          })

        :ok

      _ ->
        :ok
    end
  end

  def list_button(%Brief{} = brief) do
    if reviewable?(brief) do
      %{"text" => "List Todos", "callback_data" => callback_data(brief.id, "start")}
    end
  end

  def list_button(_brief), do: nil

  def handle_callback(data) when is_map(data) do
    case parse_callback(read_string(data, "data", "")) do
      {:ok, :latest, action} when action in ["start", "list", "cancel"] ->
        handle_latest_callback(data, action)

      {:ok, brief_id, "start"} when is_binary(brief_id) ->
        start_review(data, brief_id)

      {:error, :invalid_callback} ->
        :ignored
    end
  end

  def handle_callback(_data), do: :ignored

  def after_todo_action(user_id, chat_id, %Todo{} = todo, action)
      when is_binary(user_id) and is_binary(chat_id) and is_binary(action) do
    case active_review_for(user_id, chat_id, todo.id) do
      %Brief{} = brief -> advance_after_action(brief, chat_id, todo, action)
      nil -> :ok
    end
  end

  def after_todo_action(_user_id, _chat_id, _todo, _action), do: :ok

  defp start_review(data, brief_id) do
    chat_id = read_id_string(data, "chat_id")
    callback_id = read_string(data, "callback_id")

    with chat_id when is_binary(chat_id) <- chat_id,
         %{user_id: user_id} <-
           ConnectedAccounts.get_connected_by_external_account("telegram", chat_id),
         %Brief{} = brief <- Repo.get(Brief, brief_id),
         true <- brief.user_id == user_id do
      start_review_for_brief(brief, chat_id, callback_id: callback_id)
      :ok
    else
      {:error, :invalid_callback} ->
        :ignored

      _ ->
        maybe_answer_callback(callback_id, "I couldn't open that todo list.")
        :ok
    end
  end

  defp handle_latest_callback(data, action) do
    chat_id = read_id_string(data, "chat_id")
    callback_id = read_string(data, "callback_id")

    with chat_id when is_binary(chat_id) <- chat_id,
         %{user_id: user_id} <-
           ConnectedAccounts.get_connected_by_external_account("telegram", chat_id) do
      case action do
        "start" ->
          maybe_answer_callback(callback_id, "Sending the first todo")
          start_latest_review(user_id, chat_id)

        "list" ->
          maybe_answer_callback(callback_id, "Sending a quick list")
          send_todo_list_summary(user_id, chat_id)

        "cancel" ->
          maybe_answer_callback(callback_id, "Canceled")
          :ok
      end
    else
      _ ->
        maybe_answer_callback(callback_id, "I couldn't match that to this chat.")
        :ok
    end
  end

  defp start_latest_review(user_id, chat_id) when is_binary(user_id) and is_binary(chat_id) do
    case active_review_for_chat(user_id, chat_id) do
      %Brief{} = brief ->
        resume_review(brief, chat_id)
        :ok

      nil ->
        case latest_reviewable_brief(user_id) || build_open_todo_review_brief(user_id) do
          %Brief{} = brief ->
            start_review_for_brief(brief, chat_id)
            :ok

          nil ->
            send_no_todos(chat_id)
            :ok
        end
    end
  end

  defp start_latest_review(_user_id, _chat_id), do: :ignored

  defp send_todo_list_summary(user_id, chat_id) when is_binary(user_id) and is_binary(chat_id) do
    todos =
      user_id
      |> Todos.list_open_for_user(limit: @text_review_limit)
      |> Briefs.order_todo_digest_items(%Brief{metadata: %{}})

    text =
      case todos do
        [] ->
          "I don't see any open todos ready to review right now."

        todos ->
          lines =
            todos
            |> Enum.with_index(1)
            |> Enum.map(fn {todo, index} -> "#{index}. #{safe(todo.title)}" end)
            |> Enum.join("\n")

          """
          <b>Open todos</b>
          #{lines}

          Want to work through them with buttons? Tap One by One.
          """
          |> String.trim()
      end

    case TelegramResponder.send(chat_id, text,
           parse_mode: "HTML",
           reply_markup: maybe_review_choice_markup(todos)
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp send_todo_list_summary(_user_id, _chat_id), do: :ignored

  defp start_review_for_brief(%Brief{} = brief, chat_id, opts \\ []) do
    todos = review_todos(brief)

    review =
      %{
        "status" => "active",
        "chat_id" => chat_id,
        "started_at" => now_iso8601(),
        "todo_ids" => Enum.map(todos, & &1.id),
        "reviewed" => []
      }

    brief = put_review!(brief, review)

    case next_unreviewed_open_todo(brief) do
      {%Todo{} = todo, position, total} ->
        brief = set_current_todo!(brief, todo.id)
        maybe_answer_callback(Keyword.get(opts, :callback_id), "Sending #{position}/#{total}")
        send_review_todo(chat_id, brief, todo, position, total)

      nil ->
        brief = complete_review!(brief)
        maybe_answer_callback(Keyword.get(opts, :callback_id), "No open todos")
        send_summary(chat_id, brief)
    end
  end

  defp resume_review(%Brief{} = brief, chat_id) do
    case next_unreviewed_open_todo(brief) do
      {%Todo{} = todo, position, total} ->
        brief = set_current_todo!(brief, todo.id)
        send_review_todo(chat_id, brief, todo, position, total)

      nil ->
        brief = complete_review!(brief)
        send_summary(chat_id, brief)
    end
  end

  defp advance_after_action(%Brief{} = brief, chat_id, %Todo{} = todo, action) do
    brief =
      brief
      |> append_reviewed_action!(todo, action)
      |> clear_current_todo!()

    case next_unreviewed_open_todo(brief) do
      {%Todo{} = next_todo, position, total} ->
        brief = set_current_todo!(brief, next_todo.id)
        send_review_todo(chat_id, brief, next_todo, position, total)

      nil ->
        brief = complete_review!(brief)
        send_summary(chat_id, brief)
    end

    :ok
  end

  defp active_review_for_chat(user_id, chat_id) do
    Brief
    |> where([brief], brief.user_id == ^user_id)
    |> order_by([brief], desc: brief.updated_at, desc: brief.inserted_at)
    |> limit(30)
    |> Repo.all()
    |> Enum.find(fn brief ->
      review = review_metadata(brief)

      read_string(review, "status") == "active" and
        read_string(review, "chat_id") == chat_id
    end)
  end

  defp active_review_for(user_id, chat_id, todo_id) do
    Brief
    |> where([brief], brief.user_id == ^user_id)
    |> order_by([brief], desc: brief.updated_at, desc: brief.inserted_at)
    |> limit(30)
    |> Repo.all()
    |> Enum.find(fn brief ->
      review = review_metadata(brief)

      read_string(review, "status") == "active" and
        read_string(review, "chat_id") == chat_id and
        read_string(review, "current_todo_id") == todo_id
    end)
  end

  defp latest_reviewable_brief(user_id) do
    Brief
    |> where([brief], brief.user_id == ^user_id)
    |> order_by([brief],
      desc_nulls_last: brief.sent_at,
      desc: brief.updated_at,
      desc: brief.inserted_at
    )
    |> limit(50)
    |> Repo.all()
    |> Enum.find(fn brief -> linked_todo_ids(brief) != [] and review_todos(brief) != [] end)
  end

  defp build_open_todo_review_brief(user_id) do
    todos =
      user_id
      |> Todos.list_open_for_user(limit: @text_review_limit)
      |> Briefs.order_todo_digest_items(%Brief{metadata: %{}})

    with [_ | _] <- todos,
         agent_id when is_binary(agent_id) <- latest_agent_id(user_id),
         {:ok, brief} <-
           Briefs.record(user_id, agent_id, %{
             "cadence" => "check_in",
             "title" => "Open todo review",
             "summary" => "Review open todos one at a time.",
             "body" => "Natural-language Telegram todo review queue.",
             "scheduled_for" => now_iso8601(),
             "dedupe_key" => "telegram_todo_review:#{Ecto.UUID.generate()}",
             "status" => "sent",
             "metadata" => %{
               "origin" => "telegram_text_request",
               "linked_todo_ids" => Enum.map(todos, & &1.id)
             }
           }) do
      brief
    else
      _ -> nil
    end
  end

  defp latest_agent_id(user_id) do
    Agents.list_agents(user_id: user_id)
    |> List.first()
    |> case do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp send_review_todo(chat_id, %Brief{} = _brief, %Todo{} = todo, position, total) do
    payload = TodoActions.telegram_payload(todo, prefix_text: "Todo #{position} of #{total}")

    case TelegramResponder.send(chat_id, payload.text,
           parse_mode: "HTML",
           reply_markup: payload.reply_markup
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp send_summary(chat_id, %Brief{} = brief) do
    text = summary_text(brief)

    case TelegramResponder.send(chat_id, text, parse_mode: "HTML") do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp send_no_todos(chat_id) do
    text = "I don't see any open todos ready to review right now."

    case TelegramResponder.send(chat_id, text, parse_mode: "HTML") do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp send_review_canceled(chat_id) when is_binary(chat_id) do
    case TelegramResponder.send(chat_id, "Okay, I won't start a todo review.", parse_mode: "HTML") do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp send_review_canceled(_chat_id), do: :ignored

  defp ask_review_mode(attrs, intent) do
    user_id = read_string(attrs, "user_id")
    chat_id = read_id_string(attrs, "chat_id")

    with user_id when is_binary(user_id) <- user_id,
         chat_id when is_binary(chat_id) <- chat_id do
      maybe_mark_pending_clarification(attrs, intent)

      text = """
      Do you want to review your todos one at a time with action buttons, or just see the list?
      """

      case TelegramResponder.send(chat_id, String.trim(text),
             parse_mode: "HTML",
             reply_markup: review_mode_markup()
           ) do
        {:ok, _result} -> :ok
        {:error, _reason} -> :ok
      end
    else
      _ -> :ignored
    end
  end

  defp maybe_mark_pending_clarification(attrs, intent) do
    case Map.get(attrs, :conversation) || Map.get(attrs, "conversation") do
      %Maraithon.TelegramConversations.Conversation{} = conversation ->
        _ =
          Maraithon.TelegramConversations.update_metadata(conversation, %{
            "pending_clarification" => true,
            "pending_todo_review_clarification" => true,
            "last_clarifying_question" => "todo_review_mode",
            "todo_review_clarification_reason" =>
              Atom.to_string(Map.get(intent, :reason, :unknown))
          })

        :ok

      _ ->
        :ok
    end
  end

  defp review_mode_markup do
    %{
      "inline_keyboard" => [
        [
          %{"text" => "One by One", "callback_data" => latest_callback_data("start")},
          %{"text" => "Quick List", "callback_data" => latest_callback_data("list")}
        ],
        [%{"text" => "Cancel", "callback_data" => latest_callback_data("cancel")}]
      ]
    }
  end

  defp maybe_review_choice_markup([]), do: nil

  defp maybe_review_choice_markup(_todos) do
    %{
      "inline_keyboard" => [
        [%{"text" => "One by One", "callback_data" => latest_callback_data("start")}]
      ]
    }
  end

  defp summary_text(%Brief{} = brief) do
    todos = all_review_todos(brief)
    done = Enum.filter(todos, &(&1.status == "done"))
    dismissed = Enum.filter(todos, &(&1.status == "dismissed"))
    open = Enum.filter(todos, &(&1.status in @open_statuses))
    reviewed_count = length(reviewed_entries(brief))

    still_open =
      case open do
        [] ->
          "Still open: 0"

        todos ->
          lines =
            todos
            |> Enum.take(6)
            |> Enum.map(fn todo -> "• #{safe(todo.title)}" end)
            |> Enum.join("\n")

          extra =
            if length(todos) > 6 do
              "\n• #{length(todos) - 6} more still open"
            else
              ""
            end

          "Still open: #{length(todos)}\n#{lines}#{extra}"
      end

    """
    <b>Todo review complete</b>
    Reviewed: #{reviewed_count}
    Done: #{length(done)}
    Dismissed: #{length(dismissed)}
    #{still_open}

    Tomorrow's briefing will build on this: done and dismissed items stay out; still-open items can carry forward.
    """
    |> String.trim()
  end

  defp next_unreviewed_open_todo(%Brief{} = brief) do
    todos = review_todos(brief)
    reviewed_ids = reviewed_ids(brief)

    open_todos =
      Enum.reject(todos, fn todo ->
        todo.status not in @open_statuses or MapSet.member?(reviewed_ids, todo.id)
      end)

    case open_todos do
      [] ->
        nil

      [todo | _] ->
        total = review_total(brief)
        position = MapSet.size(reviewed_ids) + 1
        {todo, min(position, max(total, 1)), max(total, 1)}
    end
  end

  defp review_total(%Brief{} = brief) do
    case review_metadata(brief) do
      %{"todo_ids" => ids} when is_list(ids) and ids != [] -> length(ids)
      _ -> length(review_todos(brief))
    end
  end

  defp review_todos(%Brief{} = brief) do
    todo_ids =
      case review_metadata(brief) do
        %{"todo_ids" => ids} when is_list(ids) and ids != [] -> ids
        _ -> linked_todo_ids(brief)
      end

    brief.user_id
    |> Todos.list_by_ids(todo_ids, statuses: @open_statuses, open_due_only: true)
    |> Briefs.order_todo_digest_items(brief)
  end

  defp all_review_todos(%Brief{} = brief) do
    todo_ids =
      case review_metadata(brief) do
        %{"todo_ids" => ids} when is_list(ids) and ids != [] -> ids
        _ -> linked_todo_ids(brief)
      end

    Todos.list_by_ids(brief.user_id, todo_ids)
  end

  defp linked_todo_ids(%Brief{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("linked_todo_ids", [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp linked_todo_ids(_brief), do: []

  defp put_review!(%Brief{} = brief, review) when is_map(review) do
    metadata =
      brief.metadata
      |> Kernel.||(%{})
      |> Map.put(@review_key, review)

    brief
    |> Ecto.Changeset.change(%{metadata: metadata})
    |> Repo.update!()
  end

  defp set_current_todo!(%Brief{} = brief, todo_id) do
    review =
      brief
      |> review_metadata()
      |> Map.put("status", "active")
      |> Map.put("current_todo_id", todo_id)
      |> Map.put("updated_at", now_iso8601())

    put_review!(brief, review)
  end

  defp clear_current_todo!(%Brief{} = brief) do
    review =
      brief
      |> review_metadata()
      |> Map.delete("current_todo_id")
      |> Map.put("updated_at", now_iso8601())

    put_review!(brief, review)
  end

  defp complete_review!(%Brief{} = brief) do
    review =
      brief
      |> review_metadata()
      |> Map.put("status", "completed")
      |> Map.delete("current_todo_id")
      |> Map.put("completed_at", now_iso8601())
      |> Map.put("summary", summary_snapshot(brief))

    put_review!(brief, review)
  end

  defp append_reviewed_action!(%Brief{} = brief, %Todo{} = todo, action) do
    review = review_metadata(brief)

    reviewed =
      review
      |> Map.get("reviewed", [])
      |> List.wrap()
      |> Enum.reject(&(read_string(&1, "todo_id") == todo.id))

    entry = %{
      "todo_id" => todo.id,
      "action" => action,
      "status" => todo.status,
      "at" => now_iso8601()
    }

    put_review!(brief, Map.put(review, "reviewed", reviewed ++ [entry]))
  end

  defp summary_snapshot(%Brief{} = brief) do
    todos = all_review_todos(brief)

    %{
      "done_count" => Enum.count(todos, &(&1.status == "done")),
      "dismissed_count" => Enum.count(todos, &(&1.status == "dismissed")),
      "open_count" => Enum.count(todos, &(&1.status in @open_statuses)),
      "reviewed_count" => length(reviewed_entries(brief))
    }
  end

  defp reviewed_ids(%Brief{} = brief) do
    brief
    |> reviewed_entries()
    |> Enum.map(&read_string(&1, "todo_id"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp reviewed_entries(%Brief{} = brief) do
    case Map.get(review_metadata(brief), "reviewed") do
      entries when is_list(entries) -> Enum.filter(entries, &is_map/1)
      _ -> []
    end
  end

  defp review_metadata(%Brief{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @review_key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp review_metadata(_brief), do: %{}

  defp parse_callback(value) when is_binary(value) do
    cond do
      match =
          Regex.run(~r/^#{@callback_prefix}:([0-9a-f\-]{36}):(start)$/i, value,
            capture: :all_but_first
          ) ->
        [brief_id, action] = match
        {:ok, brief_id, String.downcase(action)}

      match =
          Regex.run(
            ~r/^#{@callback_prefix}:#{@latest_callback_id}:(start|list|cancel)$/i,
            value,
            capture: :all_but_first
          ) ->
        [action] = match
        {:ok, :latest, String.downcase(action)}

      true ->
        {:error, :invalid_callback}
    end
  end

  defp parse_callback(_value), do: {:error, :invalid_callback}

  defp callback_data(brief_id, action), do: "#{@callback_prefix}:#{brief_id}:#{action}"

  defp latest_callback_data(action), do: "#{@callback_prefix}:#{@latest_callback_id}:#{action}"

  defp maybe_answer_callback(callback_id, text)
       when is_binary(callback_id) and is_binary(text) and text != "" do
    _ = TelegramResponder.answer_callback(callback_id, text)
    :ok
  end

  defp maybe_answer_callback(_callback_id, _text), do: :ok

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp read_string(map, key, default \\ nil)

  defp read_string(map, key, default) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: default, else: value

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        Enum.find_value(map, default, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key do
              cond do
                is_binary(value) and String.trim(value) != "" -> String.trim(value)
                is_integer(value) -> Integer.to_string(value)
                true -> nil
              end
            end

          _ ->
            nil
        end)
    end
  end

  defp read_string(_map, _key, default), do: default

  defp read_id_string(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        value

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key do
              cond do
                is_binary(value) -> value
                is_integer(value) -> Integer.to_string(value)
                true -> nil
              end
            end

          _ ->
            nil
        end)
    end
  end

  defp safe(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp safe(value), do: to_string(value || "") |> safe()
end
