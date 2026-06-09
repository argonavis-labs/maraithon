defmodule Maraithon.AssistantChat.TodoThreadPrimer do
  @moduledoc """
  Seeds mobile todo-detail chat threads with chief-of-staff context.

  The primer is intentionally idempotent. Draft material must already live on
  the todo; when connected target metadata is complete, the primer prepares the
  existing draft as a real mobile approval action.
  """

  import Ecto.Query

  alias Maraithon.ActionCards
  alias Maraithon.CalendarLinks
  alias Maraithon.Crm
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalContacts.LocalContact
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.PreparedAction
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.Timezones
  alias Maraithon.Tools
  alias Maraithon.Todos
  alias Maraithon.Todos.{ActionDrafts, Todo}

  @primer_version 10
  @availability_timezone "America/Toronto"
  @availability_offset_hours -5
  @availability_slot_minutes 30
  @availability_candidate_hours [10, 12, 14, 15]
  @prepared_action_timeout_ms 2_500

  def ensure(%Conversation{} = conversation, %Todo{} = todo) do
    card = ActionCards.for_todo(todo, include_disconnected: true)
    draft = draft_for(todo, card)
    text = primer_text(todo, card, draft)

    case primer_turn(conversation, todo.id) do
      %Turn{} = turn ->
        attrs = primer_turn_attrs(conversation, todo, card, draft, text, turn)
        update_primer_turn(turn, attrs)
        {:ok, conversation}

      nil ->
        attrs = primer_turn_attrs(conversation, todo, card, draft, text, nil)

        case TelegramConversations.append_turn(conversation, attrs) do
          {:ok, {updated_conversation, _turn}} -> {:ok, updated_conversation}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def ensure(_conversation, _todo), do: {:error, :invalid_todo_thread}

  defp primer_turn_attrs(%Conversation{} = conversation, %Todo{} = todo, card, draft, text, turn) do
    prepared_action_id = prepared_action_id_for(conversation, todo, draft, turn)

    %{
      "role" => "assistant",
      "delivery_state" => "delivered",
      "text" => text,
      "turn_kind" => "assistant_reply",
      "origin_type" => "system",
      "origin_id" => primer_origin_id(todo.id),
      "structured_data" =>
        %{
          "message_class" => "todo_chat_primer",
          "todo_chat_primer_version" => @primer_version,
          "linked_todo" => Todos.serialize_for_prompt(todo),
          "todo_action_card" => public_card(card),
          "drafted_next_step" => draft
        }
        |> maybe_put("prepared_action_id", prepared_action_id)
    }
  end

  defp update_primer_turn(%Turn{} = turn, attrs) do
    current_version = get_in(turn.structured_data || %{}, ["todo_chat_primer_version"])
    current_prepared_action_id = get_in(turn.structured_data || %{}, ["prepared_action_id"])
    next_prepared_action_id = get_in(attrs, ["structured_data", "prepared_action_id"])

    if current_version == @primer_version and
         current_prepared_action_id == next_prepared_action_id do
      {:ok, turn}
    else
      turn
      |> Turn.changeset(attrs)
      |> Repo.update()
    end
  end

  defp primer_turn(%Conversation{turns: turns}, todo_id) when is_list(turns) do
    Enum.find(turns, &primer_turn?(&1, todo_id))
  end

  defp primer_turn(%Conversation{id: conversation_id}, todo_id) do
    Turn
    |> where([turn], turn.conversation_id == ^conversation_id)
    |> where(
      [turn],
      turn.origin_id == ^primer_origin_id(todo_id) or
        fragment("?->>'message_class' = ?", turn.structured_data, "todo_chat_primer")
    )
    |> order_by([turn], desc: turn.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp primer_turn?(
         %Turn{origin_id: origin_id, structured_data: structured_data},
         todo_id
       ) do
    origin_id == primer_origin_id(todo_id) or
      get_in(structured_data || %{}, ["message_class"]) == "todo_chat_primer"
  end

  defp primer_origin_id(todo_id), do: "todo-chat-primer:#{todo_id}"

  defp draft_for(%Todo{} = todo, card) do
    existing = ActionCards.draft_preview(card) || ActionDrafts.preview(todo.action_draft || %{})

    if present?(existing) do
      %{
        "kind" => read_string(todo.action_draft || %{}, "kind") || "prepared_next_step",
        "label" => read_string(todo.action_draft || %{}, "label") || "Drafted next step",
        "text" => existing,
        "source" => read_string(todo.action_draft || %{}, "source") || "todo_action_draft",
        "style" => read_string(todo.action_draft || %{}, "style") || "already_available"
      }
      |> compact_map()
    else
      next_step =
        first_present([
          read_string(card, "next_best_action"),
          todo.next_action,
          "Open the source context, confirm the exact ask, and decide whether to reply, delegate, or dismiss it."
        ])

      %{
        "kind" => "next_step",
        "label" => "Next step",
        "text" => "Next step: #{next_step}",
        "source" => "existing_todo_context",
        "style" => "read_only_context"
      }
      |> compact_map()
    end
  end

  defp primer_text(%Todo{} = todo, card, draft) do
    [
      "I’ve got this work item in context.",
      read_line("My read", read_string(card, "decision_prompt") || read_string(card, "headline")),
      read_line("Why now", read_string(card, "why_now")),
      if(action_card_source?(todo, draft), do: nil, else: draft_section(draft)),
      "I can tighten the wording, prepare the connected action for approval, or mark it done once you’ve handled it."
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> then(fn text ->
      if present?(todo.title), do: text, else: "I’ve got this work item in context.\n\n#{text}"
    end)
  end

  defp read_line(_label, nil), do: nil
  defp read_line(label, value), do: "#{label}: #{value}"

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp draft_section(%{"label" => label, "text" => text} = draft) when is_binary(text) do
    case read_string(draft, "subject") do
      nil -> "#{label}:\n#{text}"
      subject -> "#{label}:\nSubject: #{subject}\n\n#{text}"
    end
  end

  defp draft_section(_draft), do: nil

  defp prepared_action_id_for(%Conversation{} = conversation, %Todo{} = todo, draft, turn) do
    reusable_prepared_action_id(conversation, turn, todo, draft) ||
      create_primer_prepared_action(conversation, todo, draft)
  end

  defp reusable_prepared_action_id(
         %Conversation{} = conversation,
         %Turn{} = turn,
         %Todo{} = todo,
         draft
       ) do
    with prepared_action_id when is_binary(prepared_action_id) <-
           get_in(turn.structured_data || %{}, ["prepared_action_id"]),
         %PreparedAction{} = prepared_action <- Repo.get(PreparedAction, prepared_action_id),
         false <- stale_prepared_action?(prepared_action),
         true <-
           prepared_action_matches_current_draft?(prepared_action, conversation, todo, draft) do
      prepared_action.id
    else
      _ -> nil
    end
  end

  defp reusable_prepared_action_id(_conversation, _turn, _todo, _draft), do: nil

  defp stale_prepared_action?(%PreparedAction{status: "awaiting_confirmation"} = prepared_action) do
    TelegramAssistant.prepared_action_expired?(prepared_action)
  end

  defp stale_prepared_action?(%PreparedAction{status: status})
       when status in ["expired", "rejected"],
       do: true

  defp stale_prepared_action?(_prepared_action), do: false

  defp prepared_action_matches_current_draft?(
         %PreparedAction{action_type: "slack_post", payload: payload},
         %Conversation{} = conversation,
         %Todo{} = todo,
         draft
       ) do
    body = prepared_slack_message_body(conversation.user_id, todo, draft)

    present?(body) and
      read_string(payload || %{}, "text") == body and
      present?(read_string(payload || %{}, "team_id")) and
      present?(read_string(payload || %{}, "channel"))
  end

  defp prepared_action_matches_current_draft?(
         %PreparedAction{action_type: "gmail_draft_send", payload: payload},
         %Conversation{} = conversation,
         %Todo{} = todo,
         draft
       ) do
    body =
      case prepared_message_body(todo, draft) do
        body when is_binary(body) ->
          calendar_enriched_message_body(conversation.user_id, todo, %{}, body)

        other ->
          other
      end

    present?(body) and
      read_string(payload || %{}, "body") == body and
      present?(read_string(payload || %{}, "draft_id")) and
      present?(read_string(payload || %{}, "to")) and
      present?(read_string(payload || %{}, "subject"))
  end

  defp prepared_action_matches_current_draft?(_prepared_action, _conversation, _todo, _draft),
    do: false

  defp create_primer_prepared_action(%Conversation{} = conversation, %Todo{} = todo, draft) do
    case prepared_action_attrs_with_timeout(conversation, todo, draft) do
      {:ok, attrs} ->
        with {:ok, run} <- create_primer_run(conversation, todo, attrs),
             {:ok, prepared_action} <-
               attrs
               |> Map.put(:run_id, run.id)
               |> TelegramAssistant.create_prepared_action() do
          prepared_action.id
        else
          _ -> nil
        end

      :skip ->
        nil
    end
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp prepared_action_attrs_with_timeout(%Conversation{} = conversation, %Todo{} = todo, draft) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        result =
          try do
            prepared_action_attrs(conversation, todo, draft)
          rescue
            _ -> :skip
          catch
            _kind, _reason -> :skip
          end

        send(parent, {ref, result})
      end)

    monitor_ref = Process.monitor(pid)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        :skip
    after
      @prepared_action_timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(pid, :kill)
        :skip
    end
  end

  defp create_primer_run(%Conversation{} = conversation, %Todo{} = todo, attrs) do
    now = DateTime.utc_now()

    TelegramAssistant.start_run(%{
      user_id: conversation.user_id,
      chat_id: conversation.chat_id,
      conversation_id: conversation.id,
      surface: "mobile",
      trigger_type: "follow_up",
      status: "completed",
      model_provider: "deterministic",
      model_name: "todo_thread_primer",
      prompt_snapshot: %{},
      result_summary: %{
        surface: "mobile",
        message_class: "todo_chat_primer",
        task_class: "prepared_next_action",
        action_type: attrs.action_type,
        linked_todo_id: todo.id
      },
      started_at: now,
      finished_at: now
    })
  end

  defp prepared_action_attrs(%Conversation{} = conversation, %Todo{} = todo, draft) do
    case action_source(todo, draft) do
      "gmail" -> gmail_prepared_action_attrs(conversation, todo, draft)
      "slack" -> slack_prepared_action_attrs(conversation, todo, draft)
      _source -> :skip
    end
  end

  defp gmail_prepared_action_attrs(%Conversation{} = conversation, %Todo{} = todo, draft) do
    draft_map = todo.action_draft || %{}
    metadata = todo.metadata || %{}
    source_message = gmail_source_message(conversation.user_id, todo, draft_map, metadata)

    with body when is_binary(body) <- prepared_message_body(todo, draft),
         to when is_binary(to) <-
           gmail_recipient(conversation.user_id, todo, draft_map, metadata, source_message),
         subject when is_binary(subject) <-
           gmail_subject(todo, draft_map, metadata, source_message),
         body <- calendar_enriched_message_body(conversation.user_id, todo, source_message, body),
         {:ok, draft_id} <-
           save_gmail_draft(
             conversation.user_id,
             todo,
             draft_map,
             metadata,
             source_message,
             to,
             subject,
             body
           ) do
      account = gmail_account(todo, draft_map, metadata)

      payload =
        %{
          "user_id" => conversation.user_id,
          "todo_id" => todo.id,
          "draft_id" => draft_id,
          "to" => to,
          "recipient" => to,
          "subject" => subject,
          "body" => body,
          "cc" => read_string(draft_map, "cc"),
          "bcc" => read_string(draft_map, "bcc"),
          "thread_id" => gmail_thread_id(todo, draft_map, metadata, source_message),
          "reply_to_message_id" =>
            first_present([
              read_string(draft_map, "reply_to_message_id"),
              read_string(metadata, "reply_to_message_id"),
              read_string(metadata, "message_id"),
              read_string(source_message, "message_id")
            ]),
          "in_reply_to" =>
            first_present([
              read_string(draft_map, "in_reply_to"),
              read_string(metadata, "in_reply_to"),
              read_string(source_message, "internet_message_id")
            ]),
          "references" =>
            first_present([
              read_string(draft_map, "references"),
              read_string(metadata, "references"),
              read_string(source_message, "references"),
              read_string(source_message, "internet_message_id")
            ]),
          "account" => account,
          "from" => account,
          "source_from" => read_string(source_message, "from"),
          "source_to" => read_string(source_message, "to")
        }
        |> compact_map()

      {:ok,
       prepared_action_base(conversation, "gmail_draft_send", "gmail_draft", draft_id, payload,
         preview_text: gmail_preview_text(to, subject)
       )}
    else
      _ -> :skip
    end
  end

  defp save_gmail_draft(
         user_id,
         %Todo{} = todo,
         draft_map,
         metadata,
         source_message,
         to,
         subject,
         body
       ) do
    args =
      %{
        "user_id" => user_id,
        "action" => "create",
        "to" => to,
        "subject" => subject,
        "body" => body,
        "cc" => read_string(draft_map, "cc"),
        "bcc" => read_string(draft_map, "bcc"),
        "thread_id" => gmail_thread_id(todo, draft_map, metadata, source_message),
        "in_reply_to" =>
          first_present([
            read_string(draft_map, "in_reply_to"),
            read_string(metadata, "in_reply_to"),
            read_string(draft_map, "reply_to_message_id"),
            read_string(metadata, "reply_to_message_id"),
            read_string(source_message, "internet_message_id")
          ]),
        "references" =>
          first_present([
            read_string(draft_map, "references"),
            read_string(metadata, "references"),
            read_string(source_message, "references"),
            read_string(source_message, "internet_message_id")
          ]),
        "account" =>
          [
            read_string(draft_map, "account"),
            read_string(draft_map, "google_account_email"),
            read_string(metadata, "google_account_email"),
            read_string(metadata, "account_email")
          ]
          |> first_present()
          |> gmail_account_email_value(),
        "provider" =>
          first_present([
            read_string(draft_map, "provider"),
            read_string(draft_map, "google_provider"),
            read_string(metadata, "google_provider")
          ])
      }
      |> compact_map()

    case Tools.execute("gmail_drafts", args, %{surface: "internal", user_id: user_id}) do
      {:ok, result} ->
        case gmail_draft_id(result) do
          draft_id when is_binary(draft_id) -> {:ok, draft_id}
          _ -> {:error, :missing_draft_id}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp gmail_draft_id(%{draft: %{"id" => draft_id}}) when is_binary(draft_id), do: draft_id
  defp gmail_draft_id(%{"draft" => %{"id" => draft_id}}) when is_binary(draft_id), do: draft_id
  defp gmail_draft_id(%{draft_id: draft_id}) when is_binary(draft_id), do: draft_id
  defp gmail_draft_id(%{"draft_id" => draft_id}) when is_binary(draft_id), do: draft_id
  defp gmail_draft_id(_result), do: nil

  defp gmail_source_message(user_id, %Todo{} = todo, draft_map, metadata)
       when is_binary(user_id) do
    with message_id when is_binary(message_id) <-
           first_present([
             read_string(draft_map, "message_id"),
             read_string(draft_map, "source_message_id"),
             read_string(metadata, "message_id"),
             read_string(metadata, "source_message_id"),
             todo.source_item_id
           ]) do
      args =
        %{
          "user_id" => user_id,
          "message_id" => message_id,
          "google_account_email" =>
            [
              read_string(draft_map, "google_account_email"),
              read_string(metadata, "google_account_email"),
              read_string(metadata, "account_email"),
              todo.source_account_label
            ]
            |> first_present()
            |> gmail_account_email_value(),
          "account" =>
            [
              read_string(draft_map, "account"),
              read_string(metadata, "account"),
              todo.source_account_label
            ]
            |> first_present()
            |> gmail_account_email_value(),
          "provider" =>
            first_present([
              read_string(draft_map, "provider"),
              read_string(draft_map, "google_provider"),
              read_string(metadata, "google_provider")
            ])
        }
        |> compact_map()

      case Tools.execute("gmail_get_message", args, %{surface: "internal", user_id: user_id}) do
        {:ok, result} -> gmail_source_message_from_result(result)
        {:error, _reason} -> %{}
      end
    else
      _ -> %{}
    end
  end

  defp gmail_source_message(_user_id, _todo, _draft_map, _metadata), do: %{}

  defp gmail_source_message_from_result(%{message: %{} = message}), do: message
  defp gmail_source_message_from_result(%{"message" => %{} = message}), do: message
  defp gmail_source_message_from_result(_result), do: %{}

  defp slack_prepared_action_attrs(%Conversation{} = conversation, %Todo{} = todo, draft) do
    draft_map = todo.action_draft || %{}
    metadata = todo.metadata || %{}
    source_body = draft_body(todo, draft)

    with body when is_binary(body) <-
           prepared_slack_message_body(conversation.user_id, todo, draft),
         team_id when is_binary(team_id) <-
           slack_team_id(conversation.user_id, draft_map, metadata),
         channel when is_binary(channel) <- slack_channel(todo, draft_map, metadata) do
      payload =
        %{
          "user_id" => conversation.user_id,
          "todo_id" => todo.id,
          "team_id" => team_id,
          "channel" => channel,
          "text" => body,
          "thread_ts" => slack_thread_ts(todo, draft_map, metadata),
          "channel_name" => slack_channel_name(draft_map, metadata, source_body || body),
          "workspace_name" => slack_workspace_name(conversation.user_id, draft_map, metadata),
          "team_name" => slack_workspace_name(conversation.user_id, draft_map, metadata),
          "from" => slack_sender_label(conversation.user_id, draft_map, metadata),
          "recipient" => slack_recipient(draft_map, metadata, source_body || body),
          "token_preference" => read_string(draft_map, "token_preference") || "user",
          "slack_user_id" =>
            first_present([
              read_string(draft_map, "slack_user_id"),
              read_string(metadata, "slack_user_id")
            ])
        }
        |> compact_map()

      {:ok,
       prepared_action_base(conversation, "slack_post", "slack_channel", channel, payload,
         preview_text: slack_preview_text(payload)
       )}
    else
      _ -> :skip
    end
  end

  defp prepared_action_base(
         %Conversation{} = conversation,
         action_type,
         target_type,
         target_id,
         payload,
         opts
       ) do
    %{
      user_id: conversation.user_id,
      chat_id: conversation.chat_id,
      conversation_id: conversation.id,
      surface: "mobile",
      action_type: action_type,
      target_type: target_type,
      target_id: target_id,
      payload: payload,
      preview_text: Keyword.fetch!(opts, :preview_text),
      status: "awaiting_confirmation",
      expires_at:
        DateTime.add(
          DateTime.utc_now(),
          TelegramAssistant.confirmation_window_seconds(),
          :second
        )
    }
  end

  defp action_card_source?(%Todo{} = todo, draft),
    do: action_source(todo, draft) in ~w(gmail slack imessage whatsapp)

  defp action_source(%Todo{} = todo, draft) do
    draft_map = todo.action_draft || %{}

    [
      todo.source,
      read_string(draft_map, "channel"),
      read_string(draft_map, "provider"),
      read_string(draft_map, "source"),
      read_string(draft_map, "kind"),
      read_string(draft, "kind"),
      read_string(draft, "text"),
      ActionDrafts.preview(todo.action_draft || %{}),
      todo.next_action,
      todo.title
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

  defp draft_body(%Todo{} = todo, draft) do
    [
      read_string(draft, "text"),
      ActionDrafts.preview(todo.action_draft || %{})
    ]
    |> Enum.find_value(&read_non_empty/1)
  end

  defp prepared_message_body(%Todo{} = todo, draft) do
    case draft_body(todo, draft) do
      body when is_binary(body) ->
        quoted_message(body) || if(instruction_text?(body), do: nil, else: body)

      _other ->
        nil
    end
  end

  defp prepared_slack_message_body(user_id, %Todo{} = todo, draft) do
    draft_map = todo.action_draft || %{}
    metadata = todo.metadata || %{}

    case draft_body(todo, draft) do
      body when is_binary(body) ->
        body =
          usable_quoted_slack_message(body) ||
            synthesized_slack_message(todo, body, draft_map, metadata) ||
            if(instruction_text?(body), do: nil, else: body)

        if is_binary(body) do
          calendar_enriched_message_body(user_id, todo, %{}, body)
        end

      _other ->
        nil
    end
  end

  defp synthesized_slack_message(%Todo{} = todo, body, draft_map, metadata)
       when is_binary(body) do
    scheduling_slack_message(todo, body) ||
      synthesized_slack_share_message(todo, body, draft_map, metadata)
  end

  defp synthesized_slack_message(_todo, _body, _draft_map, _metadata), do: nil

  defp usable_quoted_slack_message(body) when is_binary(body) do
    case quoted_message(body) do
      quoted when is_binary(quoted) ->
        if slack_time_placeholder?(quoted), do: nil, else: quoted

      _other ->
        nil
    end
  end

  defp usable_quoted_slack_message(_body), do: nil

  defp synthesized_slack_share_message(%Todo{} = todo, body, draft_map, metadata)
       when is_binary(body) do
    recipient =
      slack_recipient(draft_map, metadata, body) ||
        slack_recipient_from_instruction(todo.title)

    subject =
      slack_share_subject(body) ||
        slack_share_subject(todo.title)

    with recipient when is_binary(recipient) <- recipient,
         subject when is_binary(subject) <- subject do
      "Hey #{slack_first_name(recipient)}, I found #{subject_with_article(subject)}. " <>
        "Here is the link: [insert link]. Let me know if you need anything else."
    else
      _ -> nil
    end
  end

  defp synthesized_slack_share_message(_todo, _body, _draft_map, _metadata), do: nil

  defp scheduling_slack_message(%Todo{} = todo, body) when is_binary(body) do
    cond do
      match =
          Regex.run(
            ~r/\bsend\s+(.+?)\s+a calendar invite\s+for\s+(.+?)(?:\s+and\s+confirm\b|[.?!]|$)/i,
            body
          ) ->
        [_all, recipient, meeting] = match
        scheduling_slack_message_text(recipient, meeting, todo)

      match = Regex.run(~r/\bsend\s+(.+?)\s+a calendar invite\s+and\s+message\b/i, body) ->
        [_all, recipient] = match
        scheduling_slack_message_text(recipient, nil, todo)

      true ->
        nil
    end
  end

  defp scheduling_slack_message(_todo, _body), do: nil

  defp scheduling_slack_message_text(recipient, meeting, %Todo{} = todo) do
    recipient = clean_slack_recipient_label(recipient)
    meeting = scheduling_meeting_label(meeting, todo)

    if present?(recipient) and present?(meeting) do
      "Hey #{slack_first_name(recipient)}, #{slack_invite_sentence(meeting)} " <>
        "We can keep async updates here the rest of the week."
    end
  end

  defp scheduling_meeting_label(meeting, _todo) when is_binary(meeting) do
    clean_slack_subject(meeting)
  end

  defp scheduling_meeting_label(_meeting, %Todo{} = todo) do
    title = String.downcase(todo.title || "")

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

  defp slack_share_subject(body) when is_binary(body) do
    [
      ~r/\b(?:locate|find|get)\s+(?:the\s+)?(.+?)\s+(?:in|from)\s+.+?\s+and\s+(?:share|send)\b/i,
      ~r/\b(?:locate|find|get)\s+(?:the\s+)?(.+?)\s+and\s+(?:share|send)\b/i,
      ~r/^share\s+(?:the\s+)?(.+?)\s+(?:with|to)\b/i
    ]
    |> Enum.find_value(fn pattern ->
      case Regex.run(pattern, body) do
        [_all, value] -> clean_slack_subject(value)
        _other -> nil
      end
    end)
  end

  defp slack_share_subject(_body), do: nil

  defp clean_slack_subject(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim(" .:;!?\"'")
    |> read_non_empty()
  end

  defp clean_slack_subject(_value), do: nil

  defp subject_with_article(subject) when is_binary(subject) do
    if String.match?(subject, ~r/^(?:the|a|an)\s+/i) do
      subject
    else
      "the #{subject}"
    end
  end

  defp slack_first_name(recipient) when is_binary(recipient) do
    recipient
    |> clean_slack_recipient_label()
    |> case do
      nil ->
        "there"

      name ->
        name
        |> String.split(~r/\s+/, parts: 2)
        |> List.first()
    end
  end

  defp slack_first_name(_recipient), do: "there"

  defp quoted_message(body) when is_binary(body) do
    [
      ~r/[“"](.+)[”"]\s*$/s,
      ~r/:\s*'(.+)'\s*$/s
    ]
    |> Enum.find_value(fn pattern ->
      case Regex.run(pattern, body) do
        [_all, quoted] -> read_non_empty(quoted)
        _other -> nil
      end
    end)
  end

  defp quoted_message(_body), do: nil

  defp instruction_text?(body) when is_binary(body) do
    body
    |> String.downcase()
    |> String.trim()
    |> then(fn body ->
      String.starts_with?(body, [
        "you should ",
        "next step:",
        "open ",
        "locate ",
        "review ",
        "check ",
        "test "
      ])
    end)
  end

  defp instruction_text?(_body), do: false

  defp calendar_enriched_message_body(user_id, %Todo{} = todo, source_message, body)
       when is_binary(user_id) and is_binary(body) do
    if scheduling_reply?(todo, body) do
      calendar_link = calendly_link_for(user_id, todo, source_message, body)

      if calendly_link?(calendar_link) do
        calendly_scheduling_body(todo, source_message, body, calendar_link)
      else
        slot_minutes = calendar_link_duration_minutes(calendar_link)

        case suggested_calendar_slot_labels(user_id, 2, slot_minutes) do
          [_slot | _] = labels ->
            cond do
              has_availability_placeholders?(body) ->
                body
                |> replace_availability_placeholders(labels)
                |> maybe_add_availability_sentence(labels)

              simple_availability_reply?(body) ->
                generated_availability_body(todo, source_message, body, labels)

              true ->
                maybe_add_availability_sentence(body, labels)
            end

          [] ->
            body
        end
      end
    else
      body
    end
  rescue
    _ -> body
  end

  defp calendar_enriched_message_body(_user_id, _todo, _source_message, body), do: body

  defp scheduling_reply?(%Todo{} = todo, body) do
    text =
      [
        todo.title,
        todo.summary,
        todo.next_action,
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

    scheduling_followup? =
      String.contains?(text, ["[day]", "[time]", "time slots", "few time", "available"]) or
        calendar_time_like?(text) or setup_meeting_request?(text)

    scheduling_intent? and scheduling_followup?
  end

  defp setup_meeting_request?(text) when is_binary(text) do
    Regex.match?(
      ~r/\b(?:set\s*up|setup|schedule|book|arrange|coordinate|pick|choose|find)\b.{0,80}\b(?:meeting|call|chat|time|slot|availability|calendar|calendly|meet)\b/i,
      text
    ) or
      Regex.match?(
        ~r/\b(?:meeting|call|chat|time|slot|availability|calendar|calendly|meet)\b.{0,80}\b(?:set\s*up|setup|schedule|book|arrange|coordinate|pick|choose|find)\b/i,
        text
      )
  end

  defp setup_meeting_request?(_text), do: false

  defp calendar_time_like?(text) when is_binary(text) do
    Regex.match?(
      ~r/\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|\d{1,2}\/\d{1,2}|\d{1,2}(?::\d{2})?\s*(?:am|pm))\b/i,
      text
    )
  end

  defp calendar_time_like?(_text), do: false

  defp has_availability_placeholders?(body) when is_binary(body) do
    String.contains?(String.downcase(body), ["[day]", "[time]"])
  end

  defp has_availability_placeholders?(_body), do: false

  defp simple_availability_reply?(body) when is_binary(body) do
    text = body |> String.trim() |> String.downcase()

    String.length(text) <= 220 and
      (String.contains?(text, ["works best", "i can do", "available", "availability"]) or
         calendar_time_like?(text))
  end

  defp simple_availability_reply?(_body), do: false

  defp generated_availability_body(%Todo{} = todo, source_message, body, labels) do
    greeting =
      case gmail_recipient_first_name(todo, source_message, body) do
        nil -> nil
        first_name -> "Hi #{first_name},"
      end

    availability = "#{availability_sentence(labels)} works best for me."

    closing =
      case meeting_person_name(todo, body) do
        nil -> "Looking forward to speaking."
        name -> "Looking forward to speaking with #{name}."
      end

    [greeting, "#{availability} #{closing}"]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp calendly_scheduling_body(%Todo{} = todo, source_message, body, link) do
    cond do
      String.contains?(String.downcase(body), "calendly.com") ->
        body

      simple_availability_reply?(body) or has_availability_placeholders?(body) or
        calendar_time_like?(body) or instruction_text?(body) ->
        generated_calendly_body(todo, source_message, body, link)

      true ->
        maybe_add_primary_calendly_link(body, link)
    end
  end

  defp generated_calendly_body(%Todo{} = todo, source_message, body, link) do
    greeting =
      case gmail_recipient_first_name(todo, source_message, body) do
        nil -> nil
        first_name -> "Hi #{first_name},"
      end

    scheduling = calendly_link_sentence(link)

    closing =
      case meeting_person_name(todo, body) do
        nil -> "Looking forward to speaking."
        name -> "Looking forward to speaking with #{name}."
      end

    [greeting, scheduling, closing]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp gmail_recipient_first_name(%Todo{} = todo, source_message, body) do
    recipient_name_candidates(
      todo,
      todo.action_draft || %{},
      todo.metadata || %{},
      source_message,
      body
    )
    |> Enum.find_value(fn name ->
      name
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> clean_name_token()
    end)
  end

  defp meeting_person_name(%Todo{} = todo, body) do
    [
      todo.title,
      todo.summary,
      todo.next_action,
      body,
      read_string(todo.metadata || %{}, "summary")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.find_value(fn text ->
      case Regex.run(~r/\bspeaking with\s+([A-Z][A-Za-z'’-]+(?:\s+[A-Z][A-Za-z'’-]+)?)/, text) do
        [_all, name] -> clean_person_name(name)
        _other -> nil
      end
    end)
  end

  defp clean_name_token(value) when is_binary(value) do
    value
    |> String.trim(" .,:;!?\"'()[]")
    |> read_non_empty()
  end

  defp clean_name_token(_value), do: nil

  defp clean_person_name(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim(" .,:;!?\"'()[]")
    |> read_non_empty()
  end

  defp clean_person_name(_value), do: nil

  defp replace_availability_placeholders(body, labels) do
    {updated, replaced?} =
      Enum.reduce(labels, {body, false}, fn label, {acc, replaced?} ->
        next =
          Regex.replace(
            ~r/\[Day\]\s+at\s+\[Time\](?:\s*(?:EDT|EST|ET))?/i,
            acc,
            label,
            global: false
          )

        if next == acc do
          {acc, replaced?}
        else
          {next, true}
        end
      end)

    if replaced? do
      updated
    else
      labels
      |> List.first()
      |> case do
        nil ->
          body

        label ->
          body
          |> Regex.replace(~r/\[Day\]\s*,?\s*\[Time\](?:\s*(?:EDT|EST|ET))?/i, label,
            global: false
          )
          |> String.replace("[Day]", calendar_date_part(label), global: false)
          |> String.replace("[Time]", calendar_time_part(label), global: false)
      end
    end
  end

  defp maybe_add_availability_sentence(updated_body, labels) do
    if String.contains?(updated_body, ["[Day]", "[day]", "[Time]", "[time]"]) do
      sentence = "I can do #{availability_sentence(labels)}."

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

  defp calendly_link_for(user_id, %Todo{} = todo, source_message, body) do
    CalendarLinks.best_link_for(user_id, todo, body, source_message: source_message || %{})
  rescue
    _ -> nil
  end

  defp calendly_link_for(_user_id, _todo, _source_message, _body), do: nil

  defp calendar_link_duration_minutes(%{duration_minutes: minutes})
       when is_integer(minutes) and minutes >= 5,
       do: min(minutes, 180)

  defp calendar_link_duration_minutes(_link), do: @availability_slot_minutes

  defp calendly_link?(%{url: url}) when is_binary(url), do: String.trim(url) != ""
  defp calendly_link?(_link), do: false

  defp maybe_add_primary_calendly_link(body, %{url: url} = link)
       when is_binary(body) and is_binary(url) do
    if String.contains?(String.downcase(body), "calendly.com") do
      body
    else
      [String.trim(body), calendly_link_sentence(link)]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")
    end
  end

  defp maybe_add_primary_calendly_link(body, _link), do: body

  defp calendly_link_sentence(link) do
    "Please use my #{CalendarLinks.display_label(link)} link to grab a time that works for you: #{link.url}"
  end

  defp suggested_calendar_slot_labels(user_id, limit, slot_minutes) do
    user_id
    |> suggested_calendar_slots(limit, slot_minutes)
    |> Enum.map(&calendar_slot_label/1)
  end

  defp suggested_calendar_slots(user_id, limit, slot_minutes) when is_binary(user_id) do
    slot_minutes = normalize_slot_minutes(slot_minutes)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    local_today = local_date(now)
    window_start = local_boundary_to_utc(Date.add(local_today, 1), ~T[00:00:00])
    window_end = local_boundary_to_utc(Date.add(local_today, 10), ~T[23:59:59])

    events =
      user_id
      |> LocalCalendar.events_around(since: window_start, until: window_end, limit: 300)
      |> Enum.reject(&(&1.is_all_day == true))

    local_today
    |> candidate_slot_starts()
    |> Enum.reject(&slot_busy?(&1, events, slot_minutes))
    |> Enum.take(limit)
    |> Enum.map(fn start_at ->
      %{start_at: start_at, end_at: DateTime.add(start_at, slot_minutes, :minute)}
    end)
  rescue
    _ -> []
  end

  defp suggested_calendar_slots(_user_id, _limit, _slot_minutes), do: []

  defp normalize_slot_minutes(minutes) when is_integer(minutes), do: min(max(minutes, 5), 180)
  defp normalize_slot_minutes(_minutes), do: @availability_slot_minutes

  defp candidate_slot_starts(local_today) do
    1..10
    |> Enum.map(&Date.add(local_today, &1))
    |> Enum.reject(&weekend?/1)
    |> Enum.flat_map(fn date ->
      Enum.map(@availability_candidate_hours, fn hour ->
        local_boundary_to_utc(date, Time.new!(hour, 0, 0))
      end)
    end)
  end

  defp slot_busy?(start_at, events, slot_minutes) do
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

  defp calendar_slot_label(%{start_at: %DateTime{} = start_at}) do
    offset = Timezones.offset_at(@availability_timezone, start_at, @availability_offset_hours)
    local = DateTime.add(start_at, offset, :hour)

    "#{weekday_name(local)} #{month_name(local)} #{local.day} at #{clock_label(local)} #{timezone_label(start_at)}"
  end

  defp availability_sentence([one]), do: one
  defp availability_sentence([one, two]), do: "#{one} or #{two}"

  defp availability_sentence([one, two | rest]) do
    ([one, two] ++ rest)
    |> Enum.with_index()
    |> Enum.map(fn
      {label, 0} -> label
      {label, index} when index == length(rest) + 1 -> "or #{label}"
      {label, _index} -> label
    end)
    |> Enum.join(", ")
  end

  defp availability_sentence(_labels), do: "one of these times"

  defp calendar_date_part(label) when is_binary(label) do
    label
    |> String.split(" at ", parts: 2)
    |> List.first()
  end

  defp calendar_date_part(_label), do: ""

  defp calendar_time_part(label) when is_binary(label) do
    case String.split(label, " at ", parts: 2) do
      [_date, time] -> time
      _ -> ""
    end
  end

  defp calendar_time_part(_label), do: ""

  defp local_date(%DateTime{} = datetime) do
    offset = Timezones.offset_at(@availability_timezone, datetime, @availability_offset_hours)

    datetime
    |> DateTime.add(offset, :hour)
    |> DateTime.to_date()
  end

  defp local_boundary_to_utc(%Date{} = date, %Time{} = time) do
    local_boundary = DateTime.new!(date, time, "Etc/UTC")

    offset =
      Timezones.offset_for_local(
        @availability_timezone,
        local_boundary,
        @availability_offset_hours
      )

    DateTime.add(local_boundary, -offset, :hour)
  end

  defp timezone_label(%DateTime{} = datetime) do
    offset = Timezones.offset_at(@availability_timezone, datetime, @availability_offset_hours)
    Timezones.label(@availability_timezone, offset)
  end

  defp weekend?(%Date{} = date), do: Date.day_of_week(date) in [6, 7]

  defp weekday_name(%DateTime{} = datetime) do
    ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
    |> Enum.at(Date.day_of_week(DateTime.to_date(datetime)) - 1)
  end

  defp month_name(%DateTime{month: month}) do
    ~w(January February March April May June July August September October November December)
    |> Enum.at(month - 1)
  end

  defp clock_label(%DateTime{} = datetime) do
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

  defp gmail_recipient(user_id, %Todo{} = todo, draft_map, metadata, source_message) do
    direct =
      []
      |> Kernel.++(email_field_values(draft_map, ~w(to recipient_email recipient reply_to)))
      |> Kernel.++(email_field_values(metadata, ~w(reply_to from_email from sender)))
      |> Kernel.++(email_field_values(source_message, ~w(reply_to from sender)))
      |> Enum.find_value(&valid_external_email_destination(&1, todo))

    direct ||
      crm_email_recipient(user_id, todo, draft_map, metadata, source_message) ||
      local_contact_email_recipient(user_id, todo, draft_map, metadata, source_message)
  end

  defp valid_email_destination(value) when is_binary(value) do
    case Regex.run(~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, value) do
      [email] -> String.downcase(email)
      _other -> nil
    end
  end

  defp valid_email_destination(_value), do: nil

  defp valid_external_email_destination(value, %Todo{} = todo) do
    with email when is_binary(email) <- valid_email_destination(value),
         false <- same_email?(email, todo.source_account_label) do
      email
    else
      _ -> nil
    end
  end

  defp email_field_values(map, keys) when is_map(map) and is_list(keys) do
    keys
    |> Enum.flat_map(fn key ->
      map
      |> raw_map_value(key)
      |> email_values()
    end)
  end

  defp email_field_values(_map, _keys), do: []

  defp email_values(values) when is_list(values), do: Enum.flat_map(values, &email_values/1)

  defp email_values(%{} = value) do
    [
      read_string(value, "email"),
      read_string(value, "address"),
      read_string(value, "value"),
      read_string(value, "mail")
    ]
    |> Enum.reject(&blank?/1)
  end

  defp email_values(value) when is_binary(value), do: [value]
  defp email_values(_value), do: []

  defp crm_email_recipient(user_id, %Todo{} = todo, draft_map, metadata, source_message)
       when is_binary(user_id) do
    todo
    |> recipient_name_candidates(draft_map, metadata, source_message, nil)
    |> Enum.find_value(fn query ->
      user_id
      |> Crm.search_people(query, limit: 5)
      |> Enum.find_value(&person_email_destination(&1, todo))
    end)
  rescue
    _ -> nil
  end

  defp crm_email_recipient(_user_id, _todo, _draft_map, _metadata, _source_message), do: nil

  defp person_email_destination(person, %Todo{} = todo) do
    person
    |> person_email_values()
    |> Enum.find_value(&valid_external_email_destination(&1, todo))
  end

  defp person_email_values(%{contact_details: contact_details}) when is_map(contact_details) do
    contact_details
    |> email_field_values(~w(emails email addresses))
  end

  defp person_email_values(_person), do: []

  defp local_contact_email_recipient(user_id, %Todo{} = todo, draft_map, metadata, source_message)
       when is_binary(user_id) do
    todo
    |> recipient_name_candidates(draft_map, metadata, source_message, nil)
    |> Enum.find_value(fn query ->
      user_id
      |> local_contacts_for_name(query)
      |> Enum.find_value(&local_contact_email_destination(&1, todo))
    end)
  rescue
    _ -> nil
  end

  defp local_contact_email_recipient(_user_id, _todo, _draft_map, _metadata, _source_message),
    do: nil

  defp local_contacts_for_name(user_id, query) do
    pattern = "%#{query}%"

    LocalContact
    |> where([contact], contact.user_id == ^user_id)
    |> where(
      [contact],
      ilike(contact.display_name, ^pattern) or ilike(contact.first_name, ^pattern) or
        ilike(contact.last_name, ^pattern) or ilike(contact.nickname, ^pattern) or
        fragment("?::text ILIKE ?", contact.emails, ^pattern)
    )
    |> order_by([contact],
      desc: contact.updated_at,
      asc: fragment("lower(coalesce(?, ''))", contact.display_name)
    )
    |> limit(5)
    |> Repo.all()
  end

  defp local_contact_email_destination(%LocalContact{emails: emails}, %Todo{} = todo) do
    emails
    |> List.wrap()
    |> Enum.find_value(&valid_external_email_destination(&1, todo))
  end

  defp local_contact_email_destination(_contact, _todo), do: nil

  defp recipient_name_candidates(%Todo{} = todo, draft_map, metadata, source_message, body) do
    metadata_names =
      metadata
      |> crm_people_from_metadata()
      |> Enum.flat_map(&crm_person_name_candidates/1)

    direct_names = [
      read_string(draft_map, "recipient_name"),
      read_string(draft_map, "recipient"),
      read_string(draft_map, "to"),
      read_string(metadata, "person"),
      read_string(metadata, "from_name"),
      read_string(metadata, "sender_name"),
      display_name_from_email_header(read_string(metadata, "from")),
      display_name_from_email_header(read_string(source_message, "from"))
    ]

    text_names =
      [
        todo.title,
        todo.summary,
        todo.next_action,
        read_string(draft_map, "text"),
        body
      ]
      |> Enum.flat_map(&recipient_names_from_text/1)

    (metadata_names ++ direct_names ++ text_names)
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&clean_recipient_name_candidate/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp crm_people_from_metadata(metadata) when is_map(metadata) do
    case raw_map_value(metadata, "crm_people") do
      people when is_list(people) -> Enum.filter(people, &is_map/1)
      %{} = person -> [person]
      _other -> []
    end
  end

  defp crm_people_from_metadata(_metadata), do: []

  defp crm_person_name_candidates(person) when is_map(person) do
    [
      read_string(person, "display_name"),
      [read_string(person, "first_name"), read_string(person, "last_name")]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
    ]
  end

  defp crm_person_name_candidates(_person), do: []

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
      ~r/\bmessage\s+([A-Z][A-Za-z'’-]+(?:\s+[A-Z][A-Za-z'’-]+){0,2})(?:\s+on|\s*:|,|\.|$)/,
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
      downcased in ["gmail", "email", "slack", "messages", "availability"] -> nil
      true -> value
    end
  end

  defp clean_recipient_name_candidate(_value), do: nil

  defp raw_map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || Map.get(map, existing_atom_key(key))
  end

  defp raw_map_value(_map, _key), do: nil

  defp same_email?(left, right) when is_binary(left) and is_binary(right) do
    normalize_email_identity(left) == normalize_email_identity(right)
  end

  defp same_email?(_left, _right), do: false

  defp normalize_email_identity(value) when is_binary(value) do
    valid_email_destination(value) || String.downcase(String.trim(value))
  end

  defp normalize_email_identity(_value), do: nil

  defp gmail_subject(todo, draft_map, metadata, source_message) do
    [
      read_string(draft_map, "subject"),
      read_string(metadata, "subject"),
      read_string(source_message, "subject"),
      todo.title
    ]
    |> Enum.find_value(&read_non_empty/1)
    |> normalize_reply_subject()
  end

  defp normalize_reply_subject(nil), do: nil

  defp normalize_reply_subject(subject) when is_binary(subject) do
    subject = String.trim(subject)

    cond do
      subject == "" -> nil
      String.match?(subject, ~r/^re:/i) -> subject
      true -> "Re: #{subject}"
    end
  end

  defp gmail_thread_id(%Todo{}, draft_map, metadata, source_message) do
    first_present([
      read_string(draft_map, "thread_id"),
      read_string(metadata, "thread_id"),
      read_string(source_message, "thread_id"),
      read_string(metadata, "gmail_thread_id")
    ])
  end

  defp gmail_account(%Todo{} = todo, draft_map, metadata) do
    [
      read_string(draft_map, "from"),
      read_string(draft_map, "account"),
      read_string(draft_map, "google_account_email"),
      read_string(metadata, "google_account_email"),
      read_string(metadata, "account_email"),
      todo.source_account_label,
      todo.user_id
    ]
    |> first_present()
    |> gmail_account_email_value()
  end

  defp gmail_account_email_value(value) when is_binary(value), do: valid_email_destination(value)
  defp gmail_account_email_value(_value), do: nil

  defp gmail_preview_text(to, subject) do
    case subject do
      nil -> "Send the saved Gmail draft to #{to}."
      subject -> "Send the saved Gmail draft to #{to} with subject \"#{subject}\"."
    end
  end

  defp slack_team_id(user_id, draft_map, metadata) do
    first_present([
      read_string(draft_map, "team_id"),
      read_string(draft_map, "workspace_id"),
      read_string(metadata, "team_id"),
      read_string(metadata, "workspace_id"),
      single_connected_slack_team_id(user_id)
    ])
  end

  defp single_connected_slack_team_id(user_id) when is_binary(user_id) do
    team_ids =
      user_id
      |> OAuth.list_user_tokens()
      |> Enum.map(&slack_team_id_from_token/1)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    case team_ids do
      [team_id] -> team_id
      _other -> nil
    end
  rescue
    _ -> nil
  end

  defp single_connected_slack_team_id(_user_id), do: nil

  defp slack_team_id_from_token(%{provider: provider, metadata: metadata}) do
    first_present([
      slack_team_id_from_provider(provider),
      read_string(metadata || %{}, "team_id")
    ])
  end

  defp slack_team_id_from_token(_token), do: nil

  defp slack_team_id_from_provider("slack:" <> rest) do
    rest
    |> String.split(":", parts: 2)
    |> List.first()
    |> read_non_empty()
  end

  defp slack_team_id_from_provider(_provider), do: nil

  defp slack_workspace_name(user_id, draft_map, metadata) do
    first_present([
      read_string(draft_map, "workspace_name"),
      read_string(draft_map, "team_name"),
      read_string(metadata, "workspace_name"),
      read_string(metadata, "team_name"),
      single_connected_slack_team_name(user_id)
    ])
  end

  defp single_connected_slack_team_name(user_id) when is_binary(user_id) do
    names =
      user_id
      |> OAuth.list_user_tokens()
      |> Enum.map(fn token -> read_string(token.metadata || %{}, "team_name") end)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    case names do
      [name] -> name
      _other -> nil
    end
  rescue
    _ -> nil
  end

  defp single_connected_slack_team_name(_user_id), do: nil

  defp slack_sender_label(user_id, draft_map, metadata) do
    first_present([
      read_string(draft_map, "from"),
      read_string(draft_map, "sender"),
      read_string(metadata, "from"),
      read_string(metadata, "sender"),
      slack_sender_from_token(user_id, draft_map, metadata)
    ])
  end

  defp slack_sender_from_token(user_id, draft_map, metadata) when is_binary(user_id) do
    team_id = slack_team_id(user_id, draft_map, metadata)

    slack_user_id =
      read_string(draft_map, "slack_user_id") || read_string(metadata, "slack_user_id")

    preference = read_string(draft_map, "token_preference") || "user"

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

  defp slack_sender_from_token(_user_id, _draft_map, _metadata), do: nil

  defp slack_user_token_available?(user_id, team_id, slack_user_id) do
    user_id
    |> OAuth.list_user_tokens()
    |> Enum.any?(fn token ->
      provider = token.provider || ""

      cond do
        present?(team_id) and present?(slack_user_id) ->
          provider == "slack:#{team_id}:user:#{slack_user_id}"

        present?(team_id) ->
          String.starts_with?(provider, "slack:#{team_id}:user:")

        true ->
          String.contains?(provider, ":user:")
      end
    end)
  end

  defp slack_channel(%Todo{} = todo, draft_map, metadata) do
    first_present([
      read_string(draft_map, "channel"),
      read_string(draft_map, "channel_id"),
      read_string(metadata, "channel"),
      read_string(metadata, "channel_id"),
      slack_channel_from_source_item_id(todo.source_item_id)
    ])
  end

  defp slack_channel_from_source_item_id(value) when is_binary(value) do
    value
    |> String.split(":", parts: 2)
    |> List.first()
    |> read_non_empty()
  end

  defp slack_channel_from_source_item_id(_value), do: nil

  defp slack_thread_ts(%Todo{} = todo, draft_map, metadata) do
    first_present([
      read_string(draft_map, "thread_ts"),
      read_string(metadata, "thread_ts"),
      slack_ts_from_source_item_id(todo.source_item_id)
    ])
  end

  defp slack_ts_from_source_item_id(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [_channel, ts] -> read_non_empty(ts)
      _other -> nil
    end
  end

  defp slack_ts_from_source_item_id(_value), do: nil

  defp slack_channel_name(draft_map, metadata, body) do
    first_present([
      read_string(draft_map, "channel_name"),
      read_string(draft_map, "conversation_name"),
      read_string(metadata, "channel_name"),
      read_string(metadata, "conversation_name"),
      slack_channel_mention_from_text(body)
    ])
  end

  defp slack_recipient(draft_map, metadata, body) do
    first_present([
      read_string(draft_map, "recipient"),
      read_string(draft_map, "to"),
      read_string(metadata, "person"),
      read_string(metadata, "channel_name"),
      read_string(metadata, "conversation_name"),
      slack_channel_mention_from_text(body),
      slack_recipient_from_instruction(body)
    ])
  end

  defp slack_channel_mention_from_text(body) when is_binary(body) do
    case Regex.run(~r/(?:^|\s)(#[A-Za-z0-9][A-Za-z0-9_-]*)\b/, body) do
      [_all, channel] -> channel
      _other -> nil
    end
  end

  defp slack_channel_mention_from_text(_body), do: nil

  defp slack_recipient_from_instruction(body) when is_binary(body) do
    case Regex.run(~r/\bmessage\s+(.+?)\s+on\s+slack\b/i, body) ||
           Regex.run(~r/\b(?:reply|respond)\s+to\s+(.+?)(?:\s+on\s+slack|\s*:|$)/i, body) ||
           Regex.run(~r/\b(?:share|send)\b.+?\b(?:with|to)\s+(.+?)(?:[.?!]|$)/i, body) ||
           Regex.run(~r/\bwith\s+(.+?)(?:\s+\(|[.?!]|$)/i, body) do
      [_all, value] -> clean_slack_recipient_label(value)
      _other -> nil
    end
  end

  defp slack_recipient_from_instruction(_body), do: nil

  defp clean_slack_recipient_label(value) when is_binary(value) do
    value
    |> String.replace(~r/\s*\([^)]*\)\s*$/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim(" .:;!?\"'")
    |> read_non_empty()
  end

  defp clean_slack_recipient_label(_value), do: nil

  defp slack_preview_text(payload) do
    destination =
      first_present([
        read_string(payload, "channel_name"),
        read_string(payload, "conversation_name"),
        read_string(payload, "recipient"),
        read_string(payload, "channel")
      ]) || "Slack"

    "Post a Slack message to #{destination}."
  end

  defp public_card(card) when is_map(card) do
    %{
      "headline" => read_string(card, "headline"),
      "decision_prompt" => read_string(card, "decision_prompt"),
      "why_now" => read_string(card, "why_now"),
      "next_best_action" => read_string(card, "next_best_action"),
      "draft_preview" => ActionCards.draft_preview(card),
      "evidence_excerpt" => ActionCards.evidence_excerpt(card),
      "source_context" => ActionCards.source_health_note(card),
      "prepared_action" => ActionCards.prepared_action_hint(card)
    }
    |> compact_map()
  end

  defp public_card(_card), do: %{}

  defp present?(value), do: not blank?(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) || Map.get(map, existing_atom_key(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) ->
        value |> Atom.to_string() |> read_non_empty()

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

  defp read_non_empty(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" or String.downcase(value) in ["nil", "null", "none"] do
      nil
    else
      value
    end
  end

  defp read_non_empty(_value), do: nil
end
