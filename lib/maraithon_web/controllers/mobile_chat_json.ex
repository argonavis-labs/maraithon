defmodule MaraithonWeb.MobileChatJSON do
  @moduledoc false

  alias Maraithon.TelegramAssistant.{PreparedAction, Run}
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.WorkSummary
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.Todos.{PublicPayload, Todo, UserFacingCopy}
  alias Maraithon.AssistantChat.ThreadNaming
  alias Maraithon.{CalendarLinks, Crm, LocalCalendar, LocalMessages, Timezones}
  alias Maraithon.Repo
  alias MaraithonWeb.ApiErrorCopy

  @availability_timezone "America/Toronto"
  @availability_offset_hours -5
  @availability_slot_minutes 30
  @availability_candidate_hours [10, 12, 14, 15]

  @public_structured_data_keys ~w(calculation draft_card)
  @internal_assistant_markers [
    "<redacted",
    "=>",
    "{",
    "}",
    "confidence_score",
    "quality_score",
    "priority_score",
    "urgency_score",
    "relevance_score",
    "interrupt_score",
    "source_health",
    "quality_verification",
    "generation_mode",
    "message_class",
    "model_name",
    "model_provider",
    "model_response",
    "model confidence",
    "model reasoning",
    "model score",
    "configured model",
    "model synthesis",
    "generation failed",
    "did not produce a valid brief",
    "checked source view",
    "valid json",
    "structured json",
    "reasoning_effort",
    "finish_reason",
    "max_output_tokens",
    "input_tokens",
    "output_tokens",
    "total_tokens",
    "prompt_snapshot",
    "system_prompt",
    "raw_prompt",
    "tool_call",
    "tool call",
    "tool_name",
    "http_status",
    "db_timeout",
    "stacktrace",
    "postgrex",
    "ecto.",
    "phoenix.",
    "dbconnection",
    "metadata",
    "internal_",
    "token=",
    "token:",
    "authorization",
    "bearer",
    "access_token",
    "refresh_token",
    "client_secret",
    "private_key",
    "api_key",
    "apikey",
    "secret=",
    "secret:"
  ]
  @internal_assistant_patterns [
    ~r/\b(?:confidence|quality|priority|urgency|relevance|interrupt)_score\s*[:=]/,
    ~r/\b\d{1,3}%\s+confidence\b/,
    ~r/\bconfidence\s+(?:this|that|was|is)\b/,
    ~r/^\s*reasoning\s*:/,
    ~r/\bmodel\s+(?:classified|confidence|ranked|reasoning|saw|score)\b/,
    ~r/\bscore\s*[:=]\s*\d/,
    ~r/\bscore\s+(?:says|was|is)\b/,
    ~r/\bthreshold\s*[:=]\s*\d/,
    ~r/\b(?:token|secret|password|api[_-]?key|access[_-]?token|refresh[_-]?token)\s*[:=]/,
    ~r/\b(?:authorization|bearer)\b/
  ]
  @action_card_label_pattern ~r/^(\s*(?:Context used|Context|Decision|Why now|State|Next|Suggested reply|Draft|Prepared|Evidence):\s*)(.*)$/i

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
      error: public_run_error(run),
      message_class: summary_value(run.result_summary, :message_class),
      work_summary: WorkSummary.for_run(run)
    }
  end

  def prepared_action(%PreparedAction{} = prepared_action) do
    %{
      id: prepared_action.id,
      status: prepared_action.status,
      action_type: prepared_action.action_type,
      target_type: prepared_action.target_type,
      preview_text: prepared_action.preview_text,
      draft_card: prepared_action_draft_card(prepared_action),
      expires_at: json_value(prepared_action.expires_at)
    }
  end

  def error(reason), do: ApiErrorCopy.mobile_chat(reason)

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
      latest_message: latest && message(latest, conversation)
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
        |> Enum.map(&message(&1, conversation))
    }
  end

  defp message(%Turn{} = turn, %Conversation{} = conversation) do
    structured_data = turn.structured_data || %{}
    prepared_action_id = structured_data["prepared_action_id"]

    public_structured_data =
      structured_data
      |> public_structured_data()
      |> maybe_put_public_draft_card(
        draft_card_for_turn(conversation, structured_data, prepared_action_id)
      )

    %{
      id: turn.id,
      client_message_id: turn.client_message_id || structured_data["client_message_id"],
      role: turn.role,
      body: public_message_body(turn),
      turn_kind: turn.turn_kind,
      message_class: structured_data["message_class"],
      sent_at: json_value(turn.inserted_at),
      delivery_state: turn.delivery_state || "delivered",
      run_id: structured_data["run_id"],
      actions: actions_for(turn, prepared_action_id),
      linked_todo: public_linked_todo(structured_data["linked_todo"]),
      work_summary: WorkSummary.for_message(turn),
      structured_data: public_structured_data
    }
  end

  defp public_message_body(%Turn{role: "assistant", text: text} = turn) when is_binary(text) do
    text
    |> strip_message_role_prefix()
    |> then(fn stripped_text ->
      if action_card_message?(turn.structured_data) do
        public_action_card_message_text(stripped_text)
      else
        public_assistant_message_text(stripped_text)
      end
    end)
  end

  defp public_message_body(%Turn{text: text}), do: text

  defp strip_message_role_prefix(value) do
    value
    |> String.replace(~r/(^|\n)\s*(?:assistant|maraithon|system)\s*:\s*/i, "\\1")
    |> String.trim()
  end

  defp public_assistant_message_text(value) do
    safe_text =
      value
      |> String.split("\n", trim: false)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&unsafe_assistant_line?/1)
      |> Enum.map(&product_message_text/1)
      |> Enum.join("\n")
      |> String.trim()

    cond do
      safe_text != "" ->
        safe_text

      unsafe_assistant_text?(value) ->
        ApiErrorCopy.mobile_chat_run_error(value)

      true ->
        value
        |> product_message_text()
        |> String.trim()
    end
  end

  defp public_action_card_message_text(value) do
    safe_text =
      value
      |> String.split("\n", trim: false)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&unsafe_assistant_line?/1)
      |> Enum.map(&product_action_card_message_text/1)
      |> Enum.join("\n")
      |> String.trim()

    cond do
      safe_text != "" ->
        safe_text

      unsafe_assistant_text?(value) ->
        ApiErrorCopy.mobile_chat_run_error(value)

      true ->
        value
        |> product_action_card_message_text()
        |> String.trim()
    end
  end

  defp action_card_message?(%{"message_class" => "todo_item"}), do: true
  defp action_card_message?(%{message_class: "todo_item"}), do: true
  defp action_card_message?(_structured_data), do: false

  defp unsafe_assistant_line?(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        false

      unsafe_assistant_text?(trimmed) ->
        true

      true ->
        false
    end
  end

  defp unsafe_assistant_text?(value) when is_binary(value) do
    lower = String.downcase(value)

    technical_message_body?(value) or
      Enum.any?(@internal_assistant_markers, &String.contains?(lower, &1)) or
      Enum.any?(@internal_assistant_patterns, &Regex.match?(&1, lower))
  end

  defp unsafe_assistant_text?(_value), do: true

  defp product_message_text(value) when is_binary(value) do
    value
    |> UserFacingCopy.open_work_language()
    |> String.replace(~r/\bCRM context\b/i, "relationship context")
    |> String.replace(~r/\bCRM\b/i, "relationship data")
  end

  defp product_message_text(value), do: value

  defp product_action_card_message_text(value) when is_binary(value) do
    case Regex.run(@action_card_label_pattern, value, capture: :all_but_first) do
      [label, body] -> label <> product_message_text(body)
      _other -> product_message_text(value)
    end
  end

  defp product_action_card_message_text(value), do: value

  defp technical_message_body?(value) do
    Regex.match?(
      ~r/(?:\b(?:authorization|bearer|access_token|refresh_token|client_secret|api[_-]?key|token|http_status)\b\s*[:=]|\b(?:stacktrace|internal_stacktrace|FunctionClauseError|RuntimeError|DBConnection|Postgrex|clientError|serverError)\b|\b(?:Ecto|Phoenix|Elixir)\.)/i,
      value
    )
  end

  defp public_linked_todo(nil), do: nil

  defp public_linked_todo(%Todo{} = todo), do: PublicPayload.todo(todo)

  defp public_linked_todo(%{} = todo), do: PublicPayload.todo(todo)

  defp public_linked_todo(_linked_todo), do: nil

  defp public_structured_data(structured_data) when is_map(structured_data) do
    Enum.reduce(structured_data, %{}, fn {key, value}, acc ->
      key = to_string(key)

      if key in @public_structured_data_keys do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp public_structured_data(_structured_data), do: %{}

  defp maybe_put_public_draft_card(public_data, nil), do: public_data

  defp maybe_put_public_draft_card(public_data, draft_card),
    do: Map.put(public_data, "draft_card", draft_card)

  defp actions_for(%Turn{turn_kind: "approval_prompt"}, prepared_action_id)
       when is_binary(prepared_action_id) do
    case pending_prepared_action(prepared_action_id) do
      %PreparedAction{} = prepared_action ->
        [
          %{
            id: prepared_action_id,
            kind: "prepared_action_decision",
            label: prepared_action_confirm_label(prepared_action),
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

      _ ->
        []
    end
  end

  defp actions_for(_turn, _prepared_action_id), do: []

  defp pending_prepared_action(prepared_action_id) do
    case Repo.get(PreparedAction, prepared_action_id) do
      %PreparedAction{status: "awaiting_confirmation"} = prepared_action -> prepared_action
      _ -> nil
    end
  end

  defp prepared_action_confirm_label(%PreparedAction{action_type: action_type})
       when action_type in ["gmail_send", "gmail_draft_send", "slack_post"],
       do: "Send"

  defp prepared_action_confirm_label(_prepared_action), do: "Confirm"

  defp draft_card_for_turn(
         %Conversation{} = conversation,
         structured_data,
         prepared_action_id
       ) do
    cond do
      is_binary(prepared_action_id) ->
        PreparedAction
        |> Repo.get(prepared_action_id)
        |> prepared_action_draft_card()

      get_in(structured_data || %{}, ["message_class"]) == "todo_chat_primer" ->
        todo_primer_draft_card(conversation.user_id, structured_data)

      true ->
        nil
    end
  end

  defp prepared_action_draft_card(%PreparedAction{} = prepared_action) do
    payload = prepared_action.payload || %{}

    base =
      %{"status" => prepared_action_status_label(prepared_action)}
      |> maybe_put_action(prepared_action)

    case prepared_action.action_type do
      "gmail_draft_send" ->
        %{
          "provider" => "gmail",
          "title" => "Gmail draft ready",
          "draft_id" => read_string(payload, "draft_id") || read_string(payload, "id"),
          "from" => email_from_field(payload),
          "recipient" => email_recipient_field(payload),
          "cc" => email_display_field(payload, ["cc"]),
          "bcc" => email_display_field(payload, ["bcc"]),
          "subject" => email_field(payload, ["subject"]),
          "body" => email_field(payload, ["body", "text"])
        }
        |> Map.merge(base)
        |> compact_public_map()

      "gmail_send" ->
        %{
          "provider" => "gmail",
          "title" => "Gmail message ready",
          "from" => email_from_field(payload),
          "recipient" => email_recipient_field(payload),
          "cc" => email_display_field(payload, ["cc"]),
          "bcc" => email_display_field(payload, ["bcc"]),
          "subject" => email_field(payload, ["subject"]),
          "body" => email_field(payload, ["body", "text"])
        }
        |> Map.merge(base)
        |> compact_public_map()

      "slack_post" ->
        %{
          "provider" => "slack",
          "title" => "Slack message ready",
          "from" =>
            public_display_value(payload, ["from", "sender", "account", "source_account_label"]),
          "recipient" => slack_conversation_label(payload),
          "workspace" => public_display_value(payload, ["workspace_name", "team_name"]),
          "body" => read_string(payload, "text")
        }
        |> Map.merge(base)
        |> compact_public_map()

      _ ->
        nil
    end
  end

  defp prepared_action_draft_card(_prepared_action), do: nil

  defp maybe_put_action(base, %PreparedAction{} = prepared_action) do
    if prepared_action_sendable?(prepared_action) do
      base
      |> Map.put("prepared_action_id", prepared_action.id)
      |> Map.put("send_label", prepared_action_confirm_label(prepared_action))
    else
      base
    end
  end

  defp prepared_action_sendable?(
         %PreparedAction{status: "awaiting_confirmation"} = prepared_action
       ) do
    not TelegramAssistant.prepared_action_expired?(prepared_action)
  end

  defp prepared_action_sendable?(_prepared_action), do: false

  defp prepared_action_status_label(%PreparedAction{status: "executed"}), do: "Sent"
  defp prepared_action_status_label(%PreparedAction{status: "confirmed"}), do: "Sending"
  defp prepared_action_status_label(%PreparedAction{status: "failed"}), do: "Could not send"
  defp prepared_action_status_label(%PreparedAction{status: "rejected"}), do: "Cancelled"
  defp prepared_action_status_label(%PreparedAction{status: "expired"}), do: "Expired"

  defp prepared_action_status_label(
         %PreparedAction{status: "awaiting_confirmation"} = prepared_action
       ) do
    if TelegramAssistant.prepared_action_expired?(prepared_action) do
      "Expired"
    else
      pending_prepared_action_status_label(prepared_action)
    end
  end

  defp prepared_action_status_label(%PreparedAction{action_type: "gmail_draft_send"}),
    do: "Saved in Gmail"

  defp prepared_action_status_label(_prepared_action), do: nil

  defp pending_prepared_action_status_label(%PreparedAction{action_type: "gmail_draft_send"}),
    do: "Saved in Gmail"

  defp pending_prepared_action_status_label(_prepared_action), do: "Ready to send"

  defp email_from_field(payload) do
    email_display_field(payload, [
      "from",
      "account",
      "google_account_email",
      "account_email",
      "source_account_label"
    ])
  end

  defp email_recipient_field(payload) do
    email_display_field(payload, [
      "recipient",
      "to",
      "recipient_email",
      "reply_to",
      "from_email",
      "source_from"
    ])
  end

  defp email_display_field(payload, keys) do
    payload
    |> email_field(keys)
    |> public_service_display_value()
  end

  defp email_field(payload, keys) when is_map(payload) and is_list(keys) do
    keys
    |> Enum.find_value(fn key ->
      read_string(payload, key) ||
        payload
        |> nested_email_maps()
        |> Enum.find_value(&read_string(&1, key))
    end)
  end

  defp email_field(_payload, _keys), do: nil

  defp nested_email_maps(payload) when is_map(payload) do
    [
      read_map(payload, "draft"),
      read_map(payload, "message"),
      read_map(payload, "headers"),
      payload |> read_map("draft") |> read_map("message"),
      payload |> read_map("draft") |> read_map("headers"),
      payload |> read_map("message") |> read_map("headers")
    ]
    |> Enum.reject(&blank_public_value?/1)
  end

  defp todo_primer_draft_card(user_id, structured_data)
       when is_binary(user_id) and is_map(structured_data) do
    with %{} = linked_todo <- Map.get(structured_data, "linked_todo"),
         source when is_binary(source) <- primer_action_source(linked_todo, structured_data) do
      case source do
        "gmail" -> todo_primer_gmail_card(user_id, structured_data, linked_todo)
        "slack" -> todo_primer_slack_card(user_id, structured_data, linked_todo)
        "imessage" -> todo_primer_imessage_card(user_id, structured_data, linked_todo)
        "whatsapp" -> todo_primer_whatsapp_card(user_id, structured_data, linked_todo)
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp todo_primer_draft_card(_user_id, _structured_data), do: nil

  defp todo_primer_gmail_card(user_id, structured_data, linked_todo) do
    draft = read_map(linked_todo, "action_draft")
    metadata = read_map(linked_todo, "metadata")

    with body when is_binary(body) <- primer_draft_body(structured_data, linked_todo) do
      body = fallback_calendar_enriched_gmail_body(user_id, linked_todo, body)
      from = fallback_gmail_from(user_id, linked_todo, draft, metadata)
      recipient = fallback_gmail_recipient(user_id, linked_todo, draft, metadata, body, from)

      %{
        "provider" => "gmail",
        "title" => "Gmail draft ready",
        "status" => "Reconnect Gmail to send",
        "from" => from,
        "recipient" => recipient,
        "cc" => email_display_value(read_string(draft, "cc")),
        "bcc" => email_display_value(read_string(draft, "bcc")),
        "subject" =>
          read_string(draft, "subject") || read_string(metadata, "subject") ||
            read_string(linked_todo, "title"),
        "body" => body
      }
      |> compact_public_map()
    end
  end

  defp fallback_gmail_from(user_id, linked_todo, draft, metadata) do
    direct =
      [
        email_field(draft, ["from", "account", "google_account_email", "account_email"]),
        email_field(metadata, ["google_account_email", "account_email", "account", "mailbox"]),
        read_string(linked_todo, "source_account_label")
      ]
      |> Enum.find_value(&public_service_display_value/1)

    cond do
      is_binary(direct) ->
        direct

      valid_email_destination(email_field(metadata, ["from", "from_email"])) in gmail_identity_emails(
        user_id,
        linked_todo,
        draft,
        metadata,
        nil
      ) ->
        email_display_value(email_field(metadata, ["from", "from_email"]))

      valid_email_destination(email_field(metadata, ["to", "recipient", "delivered_to"])) in gmail_identity_emails(
        user_id,
        linked_todo,
        draft,
        metadata,
        nil
      ) ->
        email_display_value(email_field(metadata, ["to", "recipient", "delivered_to"]))

      true ->
        connected_gmail_account_emails(user_id)
        |> List.first()
        |> Kernel.||(valid_email_destination(user_id))
        |> Kernel.||(email_display_value(email_field(metadata, ["to", "from"])))
    end
  end

  defp fallback_gmail_recipient(user_id, linked_todo, draft, metadata, body, from) do
    identities = gmail_identity_emails(user_id, linked_todo, draft, metadata, from)

    source_recipient =
      [
        email_field(metadata, ["reply_to", "from_email", "from"]),
        email_field(metadata, ["to", "recipient", "delivered_to"])
      ]
      |> Enum.find_value(fn value ->
        email = valid_email_destination(value)

        if is_binary(email) and email not in identities do
          value
        end
      end)

    [
      email_field(draft, ["recipient", "to", "recipient_email"]),
      source_recipient
    ]
    |> Enum.find_value(fn value ->
      email = valid_email_destination(value)

      if is_binary(email) and email not in identities do
        email
      end
    end)
    |> case do
      email when is_binary(email) ->
        email

      nil ->
        crm_email_for_gmail_recipient(user_id, linked_todo, draft, metadata, body)
    end
  end

  defp gmail_identity_emails(user_id, linked_todo, draft, metadata, from) do
    direct =
      [
        from,
        email_field(draft, ["from", "account", "google_account_email", "account_email"]),
        email_field(metadata, ["google_account_email", "account_email", "account", "mailbox"]),
        read_string(linked_todo, "source_account_label"),
        user_id
      ]
      |> Enum.map(&valid_email_destination/1)

    (direct ++ connected_gmail_account_emails(user_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp connected_gmail_account_emails(user_id) when is_binary(user_id) do
    user_id
    |> Maraithon.OAuth.list_user_tokens()
    |> Enum.flat_map(fn token ->
      [
        gmail_email_from_provider(token.provider),
        token.metadata |> read_string("email"),
        token.metadata |> read_string("account_email"),
        token.metadata |> read_string("google_account_email")
      ]
    end)
    |> Enum.map(&valid_email_destination/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  defp connected_gmail_account_emails(_user_id), do: []

  defp gmail_email_from_provider("google:" <> email), do: email
  defp gmail_email_from_provider(_provider), do: nil

  defp crm_email_for_gmail_recipient(user_id, linked_todo, draft, metadata, body)
       when is_binary(user_id) do
    linked_todo
    |> gmail_recipient_name_candidates(draft, metadata, body)
    |> Enum.find_value(fn query ->
      user_id
      |> Crm.search_people(query, limit: 5)
      |> Enum.find_value(&crm_person_email/1)
    end)
  rescue
    _ -> nil
  end

  defp crm_email_for_gmail_recipient(_user_id, _linked_todo, _draft, _metadata, _body), do: nil

  defp crm_person_email(%{contact_details: contact_details}) when is_map(contact_details) do
    [
      Map.get(contact_details, "emails"),
      Map.get(contact_details, "email")
    ]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.find_value(&valid_email_destination/1)
  end

  defp crm_person_email(_person), do: nil

  defp gmail_recipient_name_candidates(linked_todo, draft, metadata, body) do
    metadata_names =
      metadata
      |> read_metadata_people()
      |> Enum.flat_map(fn person ->
        [
          read_string(person, "display_name"),
          [read_string(person, "first_name"), read_string(person, "last_name")]
          |> Enum.reject(&blank_public_value?/1)
          |> Enum.join(" ")
        ]
      end)

    direct_names = [
      read_string(draft, "recipient_name"),
      read_string(draft, "recipient"),
      read_string(draft, "to"),
      read_string(metadata, "person"),
      display_name_from_email_header(read_string(metadata, "from"))
    ]

    text_names =
      [
        read_string(linked_todo, "title"),
        read_string(linked_todo, "summary"),
        read_string(linked_todo, "next_action"),
        read_string(draft, "text"),
        body
      ]
      |> Enum.flat_map(&recipient_names_from_text/1)

    (metadata_names ++ direct_names ++ text_names)
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&clean_recipient_name_candidate/1)
    |> Enum.reject(&blank_public_value?/1)
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp read_metadata_people(metadata) when is_map(metadata) do
    case Map.get(metadata, "crm_people") || Map.get(metadata, :crm_people) do
      people when is_list(people) -> Enum.filter(people, &is_map/1)
      %{} = person -> [person]
      _other -> []
    end
  end

  defp read_metadata_people(_metadata), do: []

  defp valid_email_destination(value) when is_binary(value) do
    case Regex.run(~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, value) do
      [email] -> String.downcase(email)
      _other -> nil
    end
  end

  defp valid_email_destination(_value), do: nil

  defp display_name_from_email_header(value) when is_binary(value) do
    case Regex.run(~r/^\s*"?([^"<@]+?)"?\s*<[^>]+>/, value) do
      [_all, name] -> name
      _other -> nil
    end
  end

  defp display_name_from_email_header(_value), do: nil

  defp recipient_names_from_text(text) when is_binary(text) do
    [
      ~r/\breply\s+to\s+([A-Z][A-Za-z'’-]+(?:\s+[A-Z][A-Za-z'’-]+){0,2})(?:\s*(?:\(|:|,|\.|$))/,
      ~r/\bto\s+([A-Z][A-Za-z'’-]+(?:\s+[A-Z][A-Za-z'’-]+){0,2})(?:\s*(?:\(|:|,|\.|$))/,
      ~r/\bmessage\s+([A-Z][A-Za-z'’-]+(?:\s+[A-Z][A-Za-z'’-]+){0,2})(?:\s+on|\s+to|\s*:|,|\.|$)/,
      ~r/\bwith\s+([A-Z][A-Za-z'’-]+(?:\s+[A-Z][A-Za-z'’-]+){0,2})(?:\s*(?:\(|:|,|\.|$))/,
      ~r/\bemail\s+([A-Z][A-Za-z'’-]+(?:\s+[A-Z][A-Za-z'’-]+){0,2})(?:\s*:|,|\.|$)/
    ]
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, text)
      |> Enum.map(fn
        [_all, name] -> name
        _other -> nil
      end)
    end)
  end

  defp recipient_names_from_text(_text), do: []

  defp clean_recipient_name_candidate(value) when is_binary(value) do
    value =
      value
      |> String.replace(~r/<[^>]+>/, "")
      |> String.replace(~r/\s*\([^)]*\)\s*$/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim(" .,:;!?\"'()[]")

    downcased = String.downcase(value)

    cond do
      value == "" -> nil
      Regex.match?(~r/@/, value) -> nil
      String.length(value) > 80 -> nil
      downcased in ["gmail", "email", "slack", "messages", "whatsapp", "availability"] -> nil
      true -> value
    end
  end

  defp clean_recipient_name_candidate(_value), do: nil

  defp fallback_calendar_enriched_gmail_body(user_id, linked_todo, body)
       when is_binary(user_id) and is_binary(body) do
    if fallback_scheduling_reply?(linked_todo, body) do
      calendar_link = fallback_calendly_link_for(user_id, linked_todo, body)
      slot_minutes = fallback_calendar_link_duration_minutes(calendar_link)

      updated_body =
        case fallback_calendar_slot_labels(user_id, 2, slot_minutes) do
          [_slot | _] = labels ->
            cond do
              String.contains?(String.downcase(body), ["[day]", "[time]"]) ->
                body
                |> fallback_replace_availability_placeholders(labels)
                |> fallback_maybe_add_availability_sentence(labels)

              fallback_simple_availability_reply?(body) ->
                fallback_generated_availability_body(linked_todo, body, labels)

              true ->
                fallback_maybe_add_availability_sentence(body, labels)
            end

          [] ->
            body
        end

      fallback_maybe_add_calendly_link(updated_body, calendar_link)
    else
      body
    end
  rescue
    _ -> body
  end

  defp fallback_calendar_enriched_gmail_body(_user_id, _linked_todo, body), do: body

  defp fallback_scheduling_reply?(linked_todo, body) do
    text =
      [
        read_string(linked_todo, "title"),
        read_string(linked_todo, "summary"),
        read_string(linked_todo, "next_action"),
        body
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    scheduling_intent? =
      String.contains?(text, [
        "availability",
        "available",
        "schedule",
        "scheduling",
        "meet",
        "meeting",
        "call",
        "chat"
      ])

    slot_request_or_draft? =
      String.contains?(text, ["[day]", "[time]", "time slots", "few time", "available"]) or
        fallback_calendar_time_like?(text)

    scheduling_intent? and slot_request_or_draft?
  end

  defp fallback_calendar_time_like?(text) when is_binary(text) do
    Regex.match?(
      ~r/\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|\d{1,2}\/\d{1,2}|\d{1,2}(?::\d{2})?\s*(?:am|pm))\b/i,
      text
    )
  end

  defp fallback_calendar_time_like?(_text), do: false

  defp fallback_simple_availability_reply?(body) when is_binary(body) do
    text = body |> String.trim() |> String.downcase()

    String.length(text) <= 220 and
      (String.contains?(text, ["works best", "i can do", "available", "availability"]) or
         fallback_calendar_time_like?(text))
  end

  defp fallback_simple_availability_reply?(_body), do: false

  defp fallback_generated_availability_body(linked_todo, body, labels) do
    draft = read_map(linked_todo, "action_draft")
    metadata = read_map(linked_todo, "metadata")

    greeting =
      linked_todo
      |> gmail_recipient_name_candidates(draft, metadata, body)
      |> Enum.find_value(fn name ->
        name
        |> String.split(~r/\s+/, parts: 2)
        |> List.first()
        |> read_public_text()
      end)
      |> case do
        nil -> nil
        first_name -> "Hi #{first_name},"
      end

    availability = "#{fallback_availability_sentence(labels)} works best for me."

    closing =
      case fallback_meeting_person_name(linked_todo, body) do
        nil -> "Looking forward to speaking."
        name -> "Looking forward to speaking with #{name}."
      end

    [greeting, "#{availability} #{closing}"]
    |> Enum.reject(&blank_public_value?/1)
    |> Enum.join("\n\n")
  end

  defp fallback_meeting_person_name(linked_todo, body) do
    [
      read_string(linked_todo, "title"),
      read_string(linked_todo, "summary"),
      read_string(linked_todo, "next_action"),
      body
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.find_value(fn text ->
      case Regex.run(~r/\bspeaking with\s+([A-Z][A-Za-z'’-]+(?:\s+[A-Z][A-Za-z'’-]+)?)/, text) do
        [_all, name] -> read_public_text(name)
        _other -> nil
      end
    end)
  end

  defp fallback_replace_availability_placeholders(body, labels) do
    {updated, replaced?} =
      Enum.reduce(labels, {body, false}, fn label, {acc, replaced?} ->
        next =
          Regex.replace(
            ~r/\[Day\]\s+at\s+\[Time\](?:\s*(?:EDT|EST|ET))?/i,
            acc,
            label,
            global: false
          )

        if next == acc, do: {acc, replaced?}, else: {next, true}
      end)

    if replaced? do
      updated
    else
      case List.first(labels) do
        nil ->
          body

        label ->
          body
          |> Regex.replace(~r/\[Day\]\s*,?\s*\[Time\](?:\s*(?:EDT|EST|ET))?/i, label,
            global: false
          )
          |> String.replace("[Day]", fallback_calendar_date_part(label), global: false)
          |> String.replace("[Time]", fallback_calendar_time_part(label), global: false)
      end
    end
  end

  defp fallback_maybe_add_availability_sentence(updated_body, labels) do
    if String.contains?(updated_body, ["[Day]", "[day]", "[Time]", "[time]"]) do
      sentence = "I can do #{fallback_availability_sentence(labels)}."

      updated_body
      |> String.replace(~r/\s+Let me know/i, " #{sentence} Let me know", global: false)
      |> String.replace("[Day]", "")
      |> String.replace("[Time]", "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    else
      updated_body
    end
  end

  defp fallback_calendly_link_for(user_id, linked_todo, body) do
    CalendarLinks.best_link_for(user_id, linked_todo, body)
  rescue
    _ -> nil
  end

  defp fallback_calendar_link_duration_minutes(%{duration_minutes: minutes})
       when is_integer(minutes) and minutes >= 5,
       do: min(minutes, 180)

  defp fallback_calendar_link_duration_minutes(_link), do: @availability_slot_minutes

  defp fallback_maybe_add_calendly_link(body, %{url: url} = link)
       when is_binary(body) and is_binary(url) do
    if String.contains?(String.downcase(body), "calendly.com") do
      body
    else
      [String.trim(body), fallback_calendly_link_sentence(link)]
      |> Enum.reject(&blank_public_value?/1)
      |> Enum.join("\n\n")
    end
  end

  defp fallback_maybe_add_calendly_link(body, _link), do: body

  defp fallback_calendly_link_sentence(link) do
    "If easier, use my #{CalendarLinks.display_label(link)}: #{link.url}"
  end

  defp fallback_calendar_slot_labels(user_id, limit, slot_minutes) do
    user_id
    |> fallback_calendar_slots(limit, slot_minutes)
    |> Enum.map(&fallback_calendar_slot_label/1)
  end

  defp fallback_calendar_slots(user_id, limit, slot_minutes) when is_binary(user_id) do
    slot_minutes = fallback_normalize_slot_minutes(slot_minutes)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    local_today = fallback_local_date(now)
    window_start = fallback_local_boundary_to_utc(Date.add(local_today, 1), ~T[00:00:00])
    window_end = fallback_local_boundary_to_utc(Date.add(local_today, 10), ~T[23:59:59])

    events =
      user_id
      |> LocalCalendar.events_around(since: window_start, until: window_end, limit: 300)
      |> Enum.reject(&(&1.is_all_day == true))

    local_today
    |> fallback_candidate_slot_starts()
    |> Enum.reject(&fallback_slot_busy?(&1, events, slot_minutes))
    |> Enum.take(limit)
    |> Enum.map(fn start_at ->
      %{start_at: start_at, end_at: DateTime.add(start_at, slot_minutes, :minute)}
    end)
  rescue
    _ -> []
  end

  defp fallback_calendar_slots(_user_id, _limit, _slot_minutes), do: []

  defp fallback_normalize_slot_minutes(minutes) when is_integer(minutes),
    do: min(max(minutes, 5), 180)

  defp fallback_normalize_slot_minutes(_minutes), do: @availability_slot_minutes

  defp fallback_candidate_slot_starts(local_today) do
    1..10
    |> Enum.map(&Date.add(local_today, &1))
    |> Enum.reject(&(Date.day_of_week(&1) in [6, 7]))
    |> Enum.flat_map(fn date ->
      Enum.map(@availability_candidate_hours, fn hour ->
        fallback_local_boundary_to_utc(date, Time.new!(hour, 0, 0))
      end)
    end)
  end

  defp fallback_slot_busy?(start_at, events, slot_minutes) do
    end_at = DateTime.add(start_at, slot_minutes, :minute)

    Enum.any?(events, fn event ->
      with %DateTime{} = event_start <- event.start_at,
           %DateTime{} = event_end <- event.end_at do
        DateTime.compare(start_at, event_end) == :lt and
          DateTime.compare(end_at, event_start) == :gt
      else
        _ -> false
      end
    end)
  end

  defp fallback_calendar_slot_label(%{start_at: %DateTime{} = start_at}) do
    offset = Timezones.offset_at(@availability_timezone, start_at, @availability_offset_hours)
    local = DateTime.add(start_at, offset, :hour)

    "#{fallback_weekday_name(local)} #{fallback_month_name(local)} #{local.day} at #{fallback_clock_label(local)} #{fallback_timezone_label(start_at)}"
  end

  defp fallback_availability_sentence([one]), do: one
  defp fallback_availability_sentence([one, two]), do: "#{one} or #{two}"
  defp fallback_availability_sentence(_labels), do: "one of these times"

  defp fallback_calendar_date_part(label) when is_binary(label) do
    label |> String.split(" at ", parts: 2) |> List.first()
  end

  defp fallback_calendar_date_part(_label), do: ""

  defp fallback_calendar_time_part(label) when is_binary(label) do
    case String.split(label, " at ", parts: 2) do
      [_date, time] -> time
      _ -> ""
    end
  end

  defp fallback_calendar_time_part(_label), do: ""

  defp fallback_local_date(%DateTime{} = datetime) do
    offset = Timezones.offset_at(@availability_timezone, datetime, @availability_offset_hours)

    datetime
    |> DateTime.add(offset, :hour)
    |> DateTime.to_date()
  end

  defp fallback_local_boundary_to_utc(%Date{} = date, %Time{} = time) do
    local_boundary = DateTime.new!(date, time, "Etc/UTC")

    offset =
      Timezones.offset_for_local(
        @availability_timezone,
        local_boundary,
        @availability_offset_hours
      )

    DateTime.add(local_boundary, -offset, :hour)
  end

  defp fallback_timezone_label(%DateTime{} = datetime) do
    offset = Timezones.offset_at(@availability_timezone, datetime, @availability_offset_hours)
    Timezones.label(@availability_timezone, offset)
  end

  defp fallback_weekday_name(%DateTime{} = datetime) do
    ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
    |> Enum.at(Date.day_of_week(DateTime.to_date(datetime)) - 1)
  end

  defp fallback_month_name(%DateTime{month: month}) do
    ~w(January February March April May June July August September October November December)
    |> Enum.at(month - 1)
  end

  defp fallback_clock_label(%DateTime{} = datetime) do
    hour = datetime.hour
    minute = datetime.minute
    meridiem = if hour < 12, do: "AM", else: "PM"
    display_hour = rem(hour + 11, 12) + 1

    if minute == 0 do
      "#{display_hour}:00 #{meridiem}"
    else
      "#{display_hour}:#{Integer.to_string(minute) |> String.pad_leading(2, "0")} #{meridiem}"
    end
  end

  defp todo_primer_slack_card(user_id, structured_data, linked_todo) do
    draft = read_map(linked_todo, "action_draft")
    metadata = read_map(linked_todo, "metadata")

    with raw_body when is_binary(raw_body) <- primer_raw_draft_body(structured_data, linked_todo) do
      %{
        "provider" => "slack",
        "title" => "Slack message ready",
        "status" => "Review before sending",
        "from" =>
          public_display_value(draft, ["from", "sender"]) ||
            public_display_value(metadata, ["from", "sender"]) ||
            slack_sender_display(user_id, draft, metadata),
        "recipient" =>
          public_display_value(draft, ["channel_name", "conversation_name"]) ||
            public_display_value(metadata, ["channel_name", "conversation_name"]) ||
            slack_channel_mention_from_text(raw_body) ||
            public_display_value(draft, ["recipient", "to"]) ||
            public_display_value(metadata, ["person"]) ||
            slack_recipient_from_instruction(raw_body) ||
            slack_channel_display(linked_todo),
        "workspace" =>
          public_display_value(draft, ["workspace_name", "team_name"]) ||
            public_display_value(metadata, ["workspace_name", "team_name"]) ||
            single_connected_slack_team_name(user_id),
        "body" => slack_card_body(raw_body, linked_todo)
      }
      |> compact_public_map()
    end
  end

  defp todo_primer_imessage_card(user_id, structured_data, linked_todo) do
    metadata = read_map(linked_todo, "metadata")

    with body when is_binary(body) <- primer_draft_body(structured_data, linked_todo),
         %{handle: recipient, display_name: display_name, message: message} <-
           imessage_recipient_context(user_id, linked_todo, metadata) do
      body = imessage_card_body(body, display_name)

      %{
        "provider" => "imessage",
        "title" => "Messages reply ready",
        "status" => "Ready to open",
        "from" => messages_sender_label(linked_todo, message),
        "recipient" => display_name,
        "body" => body,
        "open_label" => "Open Messages",
        "open_url" => messages_url(recipient, body)
      }
      |> compact_public_map()
    end
  end

  defp todo_primer_whatsapp_card(user_id, structured_data, linked_todo) do
    draft = read_map(linked_todo, "action_draft")
    metadata = read_map(linked_todo, "metadata")

    with raw_body when is_binary(raw_body) <- primer_raw_draft_body(structured_data, linked_todo),
         %{display_name: display_name, phone: phone, body: body} <-
           whatsapp_recipient_context(user_id, linked_todo, draft, metadata, raw_body) do
      %{
        "provider" => "whatsapp",
        "title" => "WhatsApp message ready",
        "status" => whatsapp_status(phone),
        "from" => "You",
        "recipient" => whatsapp_recipient_display(display_name, phone),
        "body" => body,
        "open_label" => "Open WhatsApp",
        "open_url" => whatsapp_url(phone, body)
      }
      |> compact_public_map()
    end
  end

  defp whatsapp_recipient_context(user_id, linked_todo, draft, metadata, raw_body) do
    body = whatsapp_card_body(raw_body, linked_todo)
    name_candidates = whatsapp_recipient_name_candidates(linked_todo, draft, metadata, raw_body)
    display_name = Enum.find_value(name_candidates, &read_public_text/1) || "WhatsApp"
    phone = whatsapp_phone(user_id, draft, metadata, raw_body, name_candidates)

    with body when is_binary(body) <- read_public_text(body) do
      %{display_name: display_name, phone: phone, body: body}
    end
  end

  defp whatsapp_recipient_name_candidates(linked_todo, draft, metadata, body) do
    metadata_names =
      metadata
      |> read_metadata_people()
      |> Enum.flat_map(fn person ->
        [
          read_string(person, "display_name"),
          read_string(person, "name"),
          [read_string(person, "first_name"), read_string(person, "last_name")]
          |> Enum.reject(&blank_public_value?/1)
          |> Enum.join(" ")
        ]
      end)

    direct_names = [
      read_string(draft, "recipient_name"),
      read_string(draft, "recipient"),
      read_string(draft, "to"),
      read_string(metadata, "person"),
      read_string(metadata, "recipient_name")
    ]

    text_names =
      [
        read_string(linked_todo, "title"),
        read_string(linked_todo, "summary"),
        read_string(linked_todo, "next_action"),
        read_string(draft, "text"),
        body
      ]
      |> Enum.flat_map(&recipient_names_from_text/1)

    (metadata_names ++ direct_names ++ text_names)
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&clean_recipient_name_candidate/1)
    |> Enum.reject(&blank_public_value?/1)
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp whatsapp_phone(user_id, draft, metadata, body, name_candidates) do
    direct =
      [
        read_string(draft, "phone"),
        read_string(draft, "phone_number"),
        read_string(draft, "whatsapp_number"),
        read_string(draft, "whatsapp"),
        read_string(draft, "recipient_phone"),
        read_string(draft, "to"),
        read_string(draft, "recipient"),
        read_string(metadata, "phone"),
        read_string(metadata, "phone_number"),
        read_string(metadata, "whatsapp_number"),
        read_string(metadata, "whatsapp")
      ]
      |> Enum.concat(metadata_phone_values(metadata))
      |> Enum.concat(phone_values_from_text(body))
      |> Enum.find_value(&valid_whatsapp_phone/1)

    direct || crm_phone_for_names(user_id, name_candidates)
  end

  defp metadata_phone_values(metadata) when is_map(metadata) do
    metadata
    |> read_metadata_people()
    |> Enum.flat_map(fn person ->
      contact_details = read_map(person, "contact_details")

      [
        read_string(person, "phone"),
        read_string(person, "phone_number"),
        Map.get(contact_details, "phones"),
        Map.get(contact_details, "phone"),
        Map.get(contact_details, "whatsapp"),
        Map.get(contact_details, "whatsapp_number")
      ]
      |> List.flatten()
    end)
  end

  defp metadata_phone_values(_metadata), do: []

  defp phone_values_from_text(body) when is_binary(body) do
    Regex.scan(~r/(?:\+?\d[\d\s().-]{6,}\d)/, body)
    |> Enum.map(fn
      [value] -> value
      _other -> nil
    end)
  end

  defp phone_values_from_text(_body), do: []

  defp crm_phone_for_names(user_id, name_candidates) when is_binary(user_id) do
    Enum.find_value(name_candidates, fn query ->
      user_id
      |> Crm.search_people(query, limit: 5)
      |> Enum.find_value(&crm_person_phone/1)
    end)
  rescue
    _ -> nil
  end

  defp crm_phone_for_names(_user_id, _name_candidates), do: nil

  defp crm_person_phone(%{contact_details: contact_details}) when is_map(contact_details) do
    [
      Map.get(contact_details, "phones"),
      Map.get(contact_details, "phone"),
      Map.get(contact_details, "whatsapp"),
      Map.get(contact_details, "whatsapp_number")
    ]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.find_value(&valid_whatsapp_phone/1)
  end

  defp crm_person_phone(_person), do: nil

  defp valid_whatsapp_phone(value) when is_binary(value) do
    value = String.trim(value)
    digits = String.replace(value, ~r/[^0-9]/, "")

    cond do
      String.length(digits) < 7 -> nil
      String.starts_with?(value, "+") -> "+#{digits}"
      true -> digits
    end
  end

  defp valid_whatsapp_phone(_value), do: nil

  defp whatsapp_card_body(raw_body, linked_todo) when is_binary(raw_body) do
    quoted_message(raw_body) ||
      synthesized_whatsapp_message(raw_body, linked_todo) ||
      raw_body
  end

  defp whatsapp_card_body(body, _linked_todo), do: body

  defp synthesized_whatsapp_message(body, _linked_todo) when is_binary(body) do
    case Regex.run(
           ~r/\bmessage\s+(.+?)\s+to\s+confirm\s+(.+?)\s+and\s+ask\s+for\s+(?:his|her|their)\s+whatsapp(?:\s+usa)?\s+number\b/i,
           body
         ) do
      [_all, recipient, request] ->
        recipient = clean_recipient_name_candidate(recipient)
        request = request |> String.trim(" .,:;!?\"'") |> read_public_text()

        if recipient && request do
          "Hey #{whatsapp_first_name(recipient)}, #{whatsapp_confirmation_question(request)} " <>
            "What's the best WhatsApp number for you?"
        end

      _other ->
        nil
    end
  end

  defp synthesized_whatsapp_message(_body, _linked_todo), do: nil

  defp whatsapp_confirmation_question(request) when is_binary(request) do
    day =
      case Regex.run(~r/\b(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\b/i, request) do
        [_all, value] -> String.capitalize(String.downcase(value))
        _other -> nil
      end

    if day && String.match?(request, ~r/\bplans?\b/i) do
      "are we still on for #{day}?"
    else
      "can you confirm #{request}?"
    end
  end

  defp whatsapp_first_name(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> read_public_text()
    |> Kernel.||("there")
  end

  defp whatsapp_first_name(_name), do: "there"

  defp whatsapp_status(phone) when is_binary(phone), do: "Ready to open"
  defp whatsapp_status(_phone), do: "Choose recipient in WhatsApp"

  defp whatsapp_recipient_display(display_name, phone) do
    first_present_public([
      if(display_name != "WhatsApp", do: display_name),
      phone,
      "Choose in WhatsApp"
    ])
  end

  defp whatsapp_url(phone, body) when is_binary(body) do
    encoded = URI.encode_www_form(body)

    case whatsapp_phone_url_value(phone) do
      phone when is_binary(phone) -> "whatsapp://send?phone=#{phone}&text=#{encoded}"
      _none -> "whatsapp://send?text=#{encoded}"
    end
  end

  defp whatsapp_phone_url_value(phone) when is_binary(phone) do
    phone
    |> String.replace(~r/[^0-9]/, "")
    |> read_public_text()
  end

  defp whatsapp_phone_url_value(_phone), do: nil

  defp imessage_recipient_context(user_id, linked_todo, metadata) do
    source_item_id = read_string(linked_todo, "source_item_id")
    message = if is_binary(source_item_id), do: LocalMessages.get_by_guid(user_id, source_item_id)

    handle =
      [
        if(message, do: read_string(%{"value" => message.sender_handle}, "value")),
        imessage_handle_from_source_item_id(source_item_id),
        imessage_handle_from_metadata(metadata)
      ]
      |> Enum.find_value(&valid_message_handle/1)

    if is_binary(handle) do
      %{
        handle: handle,
        display_name: imessage_display_name(user_id, handle, message, metadata),
        message: message
      }
    end
  end

  defp imessage_handle_from_source_item_id(value) when is_binary(value) do
    value
    |> String.split([";-;", "|", ";"], trim: true)
    |> Enum.reverse()
    |> Enum.find_value(&valid_message_handle/1)
  end

  defp imessage_handle_from_source_item_id(_value), do: nil

  defp imessage_handle_from_metadata(metadata) when is_map(metadata) do
    metadata
    |> read_metadata_people()
    |> Enum.find_value(fn person ->
      contact_details = read_map(person, "contact_details")

      [
        read_string(person, "phone"),
        read_string(person, "phone_number"),
        Map.get(contact_details, "phones"),
        Map.get(contact_details, "phone")
      ]
      |> List.flatten()
      |> Enum.find_value(&valid_message_handle/1)
    end)
  end

  defp imessage_handle_from_metadata(_metadata), do: nil

  defp valid_message_handle(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      valid_email_destination(value) ->
        valid_email_destination(value)

      Regex.match?(~r/^\+?[0-9][0-9\s().-]{6,}$/, value) ->
        digits = String.replace(value, ~r/[^0-9]/, "")
        prefix = if String.starts_with?(value, "+"), do: "+", else: ""
        prefix <> digits

      true ->
        nil
    end
  end

  defp valid_message_handle(_value), do: nil

  defp imessage_display_name(user_id, handle, message, metadata) do
    contact_kind = if valid_email_destination(handle), do: :email, else: :phone

    case Crm.find_person_by_contact(user_id, handle, contact_kind: contact_kind) do
      %{display_name: display_name} when is_binary(display_name) and display_name != "" ->
        display_name

      _ ->
        [
          if(message, do: read_string(%{"value" => message.chat_display_name}, "value")),
          metadata_person_name(metadata),
          handle
        ]
        |> Enum.find_value(&read_public_text/1)
    end
  rescue
    _ -> metadata_person_name(metadata) || handle
  end

  defp metadata_person_name(metadata) do
    metadata
    |> read_metadata_people()
    |> Enum.find_value(fn person ->
      [
        read_string(person, "display_name"),
        read_string(person, "name"),
        [read_string(person, "first_name"), read_string(person, "last_name")]
        |> Enum.reject(&blank_public_value?/1)
        |> Enum.join(" ")
      ]
      |> Enum.find_value(&read_public_text/1)
    end)
  end

  defp imessage_card_body(body, display_name) when is_binary(body) do
    recipient_name = display_name |> read_public_text() |> imessage_first_name()

    case Regex.run(~r/^You should (?:text|message) .+? back to confirm (.+)$/i, body) ||
           Regex.run(~r/^You should (?:text|message) .+? to confirm (.+)$/i, body) do
      [_all, request] ->
        request = request |> String.trim() |> String.trim_trailing(".")
        "Hey #{recipient_name}, can you confirm #{request}?"

      _other ->
        body
    end
  end

  defp imessage_card_body(body, _display_name), do: body

  defp imessage_first_name(nil), do: "there"

  defp imessage_first_name(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> read_public_text()
    |> Kernel.||("there")
  end

  defp primer_action_source(linked_todo, structured_data) do
    draft = read_map(linked_todo, "action_draft")

    [
      read_string(linked_todo, "source"),
      read_string(draft, "channel"),
      read_string(draft, "provider"),
      read_string(draft, "source"),
      read_string(draft, "kind"),
      primer_raw_draft_body(structured_data, linked_todo),
      read_string(linked_todo, "next_action"),
      read_string(linked_todo, "summary"),
      read_string(linked_todo, "title")
    ]
    |> Enum.find_value(&normalize_action_source/1)
  end

  defp normalize_action_source(value) when is_binary(value) do
    value = value |> String.downcase() |> String.trim()

    cond do
      value in ["gmail", "email", "gmail_draft", "gmail_send", "gmail_reply", "gmail_triage"] ->
        "gmail"

      value in ["slack", "slack_draft", "slack_post", "slack_reply"] ->
        "slack"

      value in ["imessage", "message", "messages", "sms"] ->
        "imessage"

      value in ["whatsapp", "whatsapp_message", "whatsapp_reply"] ->
        "whatsapp"

      String.contains?(value, "gmail") ->
        "gmail"

      String.contains?(value, "slack") ->
        "slack"

      String.contains?(value, "imessage") ->
        "imessage"

      String.contains?(value, "whatsapp") ->
        "whatsapp"

      true ->
        nil
    end
  end

  defp normalize_action_source(_value), do: nil

  defp primer_draft_body(structured_data, linked_todo) do
    case primer_raw_draft_body(structured_data, linked_todo) do
      body when is_binary(body) -> quoted_message(body) || body
      _other -> nil
    end
  end

  defp primer_raw_draft_body(structured_data, linked_todo) do
    [
      get_in(structured_data, ["drafted_next_step", "text"]),
      get_in(linked_todo, ["action_draft", "text"]),
      get_in(linked_todo, ["action_draft", "body"]),
      get_in(linked_todo, ["action_draft", "message"])
    ]
    |> Enum.find_value(fn value ->
      read_public_text(value)
    end)
  end

  defp quoted_message(body) when is_binary(body) do
    [
      ~r/[“"](.+)[”"]\s*$/s,
      ~r/:\s*'(.+)'\s*$/s
    ]
    |> Enum.find_value(fn pattern ->
      case Regex.run(pattern, body) do
        [_all, quoted] -> read_public_text(quoted)
        _other -> nil
      end
    end)
  end

  defp quoted_message(_body), do: nil

  defp slack_card_body(body, linked_todo) when is_binary(body) do
    case quoted_message(body) do
      quoted when is_binary(quoted) ->
        if slack_time_placeholder?(quoted) do
          scheduling_slack_message(linked_todo, body) || quoted
        else
          quoted
        end

      _other ->
        scheduling_slack_message(linked_todo, body) || body
    end
  end

  defp slack_card_body(body, _linked_todo), do: body

  defp scheduling_slack_message(linked_todo, body) when is_map(linked_todo) and is_binary(body) do
    cond do
      match =
          Regex.run(
            ~r/\bsend\s+(.+?)\s+a calendar invite\s+for\s+(.+?)(?:\s+and\s+confirm\b|[.?!]|$)/i,
            body
          ) ->
        [_all, recipient, meeting] = match
        scheduling_slack_message_text(recipient, meeting, linked_todo)

      match = Regex.run(~r/\bsend\s+(.+?)\s+a calendar invite\s+and\s+message\b/i, body) ->
        [_all, recipient] = match
        scheduling_slack_message_text(recipient, nil, linked_todo)

      true ->
        nil
    end
  end

  defp scheduling_slack_message(_linked_todo, _body), do: nil

  defp scheduling_slack_message_text(recipient, meeting, linked_todo) do
    recipient = read_public_text(recipient)
    meeting = scheduling_meeting_label(meeting, linked_todo)

    if recipient && meeting do
      "Hey #{slack_first_name(recipient)}, #{slack_invite_sentence(meeting)} " <>
        "We can keep async updates here the rest of the week."
    end
  end

  defp scheduling_meeting_label(meeting, _linked_todo) when is_binary(meeting) do
    read_public_text(meeting)
  end

  defp scheduling_meeting_label(_meeting, linked_todo) when is_map(linked_todo) do
    title = linked_todo |> read_string("title") |> Kernel.||("") |> String.downcase()

    cond do
      String.contains?(title, ["weekly checkin", "weekly check-in"]) -> "the weekly checkin"
      String.contains?(title, ["checkin", "check-in"]) -> "the checkin"
      true -> "the meeting"
    end
  end

  defp slack_invite_sentence(meeting) when is_binary(meeting) do
    if Regex.match?(~r/^(?:the\s+)?(?:weekly\s+)?check-?in$/i, meeting) do
      "I'll send over #{meeting} invite."
    else
      "I'll send a calendar invite for #{meeting}."
    end
  end

  defp slack_time_placeholder?(body) when is_binary(body) do
    Regex.match?(~r/\[(?:day|date|time|day\/time|date\/time)\]/i, body)
  end

  defp slack_time_placeholder?(_body), do: false

  defp slack_first_name(recipient) when is_binary(recipient) do
    recipient
    |> String.replace(~r/\s*\([^)]*\)\s*$/, "")
    |> String.trim(" .:;!?\"'")
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> read_public_text()
    |> Kernel.||("there")
  end

  defp slack_first_name(_recipient), do: "there"

  defp slack_channel_mention_from_text(body) when is_binary(body) do
    case Regex.run(~r/(?:^|\s)(#[A-Za-z0-9][A-Za-z0-9_-]*)\b/, body) do
      [_all, channel] -> read_public_text(channel)
      _other -> nil
    end
  end

  defp slack_channel_mention_from_text(_body), do: nil

  defp slack_recipient_from_instruction(body) when is_binary(body) do
    case Regex.run(~r/\bmessage\s+(.+?)\s+on\s+slack\b/i, body) ||
           Regex.run(~r/\b(?:reply|respond)\s+to\s+(.+?)(?:\s+on\s+slack|\s*:|$)/i, body) do
      [_all, value] -> read_public_text(value)
      _other -> nil
    end
  end

  defp slack_recipient_from_instruction(_body), do: nil

  defp slack_channel_display(linked_todo) do
    with source_item_id when is_binary(source_item_id) <-
           read_string(linked_todo, "source_item_id"),
         channel when is_binary(channel) <-
           source_item_id |> String.split(":", parts: 2) |> List.first() |> read_public_text() do
      if String.contains?(source_item_id, ":"),
        do: "Original Slack thread",
        else: "Original Slack channel"
    else
      _ -> "Slack"
    end
  end

  defp single_connected_slack_team_name(user_id) when is_binary(user_id) do
    names =
      user_id
      |> Maraithon.OAuth.list_user_tokens()
      |> Enum.map(fn token -> read_string(token.metadata || %{}, "team_name") end)
      |> Enum.reject(&blank_public_value?/1)
      |> Enum.uniq()

    case names do
      [name] -> name
      _other -> nil
    end
  rescue
    _ -> nil
  end

  defp single_connected_slack_team_name(_user_id), do: nil

  defp slack_sender_display(user_id, draft, metadata) when is_binary(user_id) do
    team_id =
      [
        read_string(draft, "team_id"),
        read_string(draft, "workspace_id"),
        read_string(metadata, "team_id"),
        read_string(metadata, "workspace_id")
      ]
      |> Enum.find_value(&read_public_text/1)

    slack_user_id = read_string(draft, "slack_user_id") || read_string(metadata, "slack_user_id")
    preference = read_string(draft, "token_preference") || "user"

    cond do
      preference == "bot" ->
        "Runner"

      slack_user_token_available?(user_id, team_id, slack_user_id) ->
        "You"

      true ->
        "Runner"
    end
  rescue
    _ -> nil
  end

  defp slack_sender_display(_user_id, _draft, _metadata), do: nil

  defp slack_user_token_available?(user_id, team_id, slack_user_id) do
    user_id
    |> Maraithon.OAuth.list_user_tokens()
    |> Enum.any?(fn token ->
      provider = token.provider || ""

      cond do
        not blank_public_value?(team_id) and not blank_public_value?(slack_user_id) ->
          provider == "slack:#{team_id}:user:#{slack_user_id}"

        not blank_public_value?(team_id) ->
          String.starts_with?(provider, "slack:#{team_id}:user:")

        true ->
          String.contains?(provider, ":user:")
      end
    end)
  end

  defp messages_sender_label(linked_todo, message) do
    [
      read_string(linked_todo, "source_account_label"),
      message_source_label(message),
      "Messages"
    ]
    |> Enum.find_value(&messages_source_display/1)
  end

  defp message_source_label(%{source: source}), do: source
  defp message_source_label(_message), do: nil

  defp messages_source_display(value) do
    case read_public_text(value) do
      nil ->
        nil

      value ->
        case String.downcase(value) do
          source when source in ["imessage", "message", "messages", "sms"] -> "Messages"
          _ -> value
        end
    end
  end

  defp messages_url(recipient, body) do
    "sms:#{URI.encode_www_form(recipient)}&body=#{URI.encode_www_form(body)}"
  end

  defp slack_conversation_label(payload) do
    public_display_value(payload, ["channel_name", "conversation_name", "recipient", "to"]) ||
      "Slack"
  end

  defp public_display_value(payload, keys) do
    keys
    |> Enum.find_value(fn key ->
      payload
      |> read_string(key)
      |> public_service_display_value()
    end)
  end

  defp first_present_public(values) do
    Enum.find_value(values, &read_public_text/1)
  end

  defp public_service_display_value(value) do
    value
    |> read_public_text()
    |> normalize_provider_display_value()
    |> reject_identifier_like()
  end

  defp email_display_value(value) do
    value
    |> read_public_text()
    |> normalize_provider_display_value()
    |> reject_identifier_like()
  end

  defp normalize_provider_display_value(nil), do: nil

  defp normalize_provider_display_value(value) when is_binary(value) do
    value = String.trim(value)
    downcased = String.downcase(value)

    cond do
      email = prefixed_email_value(value) ->
        email

      downcased in ["imessage", "message", "messages", "sms"] ->
        "Messages"

      downcased == "whatsapp" ->
        "WhatsApp"

      downcased in ["google", "gmail", "email"] ->
        nil

      String.starts_with?(downcased, "slack:") ->
        nil

      String.starts_with?(downcased, "whatsapp:") ->
        nil

      String.starts_with?(downcased, "google:") ->
        nil

      String.starts_with?(downcased, "gmail:") ->
        nil

      String.starts_with?(downcased, "email:") ->
        nil

      true ->
        value
    end
  end

  defp prefixed_email_value(value) when is_binary(value) do
    case Regex.run(~r/^(?:google|gmail|email):(.+)$/i, String.trim(value)) do
      [_all, rest] -> valid_email_destination(rest)
      _other -> nil
    end
  end

  defp prefixed_email_value(_value), do: nil

  defp reject_identifier_like(nil), do: nil

  defp reject_identifier_like(value) when is_binary(value) do
    cond do
      Regex.match?(~r/^(?:slack|whatsapp|google|gmail|email):/i, value) -> nil
      Regex.match?(~r/^[A-Z][A-Z0-9]{6,}$/, value) -> nil
      Regex.match?(~r/^[-_a-z0-9]{18,}$/i, value) -> nil
      true -> value
    end
  end

  defp read_public_text(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" or String.downcase(value) in ["nil", "null", "none"] do
      nil
    else
      value
    end
  end

  defp read_public_text(_value), do: nil

  defp read_map(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_map(_map, _key), do: %{}

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) || Map.get(map, existing_atom_key(key)) do
      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" or String.downcase(value) in ["nil", "null", "none"] do
          nil
        else
          value
        end

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        nil
    end
  end

  defp read_string(_map, _key), do: nil

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(_key), do: nil

  defp compact_public_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank_public_value?(value) end)
    |> Map.new()
  end

  defp blank_public_value?(nil), do: true
  defp blank_public_value?(""), do: true
  defp blank_public_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_public_value?(_value), do: false

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

  defp public_run_error(%Run{error: error}) do
    ApiErrorCopy.mobile_chat_run_error(error)
  end

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
    [
      get_in(conversation.metadata || %{}, ["title"]),
      first_user_turn_title(conversation),
      conversation.summary
    ]
    |> Enum.find_value(&public_thread_title/1)
    |> Kernel.||("New conversation")
  end

  defp public_thread_title(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> strip_title_role_prefix()
    |> reject_placeholder_title()
    |> reject_technical_title()
    |> truncate_title()
  end

  defp public_thread_title(_value), do: nil

  defp strip_title_role_prefix(value) do
    value
    |> String.replace(~r/(^|\s)(?:assistant|maraithon|user|operator|system)\s*:\s*/i, "\\1")
    |> String.trim()
  end

  defp reject_placeholder_title(""), do: nil

  defp reject_placeholder_title(value) do
    if String.downcase(value) == "new conversation", do: nil, else: value
  end

  defp reject_technical_title(nil), do: nil

  defp reject_technical_title(value) do
    cond do
      String.contains?(value, ["{", "}", "=>"]) ->
        nil

      Regex.match?(~r/\b(?:assistant_reply|approval_prompt|tool_call)\b/i, value) ->
        nil

      Regex.match?(
        ~r/\b(?:run_id|client_message_id|structured_data|authorization|token)\b\s*[:=]/i,
        value
      ) ->
        nil

      unsafe_generation_title?(value) ->
        nil

      true ->
        value
    end
  end

  defp unsafe_generation_title?(value) when is_binary(value) do
    Regex.match?(
      ~r/\b(?:generation failed|configured model|model synthesis|did not produce a valid brief|checked source view|valid json|structured json)\b/i,
      value
    )
  end

  defp truncate_title(nil), do: nil

  defp truncate_title(value) do
    if String.length(value) > 90 do
      value
      |> String.slice(0, 89)
      |> String.trim()
      |> Kernel.<>("...")
    else
      value
    end
  end

  defp first_user_turn_title(%Conversation{} = conversation) do
    conversation
    |> sorted_turns()
    |> Enum.find(&(&1.role == "user"))
    |> case do
      %Turn{text: text} when is_binary(text) ->
        ThreadNaming.title_for_message(text)

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
end
