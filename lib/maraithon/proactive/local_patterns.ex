defmodule Maraithon.Proactive.LocalPatterns do
  @moduledoc """
  Server-side pattern detectors that surface proactive nudges across the
  v6 local sources (iMessage, Reminders, Voice Memos, Notes, Calendar,
  Files). Each detector runs through `Maraithon.Insights.record_many/3`
  so the standard dedupe / ranking / telegram-delivery pipeline applies.

  Six detectors:

    * **Cold thread** — a chat the user texts regularly has gone quiet for
      14+ days.
    * **Dropped commitment** — an open reminder whose title matches a
      recent iMessage request, now overdue.
    * **Untranscribed memo** — a voice memo recorded in the last 24h
      with no transcript.
    * **Note follow-up** — a recently modified note whose title or body
      contains a TODO / "later" / "remember" marker.
    * **Calendar conflict** — two events that overlap inside the next
      7-day window.
    * **File mention** — a recently created file in `~/Documents` whose
      filename matches the text of a recent iMessage.

  Each detector uses a stable `tracking_key` (cross-day) and a
  `dedupe_key` that includes the current local date. Re-running inside
  the same 24h upserts the same row; rolling into a new day dismisses
  yesterday's open revision and emits a fresh one — so the user gets at
  most one nudge per detector + match per day, and a single nudge if
  they never act on it (the insight stays in the open queue but doesn't
  re-spam Telegram, because `InsightNotifications` checks
  `delivery_exists?`).
  """

  import Ecto.Query

  require Logger

  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Crm.Person
  alias Maraithon.Insights
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.LocalFiles
  alias Maraithon.LocalFiles.LocalFile
  alias Maraithon.LocalMessages
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.LocalNotes
  alias Maraithon.LocalNotes.LocalNote
  alias Maraithon.LocalReminders
  alias Maraithon.LocalReminders.LocalReminder
  alias Maraithon.LocalVoiceMemos
  alias Maraithon.LocalVoiceMemos.LocalVoiceMemo
  alias Maraithon.Repo

  @system_behavior "prompt_agent"
  @system_config_marker %{"system" => "proactive_local_patterns"}

  @detectors [
    :cold_thread,
    :dropped_commitment,
    :untranscribed_memo,
    :note_follow_up,
    :calendar_conflict,
    :file_mention
  ]

  @cold_thread_min_messages 8
  @cold_thread_window_seconds 30 * 24 * 60 * 60
  @cold_thread_quiet_seconds 14 * 24 * 60 * 60

  @recent_message_lookback_seconds 14 * 24 * 60 * 60
  @reminder_match_min_token_length 4

  @memo_recent_seconds 24 * 60 * 60
  @note_recent_seconds 24 * 60 * 60
  @file_recent_seconds 7 * 24 * 60 * 60
  @file_message_lookback_seconds 7 * 24 * 60 * 60

  @note_follow_up_markers ~w(todo later remember follow up follow-up)

  # ---------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------

  @doc """
  Runs every detector for every user that has any local data or a
  connected telegram account. Returns a summary of how many insights
  were emitted per detector (rolled up across users).

  Used by `Maraithon.Runtime.ProactiveCheckIn` on its cron tick.
  """
  def run_for_all_users(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    user_ids = candidate_user_ids()

    summary =
      Enum.reduce(user_ids, empty_summary(), fn user_id, acc ->
        case run_for_user(user_id, now: now) do
          {:ok, per_detector} -> merge_summaries(acc, per_detector)
          {:error, _reason} -> acc
        end
      end)

    Map.put(summary, :user_count, length(user_ids))
  end

  @doc """
  Runs every detector for a single user. Returns
  `{:ok, %{cold_thread: n, ...}}`.
  """
  def run_for_user(user_id, opts \\ []) when is_binary(user_id) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    case ensure_system_agent(user_id) do
      {:ok, %Agent{id: agent_id}} ->
        per_detector =
          Enum.reduce(@detectors, %{}, fn detector, acc ->
            Map.put(acc, detector, run_detector(detector, user_id, agent_id, now))
          end)

        {:ok, per_detector}

      {:error, reason} ->
        Logger.warning("LocalPatterns could not ensure system agent",
          user_id: user_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Detector entry point used by tests so each detector can be exercised
  in isolation against a fixture. Public to keep the test surface stable
  if the internal loop changes.
  """
  def run_detector(detector, user_id, agent_id, now \\ DateTime.utc_now())
      when detector in @detectors and is_binary(user_id) and is_binary(agent_id) do
    insights = build_insights(detector, user_id, now)

    case Insights.record_many(user_id, agent_id, insights) do
      {:ok, recorded} -> length(recorded)
      _ -> 0
    end
  end

  # ---------------------------------------------------------------------
  # Detector dispatch
  # ---------------------------------------------------------------------

  defp build_insights(:cold_thread, user_id, now), do: cold_thread_insights(user_id, now)

  defp build_insights(:dropped_commitment, user_id, now),
    do: dropped_commitment_insights(user_id, now)

  defp build_insights(:untranscribed_memo, user_id, now),
    do: untranscribed_memo_insights(user_id, now)

  defp build_insights(:note_follow_up, user_id, now), do: note_follow_up_insights(user_id, now)

  defp build_insights(:calendar_conflict, user_id, now),
    do: calendar_conflict_insights(user_id, now)

  defp build_insights(:file_mention, user_id, now), do: file_mention_insights(user_id, now)

  # ---------------------------------------------------------------------
  # 1. Cold thread
  # ---------------------------------------------------------------------

  defp cold_thread_insights(user_id, now) do
    quiet_cutoff = DateTime.add(now, -@cold_thread_quiet_seconds, :second)
    window_cutoff = DateTime.add(now, -@cold_thread_window_seconds, :second)

    LocalMessage
    |> where([m], m.user_id == ^user_id and not is_nil(m.chat_key) and not is_nil(m.sent_at))
    |> group_by([m], m.chat_key)
    |> select([m], %{
      chat_key: m.chat_key,
      latest_outgoing_at: filter(max(m.sent_at), m.is_from_me == true),
      count_30d: sum(fragment("CASE WHEN ? >= ? THEN 1 ELSE 0 END", m.sent_at, ^window_cutoff))
    })
    |> Repo.all()
    |> Enum.filter(fn row ->
      is_struct(row.latest_outgoing_at, DateTime) and
        DateTime.compare(row.latest_outgoing_at, quiet_cutoff) == :lt and
        (row.count_30d || 0) >= @cold_thread_min_messages
    end)
    |> Enum.map(fn row -> cold_thread_insight(user_id, now, row) end)
    |> Enum.reject(&is_nil/1)
  end

  defp cold_thread_insight(user_id, now, %{
         chat_key: chat_key,
         latest_outgoing_at: latest_outgoing,
         count_30d: count
       }) do
    days = days_since(now, latest_outgoing)
    identity = chat_identity_for(user_id, chat_key)

    if raw_phone_only_identity?(identity) do
      nil
    else
      labels = relationship_labels(identity.display)
      thread = cold_thread_context(user_id, chat_key, latest_outgoing)
      why = cold_thread_why_sentence(labels, identity, count, days)
      context_sentence = thread.context_sentence
      notes = [why, context_sentence] |> Enum.reject(&blank?/1) |> Enum.join(" ")

      %{
        "source" => "local_patterns",
        "category" => "important_fyi",
        "title" => cold_thread_title(labels, thread),
        "summary" => notes,
        "recommended_action" => cold_thread_recommended_action(labels, thread),
        "priority" => priority_for(:cold_thread, days),
        "confidence" => 0.78,
        "attention_mode" => "act_now",
        "source_id" => chat_key,
        "source_occurred_at" => thread.source_occurred_at || latest_outgoing,
        "tracking_key" => tracking_key(:cold_thread, chat_key),
        "dedupe_key" => dedupe_key(:cold_thread, chat_key, now),
        "metadata" =>
          %{
            "detector" => "cold_thread",
            "chat_key" => chat_key,
            "chat_display_name" => identity.display,
            "crm_person_id" => identity.person_id,
            "crm_relationship" => identity.relationship,
            "days_quiet" => days,
            "message_count_30d" => count,
            "last_outgoing_at" => format_dt(latest_outgoing),
            "latest_message_at" => format_dt(thread.latest_message_at),
            "pending_reply" => thread.pending_reply?,
            "last_meaningful_message" => thread.snippet,
            "last_meaningful_message_from_me" => thread.from_me?,
            "why_it_matters" => why,
            "notes" => notes
          }
          |> compact_map()
      }
    end
  end

  # ---------------------------------------------------------------------
  # 2. Dropped commitment
  # ---------------------------------------------------------------------

  defp dropped_commitment_insights(user_id, now) do
    overdue =
      user_id
      |> LocalReminders.open_reminders(limit: 100)
      |> Enum.filter(fn reminder ->
        is_struct(reminder.due_at, DateTime) and
          DateTime.compare(reminder.due_at, now) == :lt
      end)

    if overdue == [] do
      []
    else
      recent_message_texts =
        user_id
        |> LocalMessages.recent_for_user(limit: 200)
        |> Enum.filter(fn msg ->
          is_struct(msg.sent_at, DateTime) and
            DateTime.compare(
              msg.sent_at,
              DateTime.add(now, -@recent_message_lookback_seconds, :second)
            ) != :lt and
            is_binary(msg.text)
        end)

      Enum.flat_map(overdue, fn reminder ->
        case match_reminder_against_messages(reminder, recent_message_texts) do
          nil -> []
          %{} = match -> [dropped_commitment_insight(user_id, now, reminder, match)]
        end
      end)
    end
  end

  defp match_reminder_against_messages(%LocalReminder{title: title}, _msgs)
       when not is_binary(title),
       do: nil

  defp match_reminder_against_messages(%LocalReminder{title: title} = reminder, msgs) do
    title_tokens =
      title
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/u, trim: true)
      |> Enum.filter(&(String.length(&1) >= @reminder_match_min_token_length))
      |> Enum.uniq()

    if title_tokens == [] do
      nil
    else
      Enum.find_value(msgs, fn msg ->
        text = String.downcase(msg.text || "")

        matched =
          Enum.count(title_tokens, fn token -> String.contains?(text, token) end)

        # Require at least two distinct title tokens to appear in the
        # message so we don't trip on a single common word like
        # "follow" or "send".
        if matched >= min(2, length(title_tokens)) do
          %{message: msg, matched_tokens: matched, reminder_id: reminder.guid || reminder.id}
        else
          nil
        end
      end)
    end
  end

  defp dropped_commitment_insight(_user_id, now, %LocalReminder{} = reminder, match) do
    days_overdue = days_overdue(now, reminder.due_at)
    title = reminder.title || "this commitment"
    person = sender_label(match.message)

    %{
      "source" => "local_patterns",
      "category" => "commitment_unresolved",
      "title" => "Dropped commitment: #{title}",
      "summary" =>
        "Your reminder \"#{title}\" is #{days_overdue} day(s) overdue and matches a recent " <>
          "message from #{person}.",
      "recommended_action" =>
        "Either send #{person} an update or close the reminder once you've followed through.",
      "priority" => priority_for(:dropped_commitment, days_overdue),
      "confidence" => 0.7,
      "attention_mode" => "act_now",
      "source_id" => reminder.guid || reminder.id,
      "source_occurred_at" => reminder.due_at,
      "tracking_key" => tracking_key(:dropped_commitment, reminder.guid || reminder.id),
      "dedupe_key" => dedupe_key(:dropped_commitment, reminder.guid || reminder.id, now),
      "metadata" => %{
        "detector" => "dropped_commitment",
        "reminder_guid" => reminder.guid,
        "reminder_title" => title,
        "days_overdue" => days_overdue,
        "matching_message_guid" => match.message.guid,
        "matching_person" => person
      }
    }
  end

  # ---------------------------------------------------------------------
  # 3. Untranscribed memo
  # ---------------------------------------------------------------------

  defp untranscribed_memo_insights(user_id, now) do
    cutoff = DateTime.add(now, -@memo_recent_seconds, :second)

    user_id
    |> LocalVoiceMemos.recent_for_user(limit: 25)
    |> Enum.filter(fn memo ->
      is_struct(memo.created_at, DateTime) and
        DateTime.compare(memo.created_at, cutoff) != :lt and
        memo.transcript in [nil, ""]
    end)
    |> Enum.map(fn memo -> untranscribed_memo_insight(user_id, now, memo) end)
  end

  defp untranscribed_memo_insight(_user_id, now, %LocalVoiceMemo{} = memo) do
    title = memo.title || "Voice memo"
    age = age_label(now, memo.created_at)

    %{
      "source" => "local_patterns",
      "category" => "general",
      "title" => "Voice memo didn't transcribe",
      "summary" => "You recorded \"#{title}\" #{age} but it doesn't have a transcript yet.",
      "recommended_action" => "Open Maraithon and tap retry on the memo to re-transcribe it.",
      "priority" => 55,
      "confidence" => 0.85,
      "attention_mode" => "act_now",
      "source_id" => memo.guid || memo.id,
      "source_occurred_at" => memo.created_at,
      "tracking_key" => tracking_key(:untranscribed_memo, memo.guid || memo.id),
      "dedupe_key" => dedupe_key(:untranscribed_memo, memo.guid || memo.id, now),
      "metadata" => %{
        "detector" => "untranscribed_memo",
        "memo_guid" => memo.guid,
        "memo_title" => title,
        "memo_duration_seconds" => memo.duration_seconds
      }
    }
  end

  # ---------------------------------------------------------------------
  # 4. Note follow-up
  # ---------------------------------------------------------------------

  defp note_follow_up_insights(user_id, now) do
    cutoff = DateTime.add(now, -@note_recent_seconds, :second)

    user_id
    |> LocalNotes.recent_for_user(limit: 50)
    |> Enum.filter(fn note ->
      is_struct(note.modified_at, DateTime) and
        DateTime.compare(note.modified_at, cutoff) != :lt and
        note_marker_present?(note)
    end)
    |> Enum.map(fn note -> note_follow_up_insight(user_id, now, note) end)
  end

  defp note_marker_present?(%LocalNote{title: title, body: body, snippet: snippet}) do
    haystack =
      [title, body, snippet]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.join(" ")

    Enum.any?(@note_follow_up_markers, &String.contains?(haystack, &1))
  end

  defp note_follow_up_insight(_user_id, now, %LocalNote{} = note) do
    title = note.title || "Untitled note"

    %{
      "source" => "local_patterns",
      "category" => "general",
      "title" => "Open loop in note: #{title}",
      "summary" =>
        "You recently edited \"#{title}\" and it contains a TODO / later / remember marker.",
      "recommended_action" =>
        "Open the note and decide whether to act, schedule, or close the loop.",
      "priority" => 50,
      "confidence" => 0.7,
      "attention_mode" => "act_now",
      "source_id" => note.guid || note.id,
      "source_occurred_at" => note.modified_at,
      "tracking_key" => tracking_key(:note_follow_up, note.guid || note.id),
      "dedupe_key" => dedupe_key(:note_follow_up, note.guid || note.id, now),
      "metadata" => %{
        "detector" => "note_follow_up",
        "note_guid" => note.guid,
        "note_title" => title,
        "note_folder" => note.folder
      }
    }
  end

  # ---------------------------------------------------------------------
  # 5. Calendar conflict
  # ---------------------------------------------------------------------

  defp calendar_conflict_insights(user_id, now) do
    horizon = DateTime.add(now, 7 * 86_400, :second)

    events =
      user_id
      |> LocalCalendar.events_around(since: now, until: horizon, limit: 200)
      |> Enum.filter(fn event ->
        is_struct(event.start_at, DateTime) and is_struct(event.end_at, DateTime)
      end)
      |> Enum.sort_by(& &1.start_at, DateTime)

    conflicts_for(events)
    |> Enum.map(fn pair -> calendar_conflict_insight(user_id, now, pair) end)
  end

  defp conflicts_for(events), do: conflicts_for(events, [])

  defp conflicts_for([], acc), do: Enum.reverse(acc)

  defp conflicts_for([event | rest], acc) do
    overlapping =
      Enum.find(rest, fn other ->
        DateTime.compare(other.start_at, event.end_at) == :lt and
          DateTime.compare(event.start_at, other.end_at) == :lt
      end)

    case overlapping do
      nil -> conflicts_for(rest, acc)
      other -> conflicts_for(rest, [{event, other} | acc])
    end
  end

  defp calendar_conflict_insight(_user_id, now, {%LocalEvent{} = first, %LocalEvent{} = second}) do
    first_title = first.title || "Untitled event"
    second_title = second.title || "Untitled event"
    when_label = local_event_when(first.start_at)

    pair_id = Enum.sort([first.guid || first.id, second.guid || second.id]) |> Enum.join("|")

    %{
      "source" => "local_patterns",
      "category" => "event_important",
      "title" => "Calendar conflict #{when_label}: #{first_title} vs #{second_title}",
      "summary" =>
        "Two events overlap in the next 7 days: \"#{first_title}\" (#{format_dt(first.start_at)}) and " <>
          "\"#{second_title}\" (#{format_dt(second.start_at)}).",
      "recommended_action" => "Reschedule or decline one of the conflicting events.",
      "priority" => priority_for(:calendar_conflict, now, first.start_at),
      "confidence" => 0.9,
      "attention_mode" => "act_now",
      "source_id" => pair_id,
      "source_occurred_at" => first.start_at,
      "tracking_key" => tracking_key(:calendar_conflict, pair_id),
      "dedupe_key" => dedupe_key(:calendar_conflict, pair_id, now),
      "metadata" => %{
        "detector" => "calendar_conflict",
        "first_guid" => first.guid,
        "first_title" => first_title,
        "first_start_at" => format_dt(first.start_at),
        "second_guid" => second.guid,
        "second_title" => second_title,
        "second_start_at" => format_dt(second.start_at)
      }
    }
  end

  # ---------------------------------------------------------------------
  # 6. File mention
  # ---------------------------------------------------------------------

  defp file_mention_insights(user_id, now) do
    file_cutoff = DateTime.add(now, -@file_recent_seconds, :second)
    msg_cutoff = DateTime.add(now, -@file_message_lookback_seconds, :second)

    recent_files =
      user_id
      |> LocalFiles.recent_for_user(limit: 50)
      |> Enum.filter(fn file ->
        is_struct(file.created_at, DateTime) and
          DateTime.compare(file.created_at, file_cutoff) != :lt and
          file_in_documents?(file) and
          is_binary(file.filename) and file.filename != ""
      end)

    if recent_files == [] do
      []
    else
      recent_messages =
        user_id
        |> LocalMessages.recent_for_user(limit: 200)
        |> Enum.filter(fn msg ->
          is_struct(msg.sent_at, DateTime) and
            DateTime.compare(msg.sent_at, msg_cutoff) != :lt and
            is_binary(msg.text)
        end)

      Enum.flat_map(recent_files, fn file ->
        case match_file_in_messages(file, recent_messages) do
          nil -> []
          %{} = match -> [file_mention_insight(user_id, now, file, match)]
        end
      end)
    end
  end

  defp file_in_documents?(%LocalFile{path: path}) when is_binary(path) do
    String.contains?(String.downcase(path), "/documents/") or
      String.starts_with?(String.downcase(path), "~/documents/")
  end

  defp file_in_documents?(_file), do: false

  defp match_file_in_messages(%LocalFile{filename: filename} = file, messages) do
    base = filename_base(filename)

    if String.length(base) < 4 do
      nil
    else
      needle = String.downcase(base)

      Enum.find_value(messages, fn msg ->
        text = String.downcase(msg.text || "")

        if String.contains?(text, needle) do
          %{message: msg, file_id: file.guid || file.id, matched_term: base}
        else
          nil
        end
      end)
    end
  end

  defp match_file_in_messages(_file, _messages), do: nil

  defp filename_base(filename) when is_binary(filename) do
    filename
    |> String.replace(~r/\.[^.]+$/u, "")
    |> String.trim()
  end

  defp filename_base(_), do: ""

  defp file_mention_insight(_user_id, now, %LocalFile{} = file, match) do
    person = sender_label(match.message)
    filename = file.filename || "the file"

    %{
      "source" => "local_patterns",
      "category" => "commitment_unresolved",
      "title" => "Did you send #{person} the file you mentioned?",
      "summary" =>
        "You created `#{filename}` recently and texted #{person} something that referenced it.",
      "recommended_action" => "Check whether you actually sent #{filename} to #{person}.",
      "priority" => 60,
      "confidence" => 0.65,
      "attention_mode" => "act_now",
      "source_id" => file.guid || file.id,
      "source_occurred_at" => file.created_at,
      "tracking_key" =>
        tracking_key(:file_mention, "#{file.guid || file.id}:#{match.message.guid}"),
      "dedupe_key" =>
        dedupe_key(:file_mention, "#{file.guid || file.id}:#{match.message.guid}", now),
      "metadata" => %{
        "detector" => "file_mention",
        "file_guid" => file.guid,
        "file_name" => filename,
        "file_path" => file.path,
        "message_guid" => match.message.guid,
        "person" => person
      }
    }
  end

  # ---------------------------------------------------------------------
  # Dedupe / tracking key construction
  # ---------------------------------------------------------------------

  defp tracking_key(detector, suffix) do
    "local_patterns:#{detector}:#{suffix}"
  end

  defp dedupe_key(detector, suffix, %DateTime{} = now) do
    date_bucket = Date.to_iso8601(DateTime.to_date(now))
    "local_patterns:#{detector}:#{suffix}:#{date_bucket}"
  end

  # ---------------------------------------------------------------------
  # System agent + user enumeration
  # ---------------------------------------------------------------------

  defp ensure_system_agent(user_id) do
    case Repo.one(
           from agent in Agent,
             where:
               agent.user_id == ^user_id and agent.behavior == ^@system_behavior and
                 fragment("?->>'system' = ?", agent.config, "proactive_local_patterns"),
             order_by: [asc: agent.inserted_at],
             limit: 1
         ) do
      %Agent{} = agent ->
        {:ok, agent}

      nil ->
        case Agents.create_agent(%{
               user_id: user_id,
               behavior: @system_behavior,
               config: @system_config_marker,
               install_status: "enabled",
               status: "stopped"
             }) do
          {:ok, agent} -> {:ok, agent}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp candidate_user_ids do
    telegram_users =
      "telegram"
      |> ConnectedAccounts.list_connected_provider()
      |> Enum.map(& &1.user_id)

    local_users = local_source_user_ids()

    MapSet.new(telegram_users)
    |> MapSet.union(MapSet.new(local_users))
    |> MapSet.delete(nil)
    |> MapSet.to_list()
  end

  defp local_source_user_ids do
    [LocalMessage, LocalReminder, LocalVoiceMemo, LocalNote, LocalEvent, LocalFile]
    |> Enum.flat_map(fn schema ->
      Repo.all(from row in schema, distinct: row.user_id, select: row.user_id)
    end)
  end

  # ---------------------------------------------------------------------
  # Small helpers
  # ---------------------------------------------------------------------

  defp empty_summary do
    Enum.reduce(@detectors, %{user_count: 0}, fn detector, acc -> Map.put(acc, detector, 0) end)
  end

  defp merge_summaries(acc, per_detector) do
    Enum.reduce(per_detector, acc, fn {detector, count}, inner ->
      Map.update(inner, detector, count, &(&1 + count))
    end)
  end

  defp days_since(%DateTime{} = now, %DateTime{} = then) do
    div(max(DateTime.diff(now, then, :second), 0), 86_400)
  end

  defp days_since(_now, _then), do: 0

  defp days_overdue(%DateTime{} = now, %DateTime{} = due) do
    div(max(DateTime.diff(now, due, :second), 0), 86_400)
  end

  defp days_overdue(_now, _due), do: 0

  defp priority_for(:cold_thread, days) when is_integer(days) do
    clamp(50 + min(days, 30), 50, 80)
  end

  defp priority_for(:dropped_commitment, days_overdue) when is_integer(days_overdue) do
    clamp(65 + min(days_overdue, 20), 65, 90)
  end

  defp priority_for(_detector, _arg), do: 50

  defp priority_for(:calendar_conflict, %DateTime{} = now, %DateTime{} = start_at) do
    hours_until = div(max(DateTime.diff(start_at, now, :second), 0), 3_600)

    cond do
      hours_until <= 24 -> 90
      hours_until <= 72 -> 80
      true -> 70
    end
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp cold_thread_context(user_id, chat_key, latest_outgoing) do
    messages = LocalMessages.recent_for_chat(user_id, chat_key, limit: 20)

    pending_reply =
      Enum.find(messages, fn msg ->
        pending_reply_message?(msg, latest_outgoing)
      end)

    context_message =
      pending_reply ||
        Enum.find(messages, fn msg ->
          not msg.is_from_me and meaningful_message?(msg)
        end) ||
        Enum.find(messages, &meaningful_message?/1)

    %{
      pending_reply?: not is_nil(pending_reply),
      context_sentence: context_sentence(context_message),
      snippet: message_snippet(context_message),
      from_me?: context_message && context_message.is_from_me,
      latest_message_at: latest_message_at(messages),
      source_occurred_at: context_message && context_message.sent_at
    }
  end

  defp pending_reply_message?(%LocalMessage{} = msg, %DateTime{} = latest_outgoing) do
    not msg.is_from_me and meaningful_message?(msg) and is_struct(msg.sent_at, DateTime) and
      DateTime.compare(msg.sent_at, latest_outgoing) == :gt
  end

  defp pending_reply_message?(_msg, _latest_outgoing), do: false

  defp meaningful_message?(%LocalMessage{} = msg) do
    is_binary(message_snippet(msg))
  end

  defp meaningful_message?(_msg), do: false

  defp context_sentence(%LocalMessage{} = msg) do
    case {msg.is_from_me, message_snippet(msg)} do
      {false, snippet} when is_binary(snippet) ->
        "Last message from them: \"#{snippet}\""

      {true, snippet} when is_binary(snippet) ->
        "Last thread: you said \"#{snippet}\""

      _ ->
        nil
    end
  end

  defp context_sentence(_msg), do: nil

  defp message_snippet(%LocalMessage{text: text}) when is_binary(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> case do
      "" -> nil
      snippet -> truncate(snippet, 160)
    end
  end

  defp message_snippet(%LocalMessage{has_attachments: true}), do: "Attachment in the thread"
  defp message_snippet(_msg), do: nil

  defp latest_message_at([%LocalMessage{sent_at: %DateTime{} = sent_at} | _]), do: sent_at
  defp latest_message_at(_messages), do: nil

  defp cold_thread_title(labels, %{pending_reply?: true}), do: labels.title_reply
  defp cold_thread_title(labels, _thread), do: labels.title_check

  defp cold_thread_why_sentence(labels, identity, count, days) do
    relationship_prefix =
      case identity.relationship do
        relationship when is_binary(relationship) ->
          "#{labels.prose} is marked #{relationship}, and "

        _ ->
          ""
      end

    "Why this matters: #{relationship_prefix}you usually text #{labels.prose} regularly " <>
      "(#{count} messages in 30 days), but you have not sent anything in #{days} days."
  end

  defp cold_thread_recommended_action(%{kind: :thread} = labels, %{pending_reply?: true}) do
    "Open #{labels.action_target} and reply to the latest message."
  end

  defp cold_thread_recommended_action(labels, %{pending_reply?: true}) do
    "Reply to #{labels.prose} in the same thread."
  end

  defp cold_thread_recommended_action(%{kind: :thread} = labels, _thread) do
    "Open #{labels.action_target} and decide whether to send a quick check-in."
  end

  defp cold_thread_recommended_action(labels, _thread) do
    "Send #{labels.prose} a quick check-in message."
  end

  defp chat_identity_for(user_id, chat_key) do
    person = crm_person_for_chat(user_id, chat_key)

    display =
      case person do
        %Person{display_name: name} when is_binary(name) and name != "" ->
          name

        _ ->
          chat_display_for(user_id, chat_key)
      end

    %{
      display: display,
      person_id: person && person.id,
      relationship: normalize_optional_text(person && person.relationship)
    }
  end

  defp raw_phone_only_identity?(%{person_id: person_id, display: display}) do
    blank?(person_id) and phone_identifier?(display)
  end

  defp raw_phone_only_identity?(_identity), do: false

  defp relationship_labels(display) do
    cond do
      phone_identifier?(display) ->
        suffix = phone_suffix(display)

        %{
          kind: :thread,
          title_reply: "Reply in Messages thread ending #{suffix}",
          title_check: "Review Messages thread ending #{suffix}",
          prose: "this Messages thread ending #{suffix}",
          action_target: "the Messages thread ending #{suffix}"
        }

      is_binary(display) and String.trim(display) != "" ->
        display = String.trim(display)

        %{
          kind: :person,
          title_reply: "Reply to #{display}",
          title_check: "Check in with #{display}",
          prose: display,
          action_target: display
        }

      true ->
        %{
          kind: :person,
          title_reply: "Reply to this contact",
          title_check: "Check in with this contact",
          prose: "this contact",
          action_target: "this contact"
        }
    end
  end

  defp crm_person_for_chat(user_id, chat_key) do
    user_id
    |> chat_identifiers(chat_key)
    |> Enum.find_value(&crm_person_for_identifier(user_id, &1))
  end

  defp chat_identifiers(user_id, chat_key) do
    recent_handles =
      user_id
      |> LocalMessages.recent_for_chat(chat_key, limit: 20)
      |> Enum.map(& &1.sender_handle)

    [chat_key | recent_handles]
    |> Enum.flat_map(fn
      value when is_binary(value) -> String.split(value, ",")
      _ -> []
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp crm_person_for_identifier(user_id, identifier) do
    with kind when kind in [:email, :phone] <- identifier_kind(identifier) do
      identifier
      |> identifier_search_values(kind)
      |> Enum.find_value(fn search_value ->
        pattern = "%#{search_value}%"
        contact_key = crm_contact_key(kind)

        Repo.one(
          from person in Person,
            where:
              person.user_id == ^user_id and person.status == "active" and
                (fragment(
                   "(? -> ?)::text ILIKE ?",
                   person.contact_details,
                   ^contact_key,
                   ^pattern
                 ) or
                   fragment("?::text ILIKE ?", person.contact_details, ^pattern)),
            order_by: [
              desc: person.relationship_strength,
              desc: person.affinity_score,
              desc_nulls_last: person.last_interaction_at,
              desc: person.updated_at
            ],
            limit: 1
        )
      end)
    else
      _ -> nil
    end
  end

  defp identifier_kind(identifier) when is_binary(identifier) do
    cond do
      String.contains?(identifier, "@") -> :email
      phone_identifier?(identifier) -> :phone
      true -> nil
    end
  end

  defp identifier_kind(_identifier), do: nil

  defp identifier_search_values(identifier, :email) do
    identifier
    |> String.downcase()
    |> List.wrap()
  end

  defp identifier_search_values(identifier, :phone) do
    digits = phone_digits(identifier)

    [identifier, digits, "+" <> digits]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp crm_contact_key(:email), do: "emails"
  defp crm_contact_key(:phone), do: "phones"

  defp phone_identifier?(value) when is_binary(value) do
    String.match?(String.trim(value), ~r/^\+?[\d\s().-]{7,}$/) and
      String.length(phone_digits(value)) >= 7
  end

  defp phone_identifier?(_value), do: false

  defp phone_digits(value) when is_binary(value), do: String.replace(value, ~r/\D/u, "")
  defp phone_digits(_value), do: ""

  defp phone_suffix(value) do
    value
    |> phone_digits()
    |> String.graphemes()
    |> Enum.take(-4)
    |> Enum.join()
    |> case do
      "" -> "unknown"
      suffix -> suffix
    end
  end

  defp chat_display_for(user_id, chat_key) do
    case Repo.one(
           from msg in LocalMessage,
             where:
               msg.user_id == ^user_id and msg.chat_key == ^chat_key and
                 not is_nil(msg.chat_display_name),
             order_by: [desc: msg.sent_at],
             limit: 1
         ) do
      %LocalMessage{chat_display_name: name} when is_binary(name) and name != "" ->
        name

      _ ->
        # Fall back to the most recent non-self sender_handle. That's
        # encrypted, so we have to decrypt in memory.
        case Repo.one(
               from msg in LocalMessage,
                 where:
                   msg.user_id == ^user_id and msg.chat_key == ^chat_key and
                     msg.is_from_me == false,
                 order_by: [desc: msg.sent_at],
                 limit: 1
             ) do
          %LocalMessage{sender_handle: handle} when is_binary(handle) and handle != "" -> handle
          _ -> "this contact"
        end
    end
  end

  defp sender_label(%LocalMessage{sender_handle: handle, chat_display_name: display}) do
    cond do
      is_binary(display) and display != "" -> display
      is_binary(handle) and handle != "" -> handle
      true -> "them"
    end
  end

  defp sender_label(_), do: "them"

  defp normalize_optional_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_text(_value), do: nil

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or blank?(value) end)
    |> Map.new()
  end

  defp truncate(text, max_length) when is_binary(text) and is_integer(max_length) do
    if String.length(text) <= max_length do
      text
    else
      text
      |> String.slice(0, max(max_length - 3, 0))
      |> String.trim()
      |> Kernel.<>("...")
    end
  end

  defp age_label(%DateTime{} = now, %DateTime{} = then) do
    seconds = max(DateTime.diff(now, then, :second), 0)

    cond do
      seconds < 3_600 -> "in the last hour"
      seconds < 86_400 -> "#{div(seconds, 3_600)} hours ago"
      true -> "#{div(seconds, 86_400)} days ago"
    end
  end

  defp age_label(_now, _then), do: "recently"

  defp local_event_when(%DateTime{} = start_at) do
    hours = div(max(DateTime.diff(start_at, DateTime.utc_now(), :second), 0), 3_600)

    cond do
      hours <= 24 -> "today"
      hours <= 48 -> "tomorrow"
      true -> "this week"
    end
  end

  defp local_event_when(_), do: "this week"

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(DateTime.truncate(dt, :second))
  defp format_dt(_), do: nil
end
