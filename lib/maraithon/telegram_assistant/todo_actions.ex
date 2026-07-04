defmodule Maraithon.TelegramAssistant.TodoActions do
  @moduledoc """
  Telegram-native rendering and callback handling for assistant todo items.
  """

  alias Maraithon.AppUrl
  alias Maraithon.ActionCards
  alias Maraithon.AssistantChat.TodoThreadPrimer
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Drafts
  alias Maraithon.SourceLabels
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.ActionFailureCopy
  alias Maraithon.TelegramAssistant.BriefTodoReview
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.TelegramResponder
  alias Maraithon.Todos
  alias Maraithon.Todos.{ActionDrafts, PublicMetadata, Todo, UserFacingCopy}

  @callback_prefix "tgtodo"
  @feedback_values ~w(important helpful not_helpful see_less)
  @record_feedback_values ~w(helpful not_helpful)

  def telegram_payload(todo) when is_map(todo) do
    telegram_payload(todo, [])
  end

  def telegram_payload(todo, opts) when is_map(todo) and is_list(opts) do
    %{
      text: render_message(todo, opts),
      reply_markup: build_reply_markup(todo, opts)
    }
  end

  def handle_callback(data) when is_map(data) do
    callback_id = read_string(data, "callback_id")
    chat_id = read_id_string(data, "chat_id")
    message_id = read_id_string(data, "message_id")

    with {:ok, todo_id, action} <- parse_callback(read_string(data, "data", "")),
         chat_id when is_binary(chat_id) <- chat_id,
         %{user_id: user_id} <-
           ConnectedAccounts.get_connected_by_external_account("telegram", chat_id),
         {:ok, todo} <- Todos.get_for_user(user_id, todo_id) |> fetch_todo(),
         {:ok, result} <- dispatch_action(user_id, chat_id, todo, action) do
      case result do
        {:todo_updated, updated_todo} ->
          :ok = refresh_message(chat_id, message_id, updated_todo)
          maybe_answer_callback(callback_id, callback_notice(action))
          _ = BriefTodoReview.after_todo_action(user_id, chat_id, updated_todo, action)
          :ok

        {:draft_ready, draft_text, updated_todo} ->
          :ok = send_draft(chat_id, message_id, draft_text)
          :ok = refresh_message(chat_id, message_id, updated_todo)
          maybe_answer_callback(callback_id, callback_notice(action))
          :ok

        {:send_prepared, prepared_action} ->
          :ok = send_confirmation_prompt(chat_id, message_id, prepared_action)
          # SPEC 06 review finding #2: without this, the card's Send button
          # stays rendered exactly as before the tap, inviting a second tap
          # (and, pre-dedupe-fix, a second independent prepared action/send).
          # Re-rendering here picks up `awaiting_send_confirmation?/1` below so
          # the button reflects the confirmation now pending.
          :ok = refresh_message(chat_id, message_id, todo)
          maybe_answer_callback(callback_id, callback_notice(action))
          :ok
      end
    else
      {:error, :invalid_callback} ->
        :ignored

      {:error, :not_found} ->
        maybe_answer_callback(callback_id, ActionFailureCopy.todo_callback(:not_found))
        :ok

      {:error, reason} ->
        maybe_answer_callback(callback_id, ActionFailureCopy.todo_callback(reason))
        :ok

      _ ->
        maybe_answer_callback(callback_id, ActionFailureCopy.todo_callback(:chat_mismatch))
        :ok
    end
  end

  def handle_callback(_data), do: :ignored

  def parse_callback(""), do: {:error, :invalid_callback}

  def parse_callback(value) when is_binary(value) do
    case Regex.run(
           ~r/^#{@callback_prefix}:([0-9a-f\-]{36}):(done|dismiss|snooze|important|helpful|not_helpful|see_less|draft_email|draft_slack|send)$/i,
           value,
           capture: :all_but_first
         ) do
      [todo_id, action] -> {:ok, todo_id, String.downcase(action)}
      _ -> {:error, :invalid_callback}
    end
  end

  def parse_callback(_value), do: {:error, :invalid_callback}

  defp fetch_todo(%Todo{} = todo), do: {:ok, todo}
  defp fetch_todo(_todo), do: {:error, :not_found}

  defp dispatch_action(user_id, _chat_id, %Todo{id: todo_id}, "done") do
    with {:ok, todo} <-
           Todos.mark_done(
             user_id,
             todo_id,
             todo_action_opts(user_id, "Completed from Telegram work item message.")
           ) do
      {:ok, {:todo_updated, todo}}
    end
  end

  defp dispatch_action(user_id, _chat_id, %Todo{id: todo_id}, "dismiss") do
    with {:ok, todo} <-
           Todos.dismiss(
             user_id,
             todo_id,
             todo_action_opts(user_id, "Dismissed from Telegram work item message.")
           ) do
      {:ok, {:todo_updated, todo}}
    end
  end

  defp dispatch_action(user_id, _chat_id, %Todo{id: todo_id}, "snooze") do
    snoozed_until =
      DateTime.utc_now()
      |> DateTime.add(24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    with {:ok, todo} <-
           Todos.snooze(user_id, todo_id, snoozed_until,
             note: "Snoozed from Telegram work item message."
           ) do
      {:ok, {:todo_updated, todo}}
    end
  end

  defp dispatch_action(user_id, _chat_id, %Todo{id: todo_id}, "important") do
    with {:ok, todo} <- Todos.mark_important(user_id, todo_id, source: "telegram") do
      {:ok, {:todo_updated, todo}}
    end
  end

  defp dispatch_action(user_id, _chat_id, %Todo{id: todo_id}, "see_less") do
    case Todos.see_less_like(
           user_id,
           todo_id,
           Keyword.put(todo_actor_opts(user_id), :source, "telegram")
         ) do
      {:ok, %{todo: todo}} -> {:ok, {:todo_updated, todo}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_action(user_id, _chat_id, %Todo{id: todo_id}, feedback)
       when feedback in @record_feedback_values do
    with {:ok, todo} <- Todos.record_feedback(user_id, todo_id, feedback, source: "telegram") do
      {:ok, {:todo_updated, todo}}
    end
  end

  defp dispatch_action(user_id, _chat_id, %Todo{} = todo, "draft_email") do
    generate_todo_draft(user_id, todo, "gmail")
  end

  defp dispatch_action(user_id, _chat_id, %Todo{} = todo, "draft_slack") do
    generate_todo_draft(user_id, todo, "slack")
  end

  # SPEC 06 R3/R4: resolve the todo's action_draft (+ source_actions
  # destination context) into a prepare_external_action-style prepared
  # action, then hand it to the existing confirm/execute pipeline. Never
  # sends without the explicit Confirm tap handled by
  # `Maraithon.TelegramAssistant.handle_callback_query/1` /
  # `handle_text_confirmation/5`.
  defp dispatch_action(user_id, chat_id, %Todo{} = todo, "send") do
    prepare_todo_send(user_id, chat_id, todo)
  end

  defp todo_action_opts(user_id, note), do: Keyword.put(todo_actor_opts(user_id), :note, note)

  defp todo_actor_opts(user_id),
    do: [actor_type: "user", actor_id: user_id, actor_label: "User"]

  defp refresh_message(chat_id, message_id, todo)
       when is_binary(chat_id) and is_binary(message_id) do
    payload = telegram_payload(todo)

    case TelegramResponder.edit(chat_id, message_id, payload.text,
           parse_mode: "HTML",
           reply_markup: payload.reply_markup
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp refresh_message(_chat_id, _message_id, _todo), do: :ok

  defp send_draft(chat_id, message_id, text)
       when is_binary(chat_id) and is_binary(message_id) and is_binary(text) do
    case TelegramResponder.reply(chat_id, message_id, text, parse_mode: "HTML") do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp send_draft(chat_id, _message_id, text) when is_binary(chat_id) and is_binary(text) do
    case TelegramResponder.send(chat_id, text, parse_mode: "HTML") do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  # Resolves the todo's action_draft + source destination into a prepared
  # action awaiting confirmation. Attached to a real conversation so both the
  # Confirm/Cancel buttons (`TelegramResponder.action_markup/1`,
  # `Maraithon.TelegramAssistant.handle_callback_query/1`) and a typed
  # "yes"/"no" reply (`Maraithon.TelegramAssistant.handle_text_confirmation/5`)
  # can complete it; nothing sends until one of those fires.
  #
  # SPEC 06 review finding #2: repeated Send taps used to create an
  # independent Conversation + PreparedAction each time, so two taps produced
  # two Confirm prompts and, if both were confirmed, two sends plus two
  # independent nudge_count increments. Reuse the existing awaiting
  # confirmation (if any) instead of creating a duplicate.
  #
  # SPEC 02 R11/R12: this soft read-then-write check only closes the window
  # when the taps are far enough apart. The atomic backstop is the
  # `telegram_prepared_actions_awaiting_todo_index` partial unique index —
  # two truly concurrent taps both read nil here, both insert, and the loser
  # falls back to the winner's row in `insert_prepared_send/5` below.
  defp prepare_todo_send(user_id, chat_id, %Todo{} = todo) do
    case TelegramAssistant.find_awaiting_prepared_action_for_todo(user_id, todo.id) do
      %{} = existing_prepared_action ->
        {:ok, {:send_prepared, existing_prepared_action}}

      nil ->
        create_prepared_send(user_id, chat_id, todo)
    end
  end

  defp create_prepared_send(user_id, chat_id, %Todo{} = todo) do
    with {:ok, conversation} <-
           TelegramConversations.start_or_continue(user_id, chat_id, %{
             "surface" => "telegram",
             "metadata" => %{"mode" => "assistant"}
           }),
         {:ok, attrs} <- TodoThreadPrimer.resolve_send_action_attrs(conversation, todo),
         {:ok, run} <- create_send_run(conversation, todo) do
      attrs =
        attrs
        |> Map.put(:surface, "telegram")
        |> Map.put(:run_id, run.id)

      insert_prepared_send(user_id, conversation, todo, attrs, _may_retry? = true)
    else
      :skip -> {:error, :no_send_destination}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_prepared_send(user_id, conversation, %Todo{} = todo, attrs, may_retry?) do
    case TelegramAssistant.create_prepared_action(attrs) do
      {:ok, prepared_action} ->
        _ = TelegramAssistant.mark_conversation_awaiting_action(conversation, prepared_action)
        {:ok, {:send_prepared, prepared_action}}

      {:error, %Ecto.Changeset{} = changeset} ->
        if awaiting_todo_conflict?(changeset) do
          resolve_awaiting_todo_conflict(
            user_id,
            conversation,
            todo,
            attrs,
            changeset,
            may_retry?
          )
        else
          {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # SPEC 02 R12: the insert collided with the partial unique index. Look the
  # blocking row up WITHOUT the `expires_at > now` filter —
  # `find_awaiting_prepared_action_for_todo/2` filters it out, so it returns
  # nil for exactly the stale-expired-but-unswept row that caused the
  # conflict (the index predicate cannot reference expires_at; now() is not
  # immutable in Postgres).
  defp resolve_awaiting_todo_conflict(user_id, conversation, todo, attrs, changeset, may_retry?) do
    action_type = Map.get(attrs, :action_type) || Map.get(attrs, "action_type")

    case TelegramAssistant.find_awaiting_prepared_action_for_todo_ignoring_expiry(
           user_id,
           action_type,
           todo.id
         ) do
      nil ->
        # The blocking row disappeared between the failed insert and the
        # lookup — should not happen in practice, but must not crash.
        {:error, changeset}

      existing_prepared_action ->
        cond do
          not TelegramAssistant.prepared_action_expired?(existing_prepared_action) ->
            # The loser of the double-tap race gracefully falls back to the
            # winner's row.
            {:ok, {:send_prepared, existing_prepared_action}}

          may_retry? ->
            # Stale row past expires_at but not yet swept: force-expire it
            # (removing it from the partial index scope) and retry the
            # insert exactly once. A repeat conflict (third concurrent
            # racer) falls through to the found-row handling above rather
            # than retrying again — no loop.
            _ = TelegramAssistant.expire_prepared_action(existing_prepared_action)
            insert_prepared_send(user_id, conversation, todo, attrs, false)

          true ->
            {:ok, {:send_prepared, existing_prepared_action}}
        end
    end
  end

  defp awaiting_todo_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint_name) == "telegram_prepared_actions_awaiting_todo_index"
    end)
  end

  defp create_send_run(%Conversation{} = conversation, %Todo{} = todo) do
    now = DateTime.utc_now()

    TelegramAssistant.start_run(%{
      user_id: conversation.user_id,
      chat_id: conversation.chat_id,
      conversation_id: conversation.id,
      surface: "telegram",
      trigger_type: "follow_up",
      status: "completed",
      model_provider: "deterministic",
      model_name: "todo_send_action",
      prompt_snapshot: %{},
      result_summary: %{
        surface: "telegram",
        message_class: "todo_send_action",
        linked_todo_id: todo.id
      },
      started_at: now,
      finished_at: now
    })
  end

  defp send_confirmation_prompt(chat_id, message_id, %{} = prepared_action)
       when is_binary(chat_id) do
    text = send_confirmation_text(prepared_action)
    reply_markup = TelegramResponder.action_markup(prepared_action.id)

    result =
      if is_binary(message_id) do
        TelegramResponder.reply(chat_id, message_id, text,
          parse_mode: "HTML",
          reply_markup: reply_markup
        )
      else
        TelegramResponder.send(chat_id, text, parse_mode: "HTML", reply_markup: reply_markup)
      end

    case result do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp send_confirmation_prompt(_chat_id, _message_id, _prepared_action), do: :ok

  defp send_confirmation_text(%{payload: payload, preview_text: preview_text}) do
    payload = payload || %{}
    subject = read_string(payload, "subject")
    body = first_present([read_string(payload, "body"), read_string(payload, "text")])

    [
      "<b>Ready to send</b>",
      if(present?(preview_text), do: preview_text),
      if(subject, do: "<b>Subject:</b> #{safe(subject)}"),
      if(body, do: "<pre>#{safe(truncate(body, 1_500))}</pre>"),
      "Confirm to send, or Cancel to leave it untouched."
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp build_reply_markup(todo, opts) when is_map(todo) and is_list(opts) do
    card = ActionCards.for_todo(todo, action_card_opts(opts))

    rows =
      []
      |> maybe_add_draft_row(todo, card)
      |> maybe_add_action_row(todo, card)
      |> maybe_add_feedback_row(todo, card)
      |> maybe_add_link_row(todo)

    if rows == [], do: nil, else: %{"inline_keyboard" => rows}
  end

  defp build_reply_markup(_todo, _opts), do: nil

  defp maybe_add_action_row(rows, todo, card) when is_map(todo) do
    case {todo_id(todo), todo_status(todo), read_string(card, "attention_mode")} do
      {todo_id, status, "stale_check"}
      when is_binary(todo_id) and status in ["open", "snoozed"] ->
        rows ++
          [
            [
              %{"text" => "Keep active", "callback_data" => callback_data(todo_id, "important")},
              %{"text" => "Dismiss", "callback_data" => callback_data(todo_id, "dismiss")}
            ]
          ]

      {todo_id, status, _attention_mode}
      when is_binary(todo_id) and status in ["open", "snoozed"] ->
        rows ++
          [
            [
              %{"text" => "Done", "callback_data" => callback_data(todo_id, "done")},
              %{"text" => "Snooze", "callback_data" => callback_data(todo_id, "snooze")},
              %{"text" => "Dismiss", "callback_data" => callback_data(todo_id, "dismiss")}
            ]
          ]

      _ ->
        rows
    end
  end

  defp maybe_add_action_row(rows, _todo, _card), do: rows

  # SPEC 06 R2: once a *real* draft already exists on the todo, offer "Send"
  # instead of "Draft" (there is nothing left to draft, only to approve and
  # send). Deliberately does not key off `action_cards.ex`'s "review_draft"
  # prepared_actions hint: every todo gets a generic "next step" placeholder
  # draft from `Maraithon.Todos.ActionDrafts.ensure/2` (a write-boundary
  # fallback so mobile always has *something* to show), which would make that
  # signal true for nearly every todo. `real_draft_ready?/1` checks the
  # todo's own action_draft fields to tell an actual reply draft (kind
  # "reply", written by `generate_todo_draft/3` below or supplied directly by
  # a model-generated todo) apart from that placeholder.
  #
  # SPEC 06 review finding #1: a real draft used to leave exactly one button
  # ("Send") with no way to regenerate a bad draft. Once a real draft is
  # ready, show both Send and a compact "Redraft" button that reuses the
  # existing draft_email/draft_slack callback actions (`generate_todo_draft/3`
  # already persists the regenerated draft and re-renders the card).
  defp maybe_add_draft_row(rows, todo, _card) when is_map(todo) do
    case todo_id(todo) do
      todo_id when is_binary(todo_id) ->
        case draft_row_buttons(todo, todo_id) do
          [] -> rows
          buttons -> rows ++ [buttons]
        end

      _ ->
        rows
    end
  end

  defp maybe_add_draft_row(rows, _todo, _card), do: rows

  defp draft_row_buttons(todo, todo_id) do
    if real_draft_ready?(todo) do
      [send_row_button(todo, todo_id), redraft_row_button(todo, todo_id)]
      |> Enum.reject(&is_nil/1)
    else
      case draft_callback_action(todo) do
        {action, label} -> [%{"text" => label, "callback_data" => callback_data(todo_id, action)}]
        nil -> []
      end
    end
  end

  defp send_row_button(todo, todo_id) do
    case send_row_action(todo) do
      nil ->
        nil

      {action, label} ->
        # SPEC 06 review finding #2: once a send is already awaiting
        # confirmation for this todo, relabel instead of implying a fresh tap
        # starts a new send (repeat taps are deduped by
        # `prepare_todo_send/3`/`find_awaiting_prepared_action_for_todo/2`, so
        # this is a UX signal on top of that, not the only guard).
        label = if awaiting_send_confirmation?(todo), do: "Awaiting confirmation", else: label
        %{"text" => label, "callback_data" => callback_data(todo_id, action)}
    end
  end

  defp redraft_row_button(todo, todo_id) do
    case redraft_row_action(todo) do
      {action, label} -> %{"text" => label, "callback_data" => callback_data(todo_id, action)}
      nil -> nil
    end
  end

  defp redraft_row_action(todo) do
    case draft_channel(todo) do
      "gmail" -> {"draft_email", "Redraft Email"}
      "slack" -> {"draft_slack", "Redraft Slack"}
      _ -> nil
    end
  end

  defp draft_channel(todo) do
    draft = todo_action_draft(todo)
    first_present([read_string(draft, "channel"), todo_source(todo)])
  end

  defp awaiting_send_confirmation?(todo) do
    with user_id when is_binary(user_id) <- todo_user_id(todo),
         todo_id when is_binary(todo_id) <- todo_id(todo),
         %{} <- TelegramAssistant.find_awaiting_prepared_action_for_todo(user_id, todo_id) do
      true
    else
      _ -> false
    end
  end

  defp real_draft_ready?(todo) do
    draft = todo_action_draft(todo)
    text = ActionDrafts.preview(draft)

    present?(text) and not generic_next_step_draft?(draft)
  end

  defp generic_next_step_draft?(draft) do
    read_string(draft, "kind") == "next_step" or
      read_string(draft, "source") == "todo_write_boundary"
  end

  defp todo_action_draft(%Todo{action_draft: draft}) when is_map(draft), do: draft

  defp todo_action_draft(todo) when is_map(todo) do
    case Map.get(todo, "action_draft") || Map.get(todo, :action_draft) do
      draft when is_map(draft) -> draft
      _ -> %{}
    end
  end

  defp todo_action_draft(_todo), do: %{}

  defp send_row_action(todo) do
    if sendable_channel?(todo), do: {"send", "Send"}
  end

  defp sendable_channel?(todo) do
    todo_source(todo) in ["gmail", "slack"]
  end

  defp maybe_add_feedback_row(rows, todo, card) when is_map(todo) do
    case {todo_id(todo), feedback_value(todo), read_string(card, "attention_mode")} do
      {todo_id, value, _attention_mode} when is_binary(todo_id) and value in @feedback_values ->
        rows

      {todo_id, _value, "stale_check"} when is_binary(todo_id) ->
        rows

      {todo_id, _value, _attention_mode} when is_binary(todo_id) ->
        rows ++
          [
            [
              %{"text" => "Helpful", "callback_data" => callback_data(todo_id, "helpful")},
              %{
                "text" => "Less useful",
                "callback_data" => callback_data(todo_id, "not_helpful")
              },
              %{
                "text" => "Show less",
                "callback_data" => callback_data(todo_id, "see_less")
              }
            ]
          ]

      _ ->
        rows
    end
  end

  defp maybe_add_feedback_row(rows, _todo, _card), do: rows

  defp maybe_add_link_row(rows, todo) when is_map(todo) do
    buttons =
      [
        source_link_button(todo),
        %{"text" => "Open Maraithon", "url" => todo_url(todo)}
      ]
      |> Enum.reject(&is_nil/1)

    if buttons == [], do: rows, else: rows ++ [buttons]
  end

  defp render_message(todo, opts) when is_map(todo) and is_list(opts) do
    prefix_text = Keyword.get(opts, :prefix_text)
    todo = UserFacingCopy.polish_attrs(todo)
    metadata = todo_metadata(todo)
    account = metadata_account(metadata)
    todo_source = todo_source(todo)
    source = source_label(todo_source)
    feedback = feedback_label(feedback_value(todo))
    next_action = display_text(todo_next_action(todo))
    context = display_text(todo_context(todo, metadata))
    assistant_source? = assistant_source?(todo_source)
    card = ActionCards.for_todo(todo, action_card_opts(opts))
    source_health_note = ActionCards.source_health_note(card)

    [
      display_text(prefix_text),
      action_line(next_action, assistant_source?),
      todo_context_line(context, next_action),
      decision_line(card, next_action),
      why_line(card, context),
      draft_preview_line(card),
      prepared_action_line(card),
      evidence_line(card, context),
      source_sentence(source, account, assistant_source?, source_health_note),
      source_health_note,
      learning_line(card),
      feedback && "Feedback: #{safe(feedback)}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp render_message(todo, prefix_text) when is_map(todo) do
    render_message(todo, prefix_text: prefix_text)
  end

  defp action_card_opts(opts) do
    opts
    |> Keyword.take([:include_disconnected, :source_health_snapshots, :timezone_info])
    |> Keyword.put_new(:include_disconnected, true)
  end

  defp source_label(source) when is_binary(source) do
    if assistant_source?(source), do: nil, else: SourceLabels.label(source)
  end

  defp source_label(_source), do: "Operator"

  defp assistant_source?(source) when is_binary(source) do
    source in [
      "chief_of_staff_morning_briefing",
      "chief_of_staff_commitment_tracker",
      "chief_of_staff_holiday",
      "chief_of_staff_weekend"
    ]
  end

  defp assistant_source?(_source), do: false

  defp action_line(action, true) when is_binary(action) do
    "<b>#{safe(chief_action_copy(action))}</b>"
  end

  defp action_line(action, _assistant_source?) when is_binary(action) do
    "<b>#{safe(action)}</b>"
  end

  defp action_line(_action, _assistant_source?), do: nil

  defp chief_action_copy(action) do
    action = strip_leading_action_label(action)
    action = naturalize_status_check_copy(action)

    cond do
      blank?(action) ->
        "Review this."

      Regex.match?(~r/^(I'd|I would|I can|I'll|Let me|You|We)\b/i, action) ->
        ensure_sentence_case(action)

      true ->
        ensure_sentence_case(action)
    end
  end

  defp strip_leading_action_label(text) when is_binary(text) do
    String.replace(text, ~r/^\s*(next step|next|action|todo)\s*:\s*/i, "")
  end

  defp naturalize_status_check_copy(text) when is_binary(text) do
    text
    |> String.replace(
      ~r/\s+for a one-line status update covering current state, fix window if still open, and any user or customer impact\.?/i,
      ": is it resolved, who owns it, and were any users or customers affected?"
    )
    |> String.replace(
      ~r/\s+for a one-line status update covering current state, owner, fix window if still open, and any user or customer impact\.?/i,
      ": is it resolved, who owns it, and were any users or customers affected?"
    )
  end

  defp ensure_sentence_case(<<first::utf8, rest::binary>>) do
    String.upcase(<<first::utf8>>) <> rest
  end

  defp ensure_sentence_case(value), do: value

  defp source_link_button(todo) do
    case source_url(todo_metadata(todo)) do
      url when is_binary(url) -> %{"text" => source_link_label(todo_source(todo)), "url" => url}
      _ -> nil
    end
  end

  defp source_link_label(source) do
    case source_label(source) do
      label when is_binary(label) and label not in ["Maraithon", "Operator"] -> "Open #{label}"
      _ -> "Open Source"
    end
  end

  defp source_url(metadata) when is_map(metadata) do
    metadata
    |> direct_source_url()
    |> normalize_url()
  end

  defp source_url(_metadata), do: nil

  defp todo_url(todo) do
    case todo_id(todo) do
      todo_id when is_binary(todo_id) ->
        AppUrl.url("/todos?todo_id=#{URI.encode_www_form(todo_id)}")

      _ ->
        AppUrl.url("/dashboard")
    end
  end

  defp direct_source_url(metadata) do
    [
      Map.get(metadata, "url"),
      Map.get(metadata, "permalink"),
      Map.get(metadata, "html_url"),
      get_in(metadata, ["source_ref", "url"]),
      get_in(metadata, ["record", "url"])
    ]
    |> Enum.find(&present?/1)
  end

  defp normalize_url(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, "http://") or String.starts_with?(trimmed, "https://") do
      trimmed
    else
      nil
    end
  end

  defp normalize_url(_value), do: nil

  defp source_sentence(_source, _account, true, _source_health_note), do: nil
  defp source_sentence(nil, _account, _assistant_source?, _source_health_note), do: nil
  defp source_sentence("Operator", _account, _assistant_source?, _source_health_note), do: nil

  defp source_sentence(source, account, _assistant_source?, source_health_note) do
    if source_health_note_mentions_source?(source_health_note, source) do
      nil
    else
      "From #{safe(source)}#{render_account(account)}."
    end
  end

  defp source_health_note_mentions_source?(note, source)
       when is_binary(note) and is_binary(source) do
    normalized_source = source |> String.downcase() |> Regex.escape()

    Regex.match?(~r/\bUsed\s+[^.]*#{normalized_source}\b/i, note)
  end

  defp source_health_note_mentions_source?(_note, _source), do: false

  defp decision_line(card, next_action) when is_map(card) do
    decision = Map.get(card, "decision_prompt")

    if present?(decision) and not decision_restates_action?(decision, next_action) do
      "Decision: #{safe(truncate(decision, 220))}"
    end
  end

  defp decision_line(_card, _next_action), do: nil

  defp decision_restates_action?(decision, next_action)
       when is_binary(decision) and is_binary(next_action) do
    action_key = repetition_key(next_action)
    decision_key = decision |> strip_decision_label() |> repetition_key()

    unwrapped_decision_key =
      decision |> strip_decision_label() |> strip_decision_wrapper() |> repetition_key()

    present?(action_key) and
      (action_key == decision_key or action_key == unwrapped_decision_key)
  end

  defp decision_restates_action?(_decision, _next_action), do: false

  defp strip_decision_label(value) when is_binary(value) do
    String.replace(value, ~r/^\s*Decision:\s*/i, "")
  end

  defp strip_decision_wrapper(value) when is_binary(value) do
    String.replace(value, ~r/^\s*(?:decide|choose)\s+whether\s+to\s+/i, "")
  end

  defp why_line(card, already_rendered_context) when is_map(card) do
    why_now = Map.get(card, "why_now")

    if present?(why_now) and not repeated_context_line?(why_now, already_rendered_context) do
      "Why now: #{safe(truncate(why_now, 220))}"
    end
  end

  defp why_line(_card, _already_rendered_context), do: nil

  defp repeated_context_line?(value, already_rendered_context)
       when is_binary(value) and is_binary(already_rendered_context) do
    value_key = repetition_key(value)
    context_key = repetition_key(already_rendered_context)

    present?(value_key) and present?(context_key) and
      (value_key == context_key or
         (String.length(value_key) >= 32 and
            (String.contains?(context_key, value_key) or
               String.contains?(value_key, context_key))))
  end

  defp repeated_context_line?(_value, _already_rendered_context), do: false

  defp repetition_key(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[[:punct:]]+/u, " ")
    |> normalize_display_whitespace()
  end

  defp prepared_action_line(card) when is_map(card) do
    case ActionCards.prepared_action_hint(card) do
      hint when is_binary(hint) -> "Prepared: #{safe(hint)}"
      _ -> nil
    end
  end

  defp prepared_action_line(_card), do: nil

  defp draft_preview_line(card) when is_map(card) do
    case ActionCards.draft_preview(card) do
      preview when is_binary(preview) -> "Suggested reply: #{safe(truncate(preview, 360))}"
      _ -> nil
    end
  end

  defp draft_preview_line(_card), do: nil

  defp evidence_line(card, already_rendered_context) when is_map(card) do
    case ActionCards.evidence_excerpt(card) do
      excerpt when is_binary(excerpt) ->
        if present?(already_rendered_context) and
             String.contains?(already_rendered_context, excerpt) do
          nil
        else
          "Evidence: #{safe(truncate(excerpt, 180))}"
        end

      _ ->
        nil
    end
  end

  defp evidence_line(_card, _already_rendered_context), do: nil

  defp learning_line(%{"attention_mode" => "stale_check"} = card) do
    case Map.get(card, "next_best_action") do
      action when is_binary(action) ->
        safe(truncate(action, 220))

      _other ->
        "Keep it active only if it still matters; otherwise dismiss it so future briefings stay focused."
    end
  end

  defp learning_line(_card), do: nil

  # Mirrors `Maraithon.ActionCards.prepared_actions/2`'s own draft_email /
  # draft_slack detection (source + next_action wording) rather than reading
  # its "prepared_actions" list: that list's first cond branch fires whenever
  # *any* action_draft is present, including the universal write-boundary
  # "next step" placeholder every todo gets from `ActionDrafts.ensure/2`, so
  # it never actually reaches the draft_email/draft_slack branches in
  # practice. `real_draft_ready?/1` already handles the "a real draft already
  # exists, offer Send" side of this; this is the "no real draft yet, offer
  # Draft" side.
  defp draft_callback_action(todo) do
    next_action = todo |> raw_next_action() |> to_string() |> String.downcase()
    source = todo_source(todo)

    cond do
      source == "gmail" and String.contains?(next_action, ["reply", "email"]) ->
        {"draft_email", "Draft Email"}

      source == "slack" and String.contains?(next_action, ["reply", "respond", "message"]) ->
        {"draft_slack", "Draft Slack"}

      true ->
        nil
    end
  end

  defp raw_next_action(%Todo{next_action: next_action}), do: next_action
  defp raw_next_action(todo) when is_map(todo), do: map_string(todo, "next_action")
  defp raw_next_action(_todo), do: nil

  defp generate_todo_draft(user_id, %Todo{} = todo, channel) do
    card = ActionCards.for_todo(todo, include_disconnected: false)

    attrs =
      todo
      |> draft_attrs(channel, card)
      |> Map.put("channel", channel)
      |> Map.put("save_to_provider", false)

    case Drafts.create(user_id, attrs, draft_opts()) do
      {:ok, result} ->
        # SPEC 06 R5: persist the regenerated draft onto the todo's
        # `action_draft` (previously this only rendered a one-off preview
        # reply) and re-render the card so the buttons offer "Send" instead
        # of "Draft" going forward.
        updated_todo = persist_generated_draft(user_id, todo, channel, result)
        {:ok, {:draft_ready, render_draft_result(channel, result), updated_todo}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_generated_draft(user_id, %Todo{} = todo, channel, result) do
    draft_map = generated_action_draft(channel, result)

    case compact_map(draft_map) do
      empty when map_size(empty) == 0 ->
        todo

      draft_map ->
        case Todos.update_for_user(user_id, todo.id, %{"action_draft" => draft_map}) do
          {:ok, updated_todo} -> updated_todo
          {:error, _reason} -> todo
        end
    end
  end

  defp generated_action_draft("gmail", %{draft: %{"subject" => subject, "body" => body}}) do
    %{
      "kind" => "reply",
      "label" => "Email draft ready",
      "channel" => "gmail",
      "subject" => subject,
      "text" => body,
      "body" => body,
      "source" => "todo_draft_action",
      "style" => "assistant_prepared_draft"
    }
  end

  defp generated_action_draft("slack", %{draft: %{"text" => text}}) do
    %{
      "kind" => "reply",
      "label" => "Slack draft ready",
      "channel" => "slack",
      "text" => text,
      "source" => "todo_draft_action",
      "style" => "assistant_prepared_draft"
    }
  end

  defp generated_action_draft(_channel, _result), do: %{}

  defp draft_attrs(%Todo{} = todo, channel, card) do
    metadata = todo.metadata || %{}
    public_metadata = PublicMetadata.todo(metadata)
    context = Map.get(card, "context_pack", %{})
    person = person_for_draft(metadata, context)
    subject = subject_for_draft(todo, public_metadata, context)
    thread_id = first_present([read_string(metadata, "thread_id"), todo.source_item_id])
    account = first_present([metadata_account(metadata), todo.source_account_label])

    %{
      "purpose" => draft_purpose(card, todo),
      "recipient" => person,
      "subject" => subject,
      "thread_id" => thread_id,
      "account" => account,
      "context" =>
        %{
          "decision" => Map.get(card, "decision_prompt"),
          "why_now" => Map.get(card, "why_now"),
          "next_best_action" => Map.get(card, "next_best_action"),
          "source_evidence" => ActionCards.evidence_excerpt(card),
          "thread" => Map.get(context, "project_or_topic"),
          "summary" => Map.get(context, "summary"),
          "channel" => channel
        }
        |> compact_map(),
      "instructions" => "Prepare this for approval. Do not send it."
    }
    |> compact_map()
  end

  defp draft_purpose(card, todo) do
    first_present([
      Map.get(card, "next_best_action"),
      todo.next_action,
      todo.title,
      "Reply with the next useful update."
    ])
  end

  defp person_for_draft(metadata, context) do
    people =
      context
      |> Map.get("people", [])
      |> List.wrap()

    people_name =
      Enum.find_value(people, fn
        %{"display_name" => value} when is_binary(value) -> value
        %{"name" => value} when is_binary(value) -> value
        _ -> nil
      end)

    record = read_map(metadata, "record")

    first_present([
      people_name,
      read_string(record, "person"),
      read_string(metadata, "person"),
      read_string(metadata, "contact"),
      read_string(metadata, "requested_by"),
      read_string(metadata, "sender_name")
    ])
  end

  defp subject_for_draft(todo, public_metadata, context) do
    first_present([
      read_string(public_metadata, "subject"),
      read_string(public_metadata, "email_subject"),
      read_string(public_metadata, "thread_subject"),
      Map.get(context, "project_or_topic"),
      todo.title,
      "Quick follow-up"
    ])
  end

  defp draft_opts do
    Application.get_env(:maraithon, :telegram_assistant, [])
    |> Keyword.get(:draft_opts, [])
  end

  defp render_draft_result("gmail", %{draft: %{"subject" => subject, "body" => body}}) do
    [
      "<b>Email draft ready</b>",
      "<b>Subject:</b> #{safe(subject)}",
      "<pre>#{safe(truncate(body, 1_500))}</pre>",
      "Review before sending."
    ]
    |> Enum.join("\n")
  end

  defp render_draft_result("slack", %{draft: %{"text" => text}}) do
    [
      "<b>Slack draft ready</b>",
      "<pre>#{safe(truncate(text, 1_500))}</pre>",
      "Review before sending."
    ]
    |> Enum.join("\n")
  end

  defp render_draft_result(_channel, _result) do
    "<b>Draft ready</b>\nReview before sending."
  end

  defp render_account(nil), do: ""
  defp render_account(account), do: " · #{safe(account)}"

  defp metadata_account(metadata) when is_map(metadata) do
    [
      Map.get(metadata, "account"),
      Map.get(metadata, "google_account_email"),
      Map.get(metadata, "account_email"),
      Map.get(metadata, "mailbox"),
      Map.get(metadata, "workspace_name")
    ]
    |> Enum.find(&present?/1)
  end

  defp metadata_account(_metadata), do: nil

  defp feedback_value(%Todo{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "assistant_feedback") do
      %{"value" => value} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp feedback_value(todo) when is_map(todo) do
    case get_in(todo_metadata(todo), ["assistant_feedback", "value"]) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp feedback_value(_todo), do: nil

  defp todo_id(%Todo{id: id}), do: id
  defp todo_id(todo) when is_map(todo), do: map_string(todo, "id")
  defp todo_id(_todo), do: nil

  defp todo_user_id(%Todo{user_id: user_id}), do: user_id
  defp todo_user_id(todo) when is_map(todo), do: map_string(todo, "user_id")
  defp todo_user_id(_todo), do: nil

  defp todo_status(%Todo{status: status}), do: status || "open"
  defp todo_status(todo) when is_map(todo), do: map_string(todo, "status") || "open"
  defp todo_status(_todo), do: "open"

  defp todo_source(%Todo{source: source}), do: source
  defp todo_source(todo) when is_map(todo), do: map_string(todo, "source")
  defp todo_source(_todo), do: nil

  defp todo_context_line(summary, next_action) do
    cond do
      blank?(summary) -> nil
      String.trim(summary) == String.trim(next_action) -> nil
      true -> summary |> one_sentence() |> truncate(240) |> safe()
    end
  end

  defp todo_context(todo, metadata) do
    summary = todo_summary(todo)

    commitment_context(metadata, summary) ||
      summary ||
      metadata_context(metadata) ||
      todo_notes(todo)
  end

  defp todo_summary(%Todo{summary: summary}), do: summary

  defp todo_summary(todo) when is_map(todo),
    do: map_string(todo, "summary")

  defp todo_summary(_todo), do: nil

  defp todo_notes(%Todo{notes: notes}), do: notes
  defp todo_notes(todo) when is_map(todo), do: map_string(todo, "notes")
  defp todo_notes(_todo), do: nil

  defp commitment_context(metadata, summary) when is_map(metadata) do
    record = read_map(metadata, "record")
    commitment = read_string(record, "commitment")

    if generic_commitment_summary?(summary) and present?(commitment) do
      person = read_string(record, "person")
      context = person_context_suffix(metadata, record)
      commitment = commitment |> single_line() |> soften_sentence_breaks()

      if present?(person) do
        "#{person}#{context} is waiting on this commitment: #{commitment}"
      else
        "This commitment is on your work queue: #{commitment}"
      end
    end
  end

  defp commitment_context(_metadata, _summary), do: nil

  defp generic_commitment_summary?(summary) when is_binary(summary) do
    summary = String.downcase(summary)

    String.contains?(summary, "commitment") and
      (String.contains?(summary, "open") or
         String.contains?(summary, "overdue") or
         String.contains?(summary, "no evidence") or
         String.contains?(summary, "no completion evidence"))
  end

  defp generic_commitment_summary?(_summary), do: false

  defp metadata_context(metadata) when is_map(metadata) do
    record = read_map(metadata, "record")

    [
      read_string(metadata, "context"),
      read_string(metadata, "context_brief"),
      relationship_memory_jog(metadata, record),
      read_string(metadata, "why_now"),
      read_string(metadata, "why_it_matters"),
      read_string(metadata, "source_summary"),
      read_string(record, "context"),
      read_string(record, "summary"),
      read_string(record, "ask"),
      read_string(record, "commitment"),
      record |> read_string_list("evidence") |> List.first()
    ]
    |> Enum.find(&present?/1)
  end

  defp metadata_context(_metadata), do: nil

  defp todo_next_action(%Todo{next_action: next_action, title: title}),
    do:
      next_action || title ||
        "Open the source item, confirm the specific request, and decide whether this still matters."

  defp todo_next_action(todo) when is_map(todo),
    do:
      map_string(todo, "next_action") || map_string(todo, "title") ||
        "Open the source item, confirm the specific request, and decide whether this still matters."

  defp todo_next_action(_todo),
    do:
      "Open the source item, confirm the specific request, and decide whether this still matters."

  defp display_text(text) when is_binary(text) do
    text
    |> UserFacingCopy.polish_text()
    |> strip_internal_lines()
    |> replace_internal_language()
    |> normalize_display_whitespace()
  end

  defp display_text(_text), do: nil

  defp strip_internal_lines(text) do
    text
    |> String.split("\n")
    |> Enum.reject(fn line ->
      String.match?(line, ~r/^\s*(open|title|priority|status|source|from)\s*:/i)
    end)
    |> Enum.join("\n")
  end

  defp replace_internal_language(text) do
    text
    |> String.replace(~r/\bthe user wants\b/i, "You want")
    |> String.replace(~r/\bthe user needs\b/i, "You need")
    |> String.replace(~r/\bthe user has\b/i, "You have")
    |> String.replace(~r/\bthe user is\b/i, "You are")
    |> String.replace(~r/\bthe user should\b/i, "You should")
    |> String.replace(~r/\bKent needs\b/i, "you need")
    |> String.replace(~r/\bKent has\b/i, "you have")
    |> String.replace(~r/\bKent should\b/i, "you should")
    |> String.replace(~r/\bKent is\b/i, "you are")
    |> String.replace(
      ~r/\bquick status check on whether the issue is resolved, who owns it, and whether users or customers were affected\b/i,
      "quick answer on whether it is fixed, who owns the follow-up, and whether any users or customers were affected"
    )
    |> String.replace(~r/\bChief_of_staff_morning_briefing\b/i, "the morning briefing")
    |> String.replace(~r/\bchief_of_staff_morning_briefing\b/i, "the morning briefing")
    |> String.replace(~r/\bChief_of_staff_commitment_tracker\b/i, "the open work review")
    |> String.replace(~r/\bchief_of_staff_commitment_tracker\b/i, "the open work review")
  end

  defp normalize_display_whitespace(text) do
    text
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp one_sentence(text) when is_binary(text) do
    case Regex.run(~r/^(.+?[.!?])(?:\s|$)/, text) do
      [_, sentence] -> sentence
      _ -> text
    end
  end

  defp one_sentence(text), do: text

  defp truncate(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      text
      |> String.slice(0, max_length)
      |> String.trim()
      |> Kernel.<>("...")
    else
      text
    end
  end

  defp truncate(text, _max_length), do: text

  defp single_line(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp single_line(text), do: text

  defp soften_sentence_breaks(text) when is_binary(text) do
    String.replace(text, ~r/[.!?]\s+/, "; ")
  end

  defp soften_sentence_breaks(text), do: text

  defp person_context_suffix(metadata, record) do
    details =
      [
        first_present([read_string(record, "company"), read_string(metadata, "company")]),
        first_present([
          read_string(record, "organization"),
          read_string(record, "org"),
          read_string(metadata, "organization")
        ]),
        first_present([
          read_string(record, "relationship_context"),
          read_string(metadata, "relationship_context"),
          read_string(record, "relationship"),
          read_string(metadata, "relationship")
        ])
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    case details do
      [] -> ""
      values -> " (#{Enum.join(values, "; ")})"
    end
  end

  defp relationship_memory_jog(metadata, record) do
    person = read_string(record, "person") || read_string(metadata, "person")

    details =
      [
        first_present([read_string(record, "company"), read_string(metadata, "company")]),
        first_present([
          read_string(record, "organization"),
          read_string(metadata, "organization")
        ]),
        first_present([
          read_string(record, "relationship_context"),
          read_string(metadata, "relationship_context"),
          read_string(record, "relationship"),
          read_string(metadata, "relationship")
        ]),
        read_string(metadata, "why_it_matters")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    cond do
      blank?(person) or details == [] -> nil
      true -> "#{person}: #{Enum.join(details, "; ")}."
    end
  end

  defp first_present(values) when is_list(values), do: Enum.find(values, &present?/1)
  defp first_present(_values), do: nil

  defp todo_metadata(%Todo{metadata: metadata}) when is_map(metadata), do: metadata

  defp todo_metadata(todo) when is_map(todo),
    do: Map.get(todo, "metadata") || Map.get(todo, :metadata) || %{}

  defp todo_metadata(_todo), do: %{}

  defp map_string(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) || Map.get(map, safe_existing_atom(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp map_string(_map, _key), do: nil

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp feedback_label("helpful"), do: "Helpful"
  defp feedback_label("important"), do: "Keep active"
  defp feedback_label("not_helpful"), do: "Less useful"
  defp feedback_label("see_less"), do: "Show less"
  defp feedback_label(_value), do: nil

  defp callback_notice("done"), do: "Marked done"
  defp callback_notice("dismiss"), do: "Dismissed"
  defp callback_notice("snooze"), do: "Snoozed until tomorrow"
  defp callback_notice("important"), do: "Kept active"
  defp callback_notice("helpful"), do: "Saved helpful feedback"
  defp callback_notice("not_helpful"), do: "Feedback saved"
  defp callback_notice("see_less"), do: "Similar work will show up less often"
  defp callback_notice("draft_email"), do: "Draft ready"
  defp callback_notice("draft_slack"), do: "Draft ready"
  defp callback_notice("send"), do: "Review before sending"

  defp callback_data(todo_id, action), do: "#{@callback_prefix}:#{todo_id}:#{action}"

  defp maybe_answer_callback(callback_id, text)
       when is_binary(callback_id) and is_binary(text) and text != "" do
    _ = TelegramResponder.answer_callback(callback_id, text)
    :ok
  end

  defp maybe_answer_callback(_callback_id, _text), do: :ok

  defp read_string(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

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

  defp read_map(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_map(value) ->
        value

      _ ->
        Enum.find_value(map, %{}, fn
          {map_key, value} when is_atom(map_key) and is_map(value) ->
            if Atom.to_string(map_key) == key, do: value, else: nil

          _ ->
            nil
        end)
    end
  end

  defp read_map(_map, _key), do: %{}

  defp read_string_list(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) || Map.get(map, safe_existing_atom(key)) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      value when is_binary(value) ->
        if String.trim(value) == "", do: [], else: [String.trim(value)]

      _ ->
        []
    end
  end

  defp read_string_list(_map, _key), do: []

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

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(_value), do: false

  defp safe(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp safe(value), do: to_string(value || "")
end
