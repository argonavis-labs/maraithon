defmodule Maraithon.TelegramAssistant.TodoActions do
  @moduledoc """
  Telegram-native rendering and callback handling for assistant todo items.
  """

  alias Maraithon.AppUrl
  alias Maraithon.ActionCards
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Drafts
  alias Maraithon.SourceLabels
  alias Maraithon.TelegramAssistant.ActionFailureCopy
  alias Maraithon.TelegramAssistant.BriefTodoReview
  alias Maraithon.TelegramResponder
  alias Maraithon.Todos
  alias Maraithon.Todos.{PublicMetadata, Todo, UserFacingCopy}

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
         {:ok, result} <- dispatch_action(user_id, todo, action) do
      case result do
        {:todo_updated, updated_todo} ->
          :ok = refresh_message(chat_id, message_id, updated_todo)
          maybe_answer_callback(callback_id, callback_notice(action))
          _ = BriefTodoReview.after_todo_action(user_id, chat_id, updated_todo, action)
          :ok

        {:draft_ready, draft_text} ->
          :ok = send_draft(chat_id, message_id, draft_text)
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
           ~r/^#{@callback_prefix}:([0-9a-f\-]{36}):(done|dismiss|snooze|important|helpful|not_helpful|see_less|draft_email|draft_slack)$/i,
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

  defp dispatch_action(user_id, %Todo{id: todo_id}, "done") do
    with {:ok, todo} <-
           Todos.mark_done(user_id, todo_id, note: "Completed from Telegram work item message.") do
      {:ok, {:todo_updated, todo}}
    end
  end

  defp dispatch_action(user_id, %Todo{id: todo_id}, "dismiss") do
    with {:ok, todo} <-
           Todos.dismiss(user_id, todo_id, note: "Dismissed from Telegram work item message.") do
      {:ok, {:todo_updated, todo}}
    end
  end

  defp dispatch_action(user_id, %Todo{id: todo_id}, "snooze") do
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

  defp dispatch_action(user_id, %Todo{id: todo_id}, "important") do
    with {:ok, todo} <- Todos.mark_important(user_id, todo_id, source: "telegram") do
      {:ok, {:todo_updated, todo}}
    end
  end

  defp dispatch_action(user_id, %Todo{id: todo_id}, "see_less") do
    case Todos.see_less_like(user_id, todo_id, source: "telegram") do
      {:ok, %{todo: todo}} -> {:ok, {:todo_updated, todo}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_action(user_id, %Todo{id: todo_id}, feedback)
       when feedback in @record_feedback_values do
    with {:ok, todo} <- Todos.record_feedback(user_id, todo_id, feedback, source: "telegram") do
      {:ok, {:todo_updated, todo}}
    end
  end

  defp dispatch_action(user_id, %Todo{} = todo, "draft_email") do
    generate_todo_draft(user_id, todo, "gmail")
  end

  defp dispatch_action(user_id, %Todo{} = todo, "draft_slack") do
    generate_todo_draft(user_id, todo, "slack")
  end

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

  defp build_reply_markup(todo, opts) when is_map(todo) and is_list(opts) do
    card = ActionCards.for_todo(todo, action_card_opts(opts))

    rows =
      []
      |> maybe_add_draft_row(todo)
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

  defp maybe_add_draft_row(rows, todo) when is_map(todo) do
    case {todo_id(todo), draft_callback_action(todo)} do
      {todo_id, {action, label}} when is_binary(todo_id) ->
        rows ++ [[%{"text" => label, "callback_data" => callback_data(todo_id, action)}]]

      _ ->
        rows
    end
  end

  defp maybe_add_draft_row(rows, _todo), do: rows

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
      decision_line(card),
      why_line(card),
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

  defp decision_line(card) when is_map(card) do
    decision = Map.get(card, "decision_prompt")

    if present?(decision) do
      "Decision: #{safe(truncate(decision, 220))}"
    end
  end

  defp decision_line(_card), do: nil

  defp why_line(card) when is_map(card) do
    why_now = Map.get(card, "why_now")

    if present?(why_now) do
      "Why now: #{safe(truncate(why_now, 220))}"
    end
  end

  defp why_line(_card), do: nil

  defp prepared_action_line(card) when is_map(card) do
    case ActionCards.prepared_action_hint(card) do
      hint when is_binary(hint) -> "Prepared: #{safe(hint)}"
      _ -> nil
    end
  end

  defp prepared_action_line(_card), do: nil

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

  defp draft_callback_action(todo) do
    todo
    |> ActionCards.for_todo(include_disconnected: false)
    |> Map.get("prepared_actions", [])
    |> Enum.find_value(fn
      %{"type" => "draft_email"} -> {"draft_email", "Draft Email"}
      %{"type" => "draft_slack"} -> {"draft_slack", "Draft Slack"}
      _ -> nil
    end)
  end

  defp generate_todo_draft(user_id, %Todo{} = todo, channel) do
    card = ActionCards.for_todo(todo, include_disconnected: false)

    attrs =
      todo
      |> draft_attrs(channel, card)
      |> Map.put("channel", channel)
      |> Map.put("save_to_provider", false)

    case Drafts.create(user_id, attrs, draft_opts()) do
      {:ok, result} -> {:ok, {:draft_ready, render_draft_result(channel, result)}}
      {:error, reason} -> {:error, reason}
    end
  end

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
        "This commitment is still open: #{commitment}"
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
        "Open the source item, confirm the real ask, and decide whether this still matters."

  defp todo_next_action(todo) when is_map(todo),
    do:
      map_string(todo, "next_action") || map_string(todo, "title") ||
        "Open the source item, confirm the real ask, and decide whether this still matters."

  defp todo_next_action(_todo),
    do: "Open the source item, confirm the real ask, and decide whether this still matters."

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
  defp callback_notice("see_less"), do: "Maraithon will show fewer like this"
  defp callback_notice("draft_email"), do: "Draft ready"
  defp callback_notice("draft_slack"), do: "Draft ready"

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
