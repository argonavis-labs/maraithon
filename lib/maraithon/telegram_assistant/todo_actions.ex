defmodule Maraithon.TelegramAssistant.TodoActions do
  @moduledoc """
  Telegram-native rendering and callback handling for assistant todo items.
  """

  alias Maraithon.ConnectedAccounts
  alias Maraithon.TelegramResponder
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo
  alias MaraithonWeb.Endpoint

  @callback_prefix "tgtodo"
  @feedback_values ~w(helpful not_helpful)

  def telegram_payload(todo) when is_map(todo) do
    telegram_payload(todo, [])
  end

  def telegram_payload(todo, opts) when is_map(todo) and is_list(opts) do
    prefix_text = Keyword.get(opts, :prefix_text)

    %{
      text: render_message(todo, prefix_text),
      reply_markup: build_reply_markup(todo)
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
         {:ok, todo} <- dispatch_action(user_id, todo_id, action),
         :ok <- refresh_message(chat_id, message_id, todo) do
      maybe_answer_callback(callback_id, callback_notice(action))
      :ok
    else
      {:error, :invalid_callback} ->
        :ignored

      {:error, :not_found} ->
        maybe_answer_callback(callback_id, "I couldn't find that todo anymore.")
        :ok

      {:error, reason} ->
        maybe_answer_callback(callback_id, callback_error_text(reason))
        :ok

      _ ->
        maybe_answer_callback(callback_id, "I couldn't match that todo to this chat.")
        :ok
    end
  end

  def handle_callback(_data), do: :ignored

  def parse_callback(""), do: {:error, :invalid_callback}

  def parse_callback(value) when is_binary(value) do
    case Regex.run(
           ~r/^#{@callback_prefix}:([0-9a-f\-]{36}):(done|dismiss|helpful|not_helpful)$/i,
           value,
           capture: :all_but_first
         ) do
      [todo_id, action] -> {:ok, todo_id, String.downcase(action)}
      _ -> {:error, :invalid_callback}
    end
  end

  def parse_callback(_value), do: {:error, :invalid_callback}

  defp dispatch_action(user_id, todo_id, "done") do
    Todos.mark_done(user_id, todo_id, note: "Completed from Telegram todo message.")
  end

  defp dispatch_action(user_id, todo_id, "dismiss") do
    Todos.dismiss(user_id, todo_id, note: "Dismissed from Telegram todo message.")
  end

  defp dispatch_action(user_id, todo_id, feedback) when feedback in @feedback_values do
    Todos.record_feedback(user_id, todo_id, feedback, source: "telegram")
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

  defp build_reply_markup(todo) when is_map(todo) do
    rows =
      []
      |> maybe_add_action_row(todo)
      |> maybe_add_feedback_row(todo)
      |> maybe_add_link_row(todo)

    if rows == [], do: nil, else: %{"inline_keyboard" => rows}
  end

  defp maybe_add_action_row(rows, todo) when is_map(todo) do
    case {todo_id(todo), todo_status(todo)} do
      {todo_id, status} when is_binary(todo_id) and status in ["open", "snoozed"] ->
        rows ++
          [
            [
              %{"text" => "Mark Done", "callback_data" => callback_data(todo_id, "done")},
              %{"text" => "Not Interested", "callback_data" => callback_data(todo_id, "dismiss")}
            ]
          ]

      _ ->
        rows
    end
  end

  defp maybe_add_action_row(rows, _todo), do: rows

  defp maybe_add_feedback_row(rows, todo) when is_map(todo) do
    case {todo_id(todo), feedback_value(todo)} do
      {todo_id, value} when is_binary(todo_id) and value in @feedback_values ->
        rows

      {todo_id, _value} when is_binary(todo_id) ->
        rows ++
          [
            [
              %{"text" => "Helpful", "callback_data" => callback_data(todo_id, "helpful")},
              %{"text" => "Not Helpful", "callback_data" => callback_data(todo_id, "not_helpful")}
            ]
          ]

      _ ->
        rows
    end
  end

  defp maybe_add_feedback_row(rows, _todo), do: rows

  defp maybe_add_link_row(rows, todo) when is_map(todo) do
    buttons =
      [
        source_link_button(todo),
        %{"text" => "Open Dashboard", "url" => "#{Endpoint.url()}/dashboard"}
      ]
      |> Enum.reject(&is_nil/1)

    if buttons == [], do: rows, else: rows ++ [buttons]
  end

  defp render_message(todo, prefix_text) when is_map(todo) do
    metadata = todo_metadata(todo)
    account = metadata_account(metadata)
    todo_source = todo_source(todo)
    source = source_label(todo_source)
    feedback = feedback_label(feedback_value(todo))
    next_action = display_text(todo_next_action(todo))
    context = display_text(todo_context(todo, metadata))
    assistant_source? = assistant_source?(todo_source)

    [
      display_text(prefix_text),
      action_line(next_action, assistant_source?),
      todo_context_line(context, next_action),
      source_sentence(source, account, assistant_source?),
      feedback && "Feedback noted: #{safe(feedback)}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp source_label("gmail"), do: "Gmail"
  defp source_label("slack"), do: "Slack"
  defp source_label("github"), do: "GitHub"
  defp source_label("calendar"), do: "Calendar"

  defp source_label(source) when is_binary(source) do
    if assistant_source?(source), do: nil, else: String.capitalize(source)
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
        "Kent, I'd review this."

      Regex.match?(~r/^(I'd|I would|I can|I'll|Let me|You|We)\b/i, action) ->
        "Kent, #{lower_first(action)}"

      true ->
        "Kent, I'd #{lower_first(action)}"
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

  defp lower_first(<<first::utf8, rest::binary>>) do
    String.downcase(<<first::utf8>>) <> rest
  end

  defp lower_first(value), do: value

  defp source_link_button(todo) do
    case source_url(todo_metadata(todo)) do
      url when is_binary(url) -> %{"text" => "Open Source", "url" => url}
      _ -> nil
    end
  end

  defp source_url(metadata) when is_map(metadata) do
    metadata
    |> direct_source_url()
    |> normalize_url()
  end

  defp source_url(_metadata), do: nil

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

  defp source_sentence(_source, _account, true), do: nil
  defp source_sentence(nil, _account, _assistant_source?), do: nil
  defp source_sentence("Operator", _account, _assistant_source?), do: nil

  defp source_sentence(source, account, _assistant_source?),
    do: "I found this in #{safe(source)}#{render_account(account)}."

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
    todo_summary(todo) ||
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

  defp metadata_context(metadata) when is_map(metadata) do
    record = read_map(metadata, "record")

    [
      read_string(metadata, "context"),
      read_string(metadata, "context_brief"),
      read_string(metadata, "why_now"),
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
    do: next_action || title || "Review and decide the next step."

  defp todo_next_action(todo) when is_map(todo),
    do:
      map_string(todo, "next_action") || map_string(todo, "title") ||
        "Review and decide the next step."

  defp todo_next_action(_todo), do: "Review and decide the next step."

  defp display_text(text) when is_binary(text) do
    text
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
    |> String.replace(~r/\bthe user\b/i, "you")
    |> String.replace(
      ~r/\bquick status check on whether the issue is resolved, who owns it, and whether users or customers were affected\b/i,
      "quick answer on whether it is fixed, who owns the follow-up, and whether any users or customers were affected"
    )
    |> String.replace(~r/\bChief_of_staff_morning_briefing\b/i, "my morning briefing")
    |> String.replace(~r/\bchief_of_staff_morning_briefing\b/i, "my morning briefing")
    |> String.replace(~r/\bChief_of_staff_commitment_tracker\b/i, "my commitment tracker")
    |> String.replace(~r/\bchief_of_staff_commitment_tracker\b/i, "my commitment tracker")
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
  defp feedback_label("not_helpful"), do: "Not Helpful"
  defp feedback_label(_value), do: nil

  defp callback_notice("done"), do: "Marked done"
  defp callback_notice("dismiss"), do: "Marked not interested"
  defp callback_notice("helpful"), do: "Saved helpful feedback"
  defp callback_notice("not_helpful"), do: "Saved not helpful feedback"

  defp callback_error_text(reason) when is_binary(reason),
    do: "I couldn't update that todo yet: #{reason}"

  defp callback_error_text(reason), do: "I couldn't update that todo yet: #{inspect(reason)}"

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

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp safe(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp safe(value), do: to_string(value || "")
end
