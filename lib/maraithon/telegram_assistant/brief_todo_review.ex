defmodule Maraithon.TelegramAssistant.BriefTodoReview do
  @moduledoc """
  Drives one-at-a-time Telegram review sessions for open work linked to a brief.
  """

  import Ecto.Query

  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.ProviderWriteOutcome
  alias Maraithon.TelegramAssistant.TodoActions
  alias Maraithon.TelegramResponder
  alias Maraithon.Todos
  alias Maraithon.Todos.UserFacingCopy
  alias Maraithon.Todos.Todo

  @callback_prefix "brftd"
  @latest_callback_id "latest"
  @review_key "todo_review"
  @open_statuses ["open", "snoozed"]
  @text_review_limit 12
  @presentation_lease_seconds 30
  @presentation_receipt_version 1
  @payload_snapshot_version 1
  @snapshot_text_max_bytes 3_800
  @snapshot_markup_max_bytes 4_000
  @checkpoint_finalize_attempts 3
  @max_presentation_attempt 1_000
  @why_now_keys ~w(why_now why_it_matters due_context)
  @evidence_keys ~w(
    source_quote quote source_excerpt body_excerpt excerpt source_evidence checked_evidence
  )
  @unsafe_review_metadata_markers ~w(
    <redacted authorization bearer dbconnection ecto. http_status internal password phoenix.
    postgrex private_key stacktrace token
  )
  @no_open_work_review_text "No saved open work is ready for review right now. " <>
                              "New commitments will appear here once Maraithon has enough context to recommend a concrete next move."
  @no_open_work_decision_text "No saved open work is ready for a decision right now."

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
    Regex.match?(~r/\b(to-?dos?|tasks?|open work|work items?|open loops?|action items?)\b/u, text)
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
      ~r/^(list|show|pull up|give me|send me|surface)\b.*\b(to-?dos?|tasks?|open work|work items?|open loops?|action items?)\b/u,
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
      %{"text" => "Review open work", "callback_data" => callback_data(brief.id, "start")}
    end
  end

  def list_button(_brief), do: nil

  def brief_buttons(%Brief{} = brief) do
    if reviewable?(brief) do
      [
        %{"text" => "Review open work", "callback_data" => callback_data(brief.id, "start")},
        %{"text" => "Show list", "callback_data" => callback_data(brief.id, "list")}
      ]
    else
      []
    end
  end

  def brief_buttons(_brief), do: []

  def handle_callback(data) when is_map(data) do
    case parse_callback(read_string(data, "data", "")) do
      {:ok, :latest, action} when action in ["start", "list", "cancel"] ->
        handle_latest_callback(data, action)

      {:ok, brief_id, action} when is_binary(brief_id) and action in ["start", "list"] ->
        handle_brief_callback(data, brief_id, action)

      {:error, :invalid_callback} ->
        :ignored
    end
  end

  def handle_callback(_data), do: :ignored

  def after_todo_action(user_id, chat_id, %Todo{} = todo, action)
      when is_binary(user_id) and is_binary(chat_id) and is_binary(action) do
    case recoverable_review_for(user_id, chat_id, todo.id) do
      %Brief{} = brief -> advance_after_action(brief, chat_id, todo, action)
      nil -> :ok
    end
  end

  def after_todo_action(_user_id, _chat_id, _todo, _action), do: :ok

  defp handle_brief_callback(data, brief_id, action) do
    chat_id = read_id_string(data, "chat_id")
    callback_id = read_string(data, "callback_id")

    with chat_id when is_binary(chat_id) <- chat_id,
         %{user_id: user_id} <-
           ConnectedAccounts.get_connected_by_external_account("telegram", chat_id),
         %Brief{} = brief <- Repo.get(Brief, brief_id),
         true <- brief.user_id == user_id do
      case action do
        "start" ->
          start_review_for_brief(brief, chat_id, callback_id: callback_id)

        "list" ->
          with :ok <- maybe_answer_callback(callback_id, "Sending the open-work list") do
            send_todo_list(chat_id, review_todos(brief), brief_review_choice_markup(brief))
          end
      end
    else
      {:error, :invalid_callback} ->
        :ignored

      _ ->
        with :ok <-
               maybe_answer_callback(
                 callback_id,
                 "That open work review is no longer available."
               ) do
          {:noop, :brief_review_not_available}
        end
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
          start_latest_review(user_id, chat_id, callback_id: callback_id)

        "list" ->
          with :ok <- maybe_answer_callback(callback_id, "Sending a quick list") do
            send_todo_list_summary(user_id, chat_id)
          end

        "cancel" ->
          maybe_answer_callback(callback_id, "Canceled")
      end
    else
      _ ->
        with :ok <-
               maybe_answer_callback(
                 callback_id,
                 "This open work review is not linked to this chat."
               ) do
          {:noop, :brief_review_chat_mismatch}
        end
    end
  end

  defp start_latest_review(user_id, chat_id, opts \\ [])

  defp start_latest_review(user_id, chat_id, opts)
       when is_binary(user_id) and is_binary(chat_id) do
    case active_review_for_chat(user_id, chat_id) do
      %Brief{} = brief ->
        with :ok <-
               maybe_answer_callback(
                 Keyword.get(opts, :callback_id),
                 "Resuming open work review"
               ) do
          resume_review(brief, chat_id)
        end

      nil ->
        case current_open_work_review_brief(user_id) || latest_reviewable_brief(user_id) do
          %Brief{} = brief ->
            start_review_for_brief(brief, chat_id, callback_id: Keyword.get(opts, :callback_id))

          nil ->
            with :ok <-
                   maybe_answer_callback(
                     Keyword.get(opts, :callback_id),
                     "No saved open work to review"
                   ) do
              send_no_todos(chat_id)
            end
        end
    end
  end

  defp start_latest_review(_user_id, _chat_id, _opts), do: :ignored

  defp send_todo_list_summary(user_id, chat_id) when is_binary(user_id) and is_binary(chat_id) do
    todos = current_review_todos(user_id)
    send_todo_list(chat_id, todos, maybe_review_choice_markup(todos))
  end

  defp send_todo_list_summary(_user_id, _chat_id), do: :ignored

  defp send_todo_list(chat_id, todos, reply_markup)
       when is_binary(chat_id) and is_list(todos) do
    text =
      case todos do
        [] ->
          @no_open_work_review_text

        todos ->
          lines =
            todos
            |> Enum.with_index(1)
            |> Enum.map(fn {todo, index} -> todo_review_line(todo, "#{index}.") end)
            |> Enum.join("\n")

          """
          Best next move: #{todo_list_next_move(todos)}

          <b>Open work</b>
          #{lines}
          """
          |> String.trim()
      end

    case TelegramResponder.send(chat_id, text,
           parse_mode: "HTML",
           reply_markup: reply_markup
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:telegram_send_failed, reason}}
    end
  end

  defp send_todo_list(_chat_id, _todos, _reply_markup), do: :ignored

  defp start_review_for_brief(%Brief{} = brief, chat_id, opts) do
    todos = review_todos(brief)
    brief = checkpoint_review_started!(brief, chat_id, todos)

    case checkpoint_next_review_step!(brief) do
      {:todo, checkpointed, %Todo{} = todo, position, total} ->
        with :ok <-
               maybe_answer_callback(
                 Keyword.get(opts, :callback_id),
                 "Sending #{position}/#{total}"
               ) do
          send_review_todo(chat_id, checkpointed, todo, position, total)
        end

      {:summary, checkpointed} ->
        with :ok <-
               maybe_answer_callback(
                 Keyword.get(opts, :callback_id),
                 "No saved open work to review"
               ) do
          send_summary(chat_id, checkpointed)
        end
    end
  end

  defp resume_review(%Brief{} = brief, chat_id) do
    case checkpoint_next_review_step!(brief) do
      {:todo, checkpointed, %Todo{} = todo, position, total} ->
        send_review_todo(chat_id, checkpointed, todo, position, total)

      {:summary, checkpointed} ->
        send_summary(chat_id, checkpointed)
    end
  end

  defp advance_after_action(%Brief{} = brief, chat_id, %Todo{} = todo, action) do
    case checkpoint_reviewed_action(brief, chat_id, todo, action) do
      {:ok, %Brief{} = checkpointed} ->
        case read_string(review_metadata(checkpointed), "status") do
          "completed" -> send_summary(chat_id, checkpointed)
          _active -> resume_review(checkpointed, chat_id)
        end

      {:noop, :review_not_current} ->
        :ok

      {:error, reason} ->
        {:error, {:brief_review_checkpoint_failed, reason}}
    end
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

  defp recoverable_review_for(user_id, chat_id, todo_id) do
    Brief
    |> where([brief], brief.user_id == ^user_id)
    |> order_by([brief], desc: brief.updated_at, desc: brief.inserted_at)
    |> limit(30)
    |> Repo.all()
    |> Enum.find(fn brief ->
      review = review_metadata(brief)
      status = read_string(review, "status")
      same_chat? = read_string(review, "chat_id") == chat_id
      current? = read_string(review, "current_todo_id") == todo_id
      reviewed? = reviewed_todo?(review, todo_id)

      same_chat? and
        ((status == "active" and (current? or reviewed?)) or
           (status == "completed" and reviewed?))
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

  defp current_open_work_review_brief(user_id) do
    todos = current_review_todos(user_id)

    case todos do
      [] ->
        nil

      todos ->
        latest = latest_reviewable_brief(user_id)

        if same_review_todos?(latest, todos) do
          latest
        else
          build_open_todo_review_brief(user_id, todos)
        end
    end
  end

  defp current_review_todos(user_id) do
    user_id
    |> Todos.list_open_for_user(limit: @text_review_limit)
    |> Briefs.order_todo_digest_items(%Brief{metadata: %{}})
  end

  defp same_review_todos?(%Brief{} = brief, todos) when is_list(todos) do
    brief_ids = brief |> review_todos() |> Enum.map(& &1.id) |> MapSet.new()
    current_ids = todos |> Enum.map(& &1.id) |> MapSet.new()

    MapSet.equal?(brief_ids, current_ids)
  end

  defp same_review_todos?(_brief, _todos), do: false

  defp build_open_todo_review_brief(user_id, todos) do
    with [_ | _] <- todos,
         agent_id when is_binary(agent_id) <- latest_agent_id(user_id),
         {:ok, brief} <-
           Briefs.record(user_id, agent_id, %{
             "cadence" => "check_in",
             "title" => "Open work review",
             "summary" => "Decide on open work one item at a time.",
             "body" => "Telegram review session for deciding current open work.",
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

  defp send_review_todo(chat_id, %Brief{} = brief, %Todo{} = todo, position, total) do
    case claim_review_presentation(brief, "todo", todo.id) do
      {:terminal, _current} ->
        :ok

      {:in_progress, delivery_key} ->
        {:error, {:brief_review_delivery_in_progress, delivery_key}}

      {:claimed, current, claim_token} ->
        deliver_claimed_review_presentation(
          current,
          "todo",
          todo.id,
          claim_token,
          fn armed ->
            payload = review_item_payload(armed, todo, position, total)

            TelegramResponder.send(chat_id, payload.text,
              parse_mode: "HTML",
              reply_markup: payload.reply_markup
            )
          end
        )

      {:error, reason} ->
        {:error, {:brief_review_delivery_checkpoint_failed, reason}}
    end
  end

  defp send_summary(chat_id, %Brief{} = brief) do
    case claim_review_presentation(brief, "summary", brief.id) do
      {:terminal, _current} ->
        :ok

      {:in_progress, delivery_key} ->
        {:error, {:brief_review_delivery_in_progress, delivery_key}}

      {:claimed, current, claim_token} ->
        deliver_claimed_review_presentation(
          current,
          "summary",
          current.id,
          claim_token,
          fn armed -> TelegramResponder.send(chat_id, summary_text(armed), parse_mode: "HTML") end
        )

      {:error, reason} ->
        {:error, {:brief_review_delivery_checkpoint_failed, reason}}
    end
  end

  defp send_no_todos(chat_id) do
    text = @no_open_work_review_text

    case TelegramResponder.send(chat_id, text, parse_mode: "HTML") do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:telegram_send_failed, reason}}
    end
  end

  defp send_review_canceled(chat_id) when is_binary(chat_id) do
    case TelegramResponder.send(chat_id, "Open work review canceled. Nothing changed.",
           parse_mode: "HTML"
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:telegram_send_failed, reason}}
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
      Do you want to decide one item at a time, or scan the list first?
      """

      case TelegramResponder.send(chat_id, String.trim(text),
             parse_mode: "HTML",
             reply_markup: review_mode_markup()
           ) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, {:telegram_send_failed, reason}}
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
          %{"text" => "Decide one by one", "callback_data" => latest_callback_data("start")},
          %{"text" => "Show list", "callback_data" => latest_callback_data("list")}
        ],
        [%{"text" => "Cancel", "callback_data" => latest_callback_data("cancel")}]
      ]
    }
  end

  defp maybe_review_choice_markup([]), do: nil

  defp maybe_review_choice_markup(_todos) do
    %{
      "inline_keyboard" => [
        [%{"text" => "Decide one by one", "callback_data" => latest_callback_data("start")}]
      ]
    }
  end

  defp brief_review_choice_markup(%Brief{} = brief) do
    %{
      "inline_keyboard" => [
        [%{"text" => "Decide one by one", "callback_data" => callback_data(brief.id, "start")}]
      ]
    }
  end

  defp summary_text(%Brief{} = brief) do
    review = review_metadata(brief)
    payload = read_map(review, "summary_payload")

    case {Map.get(payload, "snapshot_version"), read_string(payload, "text")} do
      {@payload_snapshot_version, text}
      when is_binary(text) and byte_size(text) <= @snapshot_text_max_bytes ->
        text

      _missing ->
        build_summary_text(brief, review)
    end
  end

  defp build_summary_text(%Brief{} = brief, review) when is_map(review) do
    todos = all_review_todos(brief)
    done = Enum.filter(todos, &(&1.status == "done"))
    dismissed = Enum.filter(todos, &(&1.status == "dismissed"))
    open = Enum.filter(todos, &(&1.status in @open_statuses))
    reviewed_count = length(reviewed_entries_from_review(review))

    remaining =
      case open do
        [] ->
          "Still open: 0"

        todos ->
          lines =
            todos
            |> Enum.take(6)
            |> Enum.map(fn todo -> todo_review_line(todo, "•") end)
            |> Enum.join("\n")

          extra =
            if length(todos) > 6 do
              "\n• #{length(todos) - 6} more still open"
            else
              ""
            end

          "Still open: #{length(todos)}\n#{lines}#{extra}"
      end

    cleared_count = length(done) + length(dismissed)

    """
    <b>Open work review finished</b>
    Decisions made: #{reviewed_count}
    Cleared: #{cleared_count} (#{length(done)} done, #{length(dismissed)} dismissed)
    #{remaining}

    Done and dismissed items are off future briefs. Anything still open remains visible until it is marked done, snoozed, kept active, or dismissed.
    """
    |> String.trim()
    |> Maraithon.PromptBudget.truncate_utf8(@snapshot_text_max_bytes)
  end

  defp next_unreviewed_open_todo(%Brief{} = brief) do
    todos = review_todos(brief)
    reviewed_ids = reviewed_ids(brief)
    review = review_metadata(brief)

    open_todos =
      Enum.reject(todos, fn todo ->
        todo.status not in @open_statuses or MapSet.member?(reviewed_ids, todo.id)
      end)

    pinned_todo =
      case read_string(review, "current_todo_id") do
        todo_id when is_binary(todo_id) -> Enum.find(open_todos, &(&1.id == todo_id))
        _missing -> nil
      end

    case pinned_todo || List.first(open_todos) do
      nil ->
        nil

      %Todo{} = todo ->
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

  defp todo_review_line(todo, marker) do
    todo = UserFacingCopy.polish_attrs(todo)
    title = todo_title(todo)

    [
      "#{marker} #{safe(title)}",
      todo_why_now_line(todo),
      todo_next_action_line(todo, title),
      todo_evidence_line(todo)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp todo_title(todo) do
    todo
    |> read_string("title", "Open work")
    |> UserFacingCopy.polish_text()
  end

  defp todo_list_next_move([todo | _todos]) do
    focus = todo |> todo_list_focus() |> todo_list_sentence() |> safe()

    "#{focus} Then decide each remaining item: mark it done, snooze it, keep it active, or dismiss it."
  end

  defp todo_list_next_move(_todos), do: @no_open_work_decision_text

  defp todo_list_sentence(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> "Start with the first open item and choose the outcome."
      Regex.match?(~r/[.!?]\z/u, value) -> value
      true -> value <> "."
    end
  end

  defp todo_list_focus(todo) do
    todo = UserFacingCopy.polish_attrs(todo)
    title = todo_title(todo)
    next_action = todo_next_action(todo)

    cond do
      is_nil(next_action) -> title
      generic_list_action?(next_action) -> title
      true -> next_action
    end
  end

  defp generic_list_action?(value) when is_binary(value) do
    Regex.match?(~r/^(reply|respond)\s+in[-\s]?thread\b/i, String.trim(value))
  end

  defp generic_list_action?(_value), do: false

  defp todo_next_action(todo) do
    next_action =
      todo
      |> read_string("next_action")
      |> UserFacingCopy.polish_text()

    title = todo_title(todo)

    cond do
      is_nil(next_action) -> nil
      same_text?(next_action, title) -> nil
      true -> next_action
    end
  end

  defp todo_next_action_line(todo, title) do
    case todo_next_action(todo) do
      nil -> nil
      next_action when is_binary(title) and next_action == title -> nil
      next_action -> "   Next: #{safe(truncate(next_action, 220))}"
    end
  end

  defp todo_why_now_line(todo) do
    case first_metadata_text(todo, @why_now_keys) || todo_summary(todo) do
      nil -> nil
      why_now -> "   Why now: #{safe(truncate(why_now, 180))}"
    end
  end

  defp todo_evidence_line(todo) do
    case first_metadata_text(todo, @evidence_keys) ||
           public_metadata_text(read_string(todo, "notes")) do
      nil -> nil
      evidence -> "   Evidence: #{safe(truncate(evidence, 180))}"
    end
  end

  defp todo_summary(todo) do
    summary = public_metadata_text(read_string(todo, "summary"))
    title = todo_title(todo)
    next_action = todo_next_action(todo)

    cond do
      is_nil(summary) -> nil
      same_text?(summary, title) -> nil
      same_text?(summary, next_action) -> nil
      true -> summary
    end
  end

  defp first_metadata_text(todo, keys) when is_list(keys) do
    metadata = todo_metadata(todo)

    Enum.find_value(keys, fn key ->
      metadata
      |> metadata_value(key)
      |> public_metadata_text()
    end)
  end

  defp todo_metadata(%Todo{metadata: metadata}) when is_map(metadata), do: metadata
  defp todo_metadata(%Todo{}), do: %{}

  defp todo_metadata(todo) when is_map(todo) do
    case Map.get(todo, "metadata") || Map.get(todo, :metadata) do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end

  defp todo_metadata(_todo), do: %{}

  defp metadata_value(metadata, key) when is_map(metadata) and is_binary(key) do
    Map.get(metadata, key) ||
      case existing_atom_key(key) do
        nil -> nil
        atom_key -> Map.get(metadata, atom_key)
      end
  end

  defp metadata_value(_metadata, _key), do: nil

  defp public_metadata_text(value) when is_binary(value) do
    value =
      value
      |> Maraithon.Redaction.redact_string()
      |> UserFacingCopy.polish_text()
      |> String.trim()

    if value != "" and public_review_metadata_text?(value), do: value
  end

  defp public_metadata_text(values) when is_list(values) do
    Enum.find_value(values, &public_metadata_text/1)
  end

  defp public_metadata_text(value) when is_map(value) do
    Enum.find_value(~w(excerpt text quote summary body), fn key ->
      value
      |> metadata_value(key)
      |> public_metadata_text()
    end)
  end

  defp public_metadata_text(_value), do: nil

  defp public_review_metadata_text?(value) when is_binary(value) do
    lower = String.downcase(value)
    not Enum.any?(@unsafe_review_metadata_markers, &String.contains?(lower, &1))
  end

  defp public_review_metadata_text?(_value), do: false

  defp same_text?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(left) == String.downcase(right)
  end

  defp same_text?(_left, _right), do: false

  defp review_item_payload(%Brief{} = brief, %Todo{} = todo, position, total) do
    review = review_metadata(brief)
    snapshot = read_map(review, "current_item_snapshot")

    if valid_item_payload_snapshot?(snapshot, todo.id) do
      payload = read_map(snapshot, "payload")

      %{
        text: read_string(payload, "text"),
        reply_markup: read_map_or_nil(payload, "reply_markup")
      }
    else
      live_review_item_payload(todo, position, total)
    end
  end

  defp live_review_item_payload(%Todo{} = todo, position, total) do
    TodoActions.telegram_payload(todo,
      prefix_text: "Open work decision #{position} of #{total}"
    )
  end

  defp item_payload_snapshot(%Todo{} = todo, position, total) do
    payload = live_review_item_payload(todo, position, total)

    text =
      if is_binary(payload.text) and byte_size(payload.text) <= @snapshot_text_max_bytes do
        payload.text
      else
        fallback_review_item_text(todo, position, total)
      end

    %{
      "snapshot_version" => @payload_snapshot_version,
      "todo_id" => todo.id,
      "position" => position,
      "total" => total,
      "payload" => %{
        "text" => text,
        "reply_markup" => bounded_reply_markup(payload.reply_markup)
      }
    }
  end

  defp fallback_review_item_text(%Todo{} = todo, position, total) do
    title = todo |> todo_title() |> Maraithon.PromptBudget.truncate_utf8(800) |> safe()

    "Open work decision #{position} of #{total}\n#{title}"
    |> Maraithon.PromptBudget.truncate_utf8(@snapshot_text_max_bytes)
  end

  defp bounded_reply_markup(%{"inline_keyboard" => rows}) when is_list(rows) do
    keyboard =
      rows
      |> Enum.take(8)
      |> Enum.map(fn row ->
        row
        |> List.wrap()
        |> Enum.take(4)
        |> Enum.map(&bounded_reply_button/1)
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.reject(&(&1 == []))

    markup = if keyboard == [], do: nil, else: %{"inline_keyboard" => keyboard}

    if bounded_json?(markup, @snapshot_markup_max_bytes), do: markup
  end

  defp bounded_reply_markup(_markup), do: nil

  defp bounded_reply_button(button) when is_map(button) do
    text =
      button
      |> read_string("text")
      |> bounded_snapshot_string(96)

    callback_data =
      button
      |> read_string("callback_data")
      |> bounded_snapshot_string(256)

    url =
      button
      |> read_string("url")
      |> bounded_snapshot_string(1_024)

    cond do
      is_nil(text) -> nil
      is_binary(callback_data) -> %{"text" => text, "callback_data" => callback_data}
      is_binary(url) -> %{"text" => text, "url" => url}
      true -> nil
    end
  end

  defp bounded_reply_button(_button), do: nil

  defp bounded_snapshot_string(value, max_bytes) when is_binary(value) do
    value = Maraithon.PromptBudget.truncate_utf8(value, max_bytes)
    if value == "", do: nil, else: value
  end

  defp bounded_snapshot_string(_value, _max_bytes), do: nil

  defp bounded_json?(nil, _max_bytes), do: true

  defp bounded_json?(value, max_bytes) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded) <= max_bytes
      {:error, _reason} -> false
    end
  end

  defp valid_item_payload_snapshot?(snapshot, todo_id) do
    payload = read_map(snapshot, "payload")
    text = read_string(payload, "text")
    markup = Map.get(payload, "reply_markup")

    Map.get(snapshot, "snapshot_version") == @payload_snapshot_version and
      read_string(snapshot, "todo_id") == todo_id and is_binary(text) and text != "" and
      byte_size(text) <= @snapshot_text_max_bytes and
      bounded_json?(markup, @snapshot_markup_max_bytes)
  end

  defp read_map_or_nil(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _missing -> nil
    end
  end

  defp claim_review_presentation(%Brief{} = brief, kind, item_id) do
    Repo.transaction(fn ->
      current = lock_brief(brief.id) || Repo.rollback(:brief_not_found)
      review = review_metadata(current)
      presentation = review_presentation(review)
      delivery_key = review_delivery_key(current.id, kind, item_id)

      cond do
        not valid_review_presentation?(current, review, kind, item_id) ->
          Repo.rollback(:review_presentation_not_current)

        terminal_review_presentation?(presentation, delivery_key) ->
          {:terminal, current}

        legacy_missing_review_receipt?(review, presentation) ->
          {:terminal, current}

        active_review_presentation_claim?(presentation, delivery_key) ->
          {:in_progress, delivery_key}

        expired_started_review_presentation?(presentation, delivery_key) ->
          unknown =
            presentation
            |> terminal_review_presentation("outcome_unknown")
            |> Map.merge(ProviderWriteOutcome.expired_write_error_fields())
            |> Map.put("receipt_version", @presentation_receipt_version)
            |> Map.put("unknown_at", now_iso8601())

          case put_review_presentation(current, review, unknown) do
            {:ok, updated} -> {:terminal, updated}
            {:error, reason} -> Repo.rollback(reason)
          end

        true ->
          claim_token = Ecto.UUID.generate()
          now = DateTime.utc_now()

          claimed = %{
            "kind" => kind,
            "item_id" => item_id,
            "status" => "claimed",
            "delivery_key" => delivery_key,
            "claim_token" => claim_token,
            "attempt" => next_presentation_attempt(presentation),
            "claimed_at" => DateTime.to_iso8601(now),
            "lease_until" =>
              now
              |> DateTime.add(@presentation_lease_seconds, :second)
              |> DateTime.to_iso8601()
          }

          case put_review_presentation(current, review, claimed) do
            {:ok, updated} -> {:claimed, updated, claim_token}
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, {:terminal, %Brief{} = current}} ->
        {:terminal, current}

      {:ok, {:in_progress, delivery_key}} ->
        {:in_progress, delivery_key}

      {:ok, {:claimed, %Brief{} = current, claim_token}} ->
        {:claimed, current, claim_token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver_claimed_review_presentation(
         %Brief{} = brief,
         kind,
         item_id,
         claim_token,
         writer
       )
       when is_function(writer, 1) do
    case arm_review_presentation_write(brief, kind, item_id, claim_token) do
      {:terminal, _current} ->
        :ok

      {:ok, armed} ->
        case writer.(armed) do
          {:ok, result} ->
            finalize_review_presentation_after_write(
              armed,
              kind,
              item_id,
              claim_token,
              result
            )

          {:error, reason} ->
            resolve_review_presentation_write_error(
              armed,
              kind,
              item_id,
              claim_token,
              reason
            )

          _other ->
            mark_review_presentation_unknown(
              armed,
              kind,
              item_id,
              claim_token,
              ProviderWriteOutcome.invalid_response_error_fields()
            )
        end

      {:error, reason} ->
        {:error, {:brief_review_delivery_checkpoint_failed, reason}}
    end
  end

  defp arm_review_presentation_write(%Brief{} = brief, kind, item_id, claim_token) do
    mutate_claimed_review_presentation(
      brief,
      kind,
      item_id,
      claim_token,
      "claimed",
      fn presentation ->
        now = DateTime.utc_now()

        presentation
        |> Map.put("status", "delivering")
        |> Map.put("write_started_at", DateTime.to_iso8601(now))
        |> Map.put(
          "lease_until",
          now
          |> DateTime.add(@presentation_lease_seconds, :second)
          |> DateTime.to_iso8601()
        )
      end
    )
    |> case do
      {:ok, %Brief{} = updated} -> {:ok, updated}
      {:terminal, %Brief{} = current} -> {:terminal, current}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_review_presentation_after_write(
         %Brief{} = brief,
         kind,
         item_id,
         claim_token,
         result
       ) do
    finalizer = fn ->
      finalize_review_presentation(brief, kind, item_id, claim_token, result)
    end

    case retry_review_checkpoint(finalizer, @checkpoint_finalize_attempts) do
      :ok ->
        :ok

      {:error, _reason} ->
        mark_review_presentation_unknown(
          brief,
          kind,
          item_id,
          claim_token,
          ProviderWriteOutcome.local_checkpoint_error_fields()
        )
    end
  end

  defp finalize_review_presentation(
         %Brief{} = brief,
         kind,
         item_id,
         claim_token,
         result
       ) do
    mutate_claimed_review_presentation(
      brief,
      kind,
      item_id,
      claim_token,
      "delivering",
      fn presentation ->
        presentation
        |> terminal_review_presentation("delivered")
        |> Map.put("receipt_version", @presentation_receipt_version)
        |> Map.put("provider_message_id", read_id_string(result, "message_id"))
        |> Map.put("delivered_at", now_iso8601())
      end
    )
    |> normalize_review_mutation_result()
  end

  defp resolve_review_presentation_write_error(
         %Brief{} = brief,
         kind,
         item_id,
         claim_token,
         reason
       ) do
    if ProviderWriteOutcome.ambiguous_write_error?(reason) do
      mark_review_presentation_unknown(
        brief,
        kind,
        item_id,
        claim_token,
        ProviderWriteOutcome.error_fields(reason)
      )
    else
      case fail_review_presentation(brief, kind, item_id, claim_token, reason) do
        :ok -> {:error, {:telegram_send_failed, reason}}
        {:error, _checkpoint_reason} = error -> error
      end
    end
  end

  defp mark_review_presentation_unknown(
         %Brief{} = brief,
         kind,
         item_id,
         claim_token,
         error_fields
       ) do
    marker = fn ->
      mutate_claimed_review_presentation(
        brief,
        kind,
        item_id,
        claim_token,
        "delivering",
        fn presentation ->
          presentation
          |> terminal_review_presentation("outcome_unknown")
          |> Map.merge(error_fields)
          |> Map.put("receipt_version", @presentation_receipt_version)
          |> Map.put("unknown_at", now_iso8601())
        end
      )
      |> normalize_review_mutation_result()
    end

    case retry_review_checkpoint(marker, @checkpoint_finalize_attempts) do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error, {:brief_review_delivery_checkpoint_failed, :outcome_unknown_not_committed}}
    end
  end

  defp fail_review_presentation(%Brief{} = brief, kind, item_id, claim_token, reason) do
    mutate_claimed_review_presentation(
      brief,
      kind,
      item_id,
      claim_token,
      "delivering",
      fn presentation ->
        presentation
        |> terminal_review_presentation("failed")
        |> Map.merge(ProviderWriteOutcome.error_fields(reason))
        |> Map.put("failed_at", now_iso8601())
      end
    )
    |> normalize_review_mutation_result()
  end

  defp mutate_claimed_review_presentation(
         %Brief{} = brief,
         kind,
         item_id,
         claim_token,
         expected_status,
         mutation
       )
       when is_function(mutation, 1) do
    Repo.transaction(fn ->
      current = lock_brief(brief.id) || Repo.rollback(:brief_not_found)
      review = review_metadata(current)
      presentation = review_presentation(review)
      delivery_key = review_delivery_key(current.id, kind, item_id)

      cond do
        terminal_review_presentation?(presentation, delivery_key) ->
          {:terminal, current}

        not valid_review_presentation?(current, review, kind, item_id) ->
          Repo.rollback(:review_presentation_not_current)

        read_string(presentation, "delivery_key") != delivery_key or
          read_string(presentation, "status") != expected_status or
            read_string(presentation, "claim_token") != claim_token ->
          Repo.rollback(:review_presentation_claim_lost)

        true ->
          case put_review_presentation(current, review, mutation.(presentation)) do
            {:ok, updated} -> {:ok, updated}
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, {:ok, %Brief{} = updated}} -> {:ok, updated}
      {:ok, {:terminal, %Brief{} = current}} -> {:terminal, current}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_review_mutation_result({:ok, %Brief{}}), do: :ok
  defp normalize_review_mutation_result({:terminal, %Brief{}}), do: :ok

  defp normalize_review_mutation_result({:error, reason}),
    do: {:error, {:brief_review_delivery_checkpoint_failed, reason}}

  defp retry_review_checkpoint(fun, attempts) when is_function(fun, 0) and attempts > 1 do
    case fun.() do
      :ok -> :ok
      {:error, _reason} -> retry_review_checkpoint(fun, attempts - 1)
    end
  end

  defp retry_review_checkpoint(fun, 1) when is_function(fun, 0), do: fun.()

  defp terminal_review_presentation(presentation, status) do
    presentation
    |> Map.take([
      "kind",
      "item_id",
      "delivery_key",
      "attempt",
      "claimed_at",
      "write_started_at"
    ])
    |> Map.put("status", status)
  end

  defp review_delivery_key(brief_id, kind, item_id),
    do: "brief-review:#{brief_id}:#{kind}:#{item_id}"

  defp next_presentation_attempt(presentation) do
    case Map.get(presentation, "attempt") do
      attempt when is_integer(attempt) and attempt >= 0 ->
        min(attempt + 1, @max_presentation_attempt)

      _missing ->
        1
    end
  end

  defp legacy_missing_review_receipt?(review, presentation) do
    not is_integer(Map.get(review, "presentation_receipt_version")) and
      map_size(presentation) == 0
  end

  defp expired_started_review_presentation?(presentation, delivery_key) do
    read_string(presentation, "delivery_key") == delivery_key and
      read_string(presentation, "status") == "delivering" and
      not future_iso8601?(read_string(presentation, "lease_until"))
  end

  defp valid_review_presentation?(%Brief{} = brief, review, kind, item_id) do
    case kind do
      "todo" ->
        read_string(review, "status") == "active" and
          read_string(review, "current_todo_id") == item_id

      "summary" ->
        read_string(review, "status") == "completed" and item_id == brief.id

      _other ->
        false
    end
  end

  defp terminal_review_presentation?(presentation, delivery_key) do
    read_string(presentation, "delivery_key") == delivery_key and
      read_string(presentation, "status") in ["delivered", "outcome_unknown"]
  end

  defp active_review_presentation_claim?(presentation, delivery_key) do
    read_string(presentation, "delivery_key") == delivery_key and
      read_string(presentation, "status") in ["claimed", "delivering"] and
      future_iso8601?(read_string(presentation, "lease_until"))
  end

  defp future_iso8601?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.compare(datetime, DateTime.utc_now()) == :gt
      _invalid -> false
    end
  end

  defp future_iso8601?(_value), do: false

  defp review_presentation(review) when is_map(review) do
    case Map.get(review, "presentation") do
      value when is_map(value) -> value
      _missing -> %{}
    end
  end

  defp put_review_presentation(%Brief{} = brief, review, presentation) do
    updated_review = Map.put(review, "presentation", presentation)
    metadata = Map.put(brief.metadata || %{}, @review_key, updated_review)

    brief
    |> Ecto.Changeset.change(metadata: metadata)
    |> Repo.update()
  end

  defp lock_brief(brief_id) do
    Brief
    |> where([candidate], candidate.id == ^brief_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp linked_todo_ids(%Brief{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("linked_todo_ids", [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp linked_todo_ids(_brief), do: []

  defp checkpoint_review_started!(%Brief{} = brief, chat_id, todos) do
    Repo.transaction(fn ->
      current = lock_brief(brief.id) || Repo.rollback(:brief_not_found)
      existing = review_metadata(current)

      if read_string(existing, "status") == "active" and
           read_string(existing, "chat_id") == chat_id do
        current
      else
        review = %{
          "status" => "active",
          "chat_id" => chat_id,
          "started_at" => now_iso8601(),
          "todo_ids" => Enum.map(todos, & &1.id),
          "reviewed" => []
        }

        metadata = Map.put(current.metadata || %{}, @review_key, review)

        current
        |> Ecto.Changeset.change(metadata: metadata)
        |> Repo.update!()
      end
    end)
    |> case do
      {:ok, %Brief{} = current} -> current
      {:error, reason} -> raise "brief review start checkpoint failed: #{inspect(reason)}"
    end
  end

  defp checkpoint_next_review_step!(%Brief{} = brief) do
    Repo.transaction(fn ->
      current = lock_brief(brief.id) || Repo.rollback(:brief_not_found)
      review = review_metadata(current)

      if read_string(review, "status") == "completed" do
        {:summary, current}
      else
        case next_unreviewed_open_todo(current) do
          {%Todo{} = todo, position, total} ->
            same_current? = read_string(review, "current_todo_id") == todo.id

            updated_review =
              review
              |> Map.put("status", "active")
              |> Map.put("current_todo_id", todo.id)
              |> Map.put("updated_at", now_iso8601())

            updated_review =
              cond do
                not same_current? ->
                  updated_review
                  |> Map.put("presentation_receipt_version", @presentation_receipt_version)
                  |> Map.put(
                    "current_item_snapshot",
                    item_payload_snapshot(todo, position, total)
                  )
                  |> Map.delete("presentation")

                is_integer(Map.get(review, "presentation_receipt_version")) and
                    not valid_item_payload_snapshot?(
                      read_map(review, "current_item_snapshot"),
                      todo.id
                    ) ->
                  Map.put(
                    updated_review,
                    "current_item_snapshot",
                    item_payload_snapshot(todo, position, total)
                  )

                true ->
                  # Missing version/snapshot is a rollout-era completion
                  # receipt. Preserve it so replay drains instead of sending a
                  # card which may already have reached Telegram.
                  updated_review
              end

            metadata = Map.put(current.metadata || %{}, @review_key, updated_review)

            updated =
              current
              |> Ecto.Changeset.change(metadata: metadata)
              |> Repo.update!()

            {:todo, updated, todo, position, total}

          nil ->
            completed_review =
              review
              |> Map.put("status", "completed")
              |> Map.put("presentation_receipt_version", @presentation_receipt_version)
              |> Map.delete("current_todo_id")
              |> Map.delete("current_item_snapshot")
              |> Map.delete("presentation")
              |> Map.put("completed_at", now_iso8601())
              |> Map.put("summary", summary_snapshot(current))

            completed_review =
              Map.put(
                completed_review,
                "summary_payload",
                summary_payload_snapshot(current, completed_review)
              )

            metadata = Map.put(current.metadata || %{}, @review_key, completed_review)

            updated =
              current
              |> Ecto.Changeset.change(metadata: metadata)
              |> Repo.update!()

            {:summary, updated}
        end
      end
    end)
    |> case do
      {:ok, {:todo, %Brief{} = current, %Todo{} = todo, position, total}} ->
        {:todo, current, todo, position, total}

      {:ok, {:summary, %Brief{} = current}} ->
        {:summary, current}

      {:error, reason} ->
        raise "brief review advancement checkpoint failed: #{inspect(reason)}"
    end
  end

  defp checkpoint_reviewed_action(%Brief{} = brief, chat_id, %Todo{} = todo, action) do
    Repo.transaction(fn ->
      current =
        Brief
        |> where([candidate], candidate.id == ^brief.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case current do
        nil ->
          Repo.rollback(:brief_not_found)

        %Brief{} = current ->
          review = review_metadata(current)
          status = read_string(review, "status")
          same_chat? = read_string(review, "chat_id") == chat_id
          current_todo? = read_string(review, "current_todo_id") == todo.id
          reviewed? = reviewed_todo?(review, todo.id)

          cond do
            not same_chat? ->
              {:noop, :review_not_current}

            status == "completed" and reviewed? ->
              {:ok, current}

            status == "active" and reviewed? ->
              {:ok, current}

            status == "active" and current_todo? ->
              reviewed =
                review
                |> Map.get("reviewed", [])
                |> List.wrap()
                |> Enum.filter(&is_map/1)

              entry = %{
                "todo_id" => todo.id,
                "action" => action,
                "status" => todo.status,
                "at" => now_iso8601()
              }

              updated_review =
                review
                |> Map.put("reviewed", reviewed ++ [entry])
                |> Map.delete("current_todo_id")
                |> Map.delete("presentation")
                |> Map.put("updated_at", now_iso8601())

              metadata =
                (current.metadata || %{})
                |> Map.put(@review_key, updated_review)

              case current
                   |> Ecto.Changeset.change(metadata: metadata)
                   |> Repo.update() do
                {:ok, updated} -> {:ok, updated}
                {:error, reason} -> Repo.rollback(reason)
              end

            true ->
              {:noop, :review_not_current}
          end
      end
    end)
    |> case do
      {:ok, {:ok, %Brief{} = current}} -> {:ok, current}
      {:ok, {:noop, reason}} -> {:noop, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reviewed_todo?(review, todo_id) when is_map(review) and is_binary(todo_id) do
    review
    |> Map.get("reviewed", [])
    |> List.wrap()
    |> Enum.any?(&(read_string(&1, "todo_id") == todo_id))
  end

  defp reviewed_todo?(_review, _todo_id), do: false

  defp summary_snapshot(%Brief{} = brief) do
    todos = all_review_todos(brief)

    %{
      "done_count" => Enum.count(todos, &(&1.status == "done")),
      "dismissed_count" => Enum.count(todos, &(&1.status == "dismissed")),
      "open_count" => Enum.count(todos, &(&1.status in @open_statuses)),
      "reviewed_count" => length(reviewed_entries(brief))
    }
  end

  defp summary_payload_snapshot(%Brief{} = brief, review) when is_map(review) do
    %{
      "snapshot_version" => @payload_snapshot_version,
      "text" => build_summary_text(brief, review)
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
    brief
    |> review_metadata()
    |> reviewed_entries_from_review()
  end

  defp reviewed_entries_from_review(review) when is_map(review) do
    case Map.get(review, "reviewed") do
      entries when is_list(entries) -> Enum.filter(entries, &is_map/1)
      _ -> []
    end
  end

  defp reviewed_entries_from_review(_review), do: []

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
          Regex.run(~r/^#{@callback_prefix}:([0-9a-f\-]{36}):(start|list)$/i, value,
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
    case TelegramResponder.answer_callback(callback_id, text) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        if ProviderWriteOutcome.callback_terminal_drained?(reason) do
          :ok
        else
          {:error, {:telegram_callback_answer_failed, reason}}
        end

      other ->
        {:error, {:invalid_telegram_callback_answer_result, other}}
    end
  end

  defp maybe_answer_callback(_callback_id, _text), do: :ok

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp read_string(map, key, default \\ nil)

  defp read_string(map, key, default) when is_map(map) and is_binary(key) do
    value =
      Map.get(map, key) ||
        case existing_atom_key(key) do
          nil -> nil
          atom_key -> Map.get(map, atom_key)
        end

    case value do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: default, else: value

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        default
    end
  end

  defp read_string(_map, _key, default), do: default

  defp read_map(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _missing -> %{}
    end
  end

  defp read_map(_map, _key), do: %{}

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

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

  defp truncate(value, max_length) when is_binary(value) and is_integer(max_length) do
    value = String.trim(value)

    if String.length(value) <= max_length do
      value
    else
      value
      |> String.slice(0, max(max_length - 3, 0))
      |> String.trim_trailing()
      |> Kernel.<>("...")
    end
  end

  defp truncate(value, _max_length), do: to_string(value || "")
end
