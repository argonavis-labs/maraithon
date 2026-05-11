defmodule Maraithon.Tools.RecallAnywhereHelpers do
  @moduledoc """
  Scoring, normalization, and source dispatch for `recall_anywhere`.

  ## Scoring formula

  Each hit gets a score in `[0, 1]` computed as:

      score = @recency_weight * recency_score
            + @substring_quality_weight * substring_quality
            + @source_trust_weight * source_trust

  Where (defaults documented as module attributes so they're easy to tune):

    * `@recency_weight` (#{0.6})
    * `@substring_quality_weight` (#{0.3})
    * `@source_trust_weight` (#{0.1})

  And components are bounded:

    * `recency_score` — 1.0 for today, decaying linearly to 0 at
      `@recency_horizon_days` (90) days old; > horizon clamps to 0.
    * `substring_quality` — title hit = 1.0, snippet hit = 0.6,
      body hit = 0.4, fallback (no substring match) = 0.2.
    * `source_trust` — see `@source_trust` table:
        * iMessage / Notes / Voice Memos / Reminders = 1.0 (user-authored)
        * Gmail / Slack = 0.8
        * Files / CRM people = 0.7
        * Calendar / Memory = 0.9
        * Browser History = 0.5

  Override the source-call dispatch table via:

      Application.put_env(:maraithon, :recall_anywhere_sources, %{
        "local_messages" => fn user_id, query, opts -> [...] end,
        ...
      })

  Each callable receives `(user_id, query, opts)` and must return a list of
  uniform hit maps shaped like:

      %{
        source: "local_messages",
        id: "guid-or-id",
        title: "...",
        snippet: "...",
        timestamp: %DateTime{} | nil,
        match_field: :title | :snippet | :body | :none
      }
  """

  alias Maraithon.Crm
  alias Maraithon.Crm.Person
  alias Maraithon.LocalBrowserHistory
  alias Maraithon.LocalBrowserHistory.LocalVisit
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
  alias Maraithon.Memory

  # Ranking weights (sum to 1.0 by convention; tune freely).
  @recency_weight 0.6
  @substring_quality_weight 0.3
  @source_trust_weight 0.1

  # Horizon for recency decay, in days.
  @recency_horizon_days 90

  # Source-trust table.
  @source_trust %{
    "local_messages" => 1.0,
    "local_notes" => 1.0,
    "local_voice_memos" => 1.0,
    "local_reminders" => 1.0,
    "local_calendar" => 0.9,
    "maraithon_memory" => 0.9,
    "gmail" => 0.8,
    "slack" => 0.8,
    "local_files" => 0.7,
    "crm_people" => 0.7,
    "local_browser_history" => 0.5
  }

  @snippet_limit 200

  @all_sources ~w(
    local_messages local_notes local_voice_memos local_calendar
    local_reminders local_files local_browser_history
    maraithon_memory crm_people
  )

  @doc "Return the canonical list of source names this tool searches."
  def all_sources, do: @all_sources

  @doc "Return the configured per-source weights so callers can inspect them."
  def weights do
    %{
      recency: @recency_weight,
      substring_quality: @substring_quality_weight,
      source_trust: @source_trust_weight,
      recency_horizon_days: @recency_horizon_days
    }
  end

  @doc "Return the configured source trust map (defaults can be overridden in tests)."
  def source_trust, do: @source_trust

  @doc """
  Filter `requested` against `all_sources()` and return the valid subset.
  When `requested` is `nil` or empty, return `all_sources()`.
  """
  def normalize_sources(nil), do: @all_sources
  def normalize_sources([]), do: @all_sources

  def normalize_sources(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> Enum.filter(&(&1 in @all_sources))
    |> case do
      [] -> @all_sources
      filtered -> filtered
    end
  end

  def normalize_sources(_), do: @all_sources

  @doc """
  Resolve the per-source search function for `source_name`. Tests can install
  overrides through `Application.put_env(:maraithon, :recall_anywhere_sources, %{...})`.
  """
  def source_function(source_name) when is_binary(source_name) do
    overrides = Application.get_env(:maraithon, :recall_anywhere_sources, %{})

    Map.get(overrides, source_name) || default_source_function(source_name)
  end

  @doc """
  Score a uniform hit against `now`.

  Returns a `:score` float, plus the component breakdown stored on the hit for
  observability and tunability.
  """
  def score_hit(%{} = hit, %DateTime{} = now) do
    source = Map.get(hit, :source) || "unknown"
    recency = recency_score(Map.get(hit, :timestamp), now)
    substring = substring_quality(Map.get(hit, :match_field))
    trust = Map.get(@source_trust, source, 0.5)

    total =
      @recency_weight * recency +
        @substring_quality_weight * substring +
        @source_trust_weight * trust

    %{
      source: source,
      id: Map.get(hit, :id),
      title: Map.get(hit, :title),
      snippet: Map.get(hit, :snippet),
      timestamp: Map.get(hit, :timestamp),
      score: Float.round(total, 4),
      recency_score: Float.round(recency, 4),
      substring_quality: Float.round(substring, 4),
      source_trust: trust
    }
  end

  @doc """
  Sort uniform hits by descending score, deterministic ties broken by
  newest-first then by source/id.
  """
  def rank(hits) do
    Enum.sort_by(
      hits,
      fn hit ->
        ts = hit[:timestamp]

        ts_key =
          case ts do
            %DateTime{} = dt -> -DateTime.to_unix(dt, :microsecond)
            _ -> 0
          end

        {-(hit[:score] || 0.0), ts_key, hit[:source] || "", hit[:id] || ""}
      end
    )
  end

  @doc """
  Substring search of the query against a single text field. Used by helper
  scoring code to classify which kind of hit a source produced when the
  underlying context module already filtered.
  """
  def classify_match(query, title, snippet, body) when is_binary(query) do
    needle = String.downcase(String.trim(query))

    cond do
      needle == "" -> :none
      contains?(title, needle) -> :title
      contains?(snippet, needle) -> :snippet
      contains?(body, needle) -> :body
      true -> :none
    end
  end

  defp contains?(nil, _needle), do: false

  defp contains?(value, needle) when is_binary(value) and is_binary(needle) do
    String.contains?(String.downcase(value), needle)
  end

  defp contains?(_value, _needle), do: false

  defp recency_score(%DateTime{} = timestamp, %DateTime{} = now) do
    age_days = DateTime.diff(now, timestamp, :second) / 86_400

    cond do
      age_days < 0 -> 1.0
      age_days >= @recency_horizon_days -> 0.0
      true -> 1.0 - age_days / @recency_horizon_days
    end
  end

  defp recency_score(_timestamp, _now), do: 0.0

  defp substring_quality(:title), do: 1.0
  defp substring_quality(:snippet), do: 0.6
  defp substring_quality(:body), do: 0.4
  defp substring_quality(_other), do: 0.2

  # --- Default source functions -------------------------------------------

  defp default_source_function("local_messages") do
    fn user_id, query, opts ->
      LocalMessages.search(user_id, query, opts)
      |> Enum.map(&message_to_hit(&1, query))
    end
  end

  defp default_source_function("local_notes") do
    fn user_id, query, opts ->
      LocalNotes.search(user_id, query, opts)
      |> Enum.map(&note_to_hit(&1, query))
    end
  end

  defp default_source_function("local_voice_memos") do
    fn user_id, query, opts ->
      LocalVoiceMemos.search(user_id, query, opts)
      |> Enum.map(&voice_memo_to_hit(&1, query))
    end
  end

  defp default_source_function("local_calendar") do
    fn user_id, query, opts ->
      LocalCalendar.search(user_id, query, opts)
      |> Enum.map(&event_to_hit(&1, query))
    end
  end

  defp default_source_function("local_reminders") do
    fn user_id, query, opts ->
      LocalReminders.search(user_id, query, opts)
      |> Enum.map(&reminder_to_hit(&1, query))
    end
  end

  defp default_source_function("local_files") do
    fn user_id, query, opts ->
      LocalFiles.search(user_id, query, opts)
      |> Enum.map(&file_to_hit(&1, query))
    end
  end

  defp default_source_function("local_browser_history") do
    fn user_id, query, opts ->
      LocalBrowserHistory.search(user_id, query, opts)
      |> Enum.map(&visit_to_hit(&1, query))
    end
  end

  defp default_source_function("maraithon_memory") do
    fn user_id, query, opts ->
      case Memory.recall(user_id, query, opts) do
        {:ok, %{memories: memories}} ->
          Enum.map(memories, &memory_to_hit(&1, query))

        _ ->
          []
      end
    end
  end

  defp default_source_function("crm_people") do
    fn user_id, query, opts ->
      Crm.search_people(user_id, query, opts)
      |> Enum.map(&person_to_hit(&1, query))
    end
  end

  defp default_source_function(_), do: fn _, _, _ -> [] end

  # --- Per-source normalizers ---------------------------------------------

  defp message_to_hit(%LocalMessage{} = msg, query) do
    snippet = truncate(msg.text)

    %{
      source: "local_messages",
      id: msg.guid,
      title: msg.chat_display_name || msg.sender_handle,
      snippet: snippet,
      timestamp: msg.sent_at,
      match_field: classify_match(query, msg.chat_display_name, snippet, msg.text)
    }
  end

  defp note_to_hit(%LocalNote{} = note, query) do
    snippet = truncate(note.snippet || note.body)

    %{
      source: "local_notes",
      id: note.guid,
      title: note.title,
      snippet: snippet,
      timestamp: note.modified_at || note.created_at,
      match_field: classify_match(query, note.title, snippet, note.body)
    }
  end

  defp voice_memo_to_hit(%LocalVoiceMemo{} = memo, query) do
    snippet = truncate(memo.snippet || memo.transcript)

    %{
      source: "local_voice_memos",
      id: memo.guid,
      title: memo.title,
      snippet: snippet,
      timestamp: memo.created_at,
      match_field: classify_match(query, memo.title, snippet, memo.transcript)
    }
  end

  defp event_to_hit(%LocalEvent{} = event, query) do
    snippet = truncate(event.notes) || truncate(event.location)

    %{
      source: "local_calendar",
      id: event.guid,
      title: event.title,
      snippet: snippet,
      timestamp: event.start_at,
      match_field: classify_match(query, event.title, snippet, event.notes)
    }
  end

  defp reminder_to_hit(%LocalReminder{} = reminder, query) do
    snippet = truncate(reminder.notes)

    %{
      source: "local_reminders",
      id: reminder.guid,
      title: reminder.title,
      snippet: snippet,
      timestamp:
        reminder.modified_at || reminder.due_at || reminder.completed_at || reminder.created_at,
      match_field: classify_match(query, reminder.title, snippet, reminder.notes)
    }
  end

  defp file_to_hit(%LocalFile{} = file, query) do
    snippet = truncate(file.text_content)

    %{
      source: "local_files",
      id: file.guid,
      title: file.filename || file.path,
      snippet: snippet,
      timestamp: file.modified_at || file.created_at,
      match_field: classify_match(query, file.filename, snippet, file.text_content)
    }
  end

  defp visit_to_hit(%LocalVisit{} = visit, query) do
    snippet = truncate(visit.url)

    %{
      source: "local_browser_history",
      id: visit.guid,
      title: visit.title || visit.host,
      snippet: snippet,
      timestamp: visit.last_visited_at,
      match_field: classify_match(query, visit.title, visit.url, visit.host)
    }
  end

  defp memory_to_hit(%{} = memory, query) do
    title = Map.get(memory, :title) || Map.get(memory, "title")
    summary = Map.get(memory, :summary) || Map.get(memory, "summary")
    content = Map.get(memory, :content) || Map.get(memory, "content")
    snippet = truncate(summary || content)

    timestamp =
      Map.get(memory, :updated_at) || Map.get(memory, "updated_at") ||
        Map.get(memory, :inserted_at) || Map.get(memory, "inserted_at")

    %{
      source: "maraithon_memory",
      id: Map.get(memory, :id) || Map.get(memory, "id"),
      title: title,
      snippet: snippet,
      timestamp: timestamp,
      match_field: classify_match(query, title, snippet, content)
    }
  end

  defp person_to_hit(%Person{} = person, query) do
    title = person.display_name || join_name(person.first_name, person.last_name)
    snippet = person.notes |> truncate()

    %{
      source: "crm_people",
      id: person.id,
      title: title,
      snippet: snippet,
      timestamp: person.last_interaction_at || person.updated_at,
      match_field: classify_match(query, title, snippet, person.notes)
    }
  end

  defp person_to_hit(%{} = person, query) do
    title =
      Map.get(person, :display_name) || Map.get(person, "display_name") ||
        join_name(
          Map.get(person, :first_name) || Map.get(person, "first_name"),
          Map.get(person, :last_name) || Map.get(person, "last_name")
        )

    notes = Map.get(person, :notes) || Map.get(person, "notes")

    %{
      source: "crm_people",
      id: Map.get(person, :id) || Map.get(person, "id"),
      title: title,
      snippet: truncate(notes),
      timestamp:
        Map.get(person, :last_interaction_at) || Map.get(person, "last_interaction_at") ||
          Map.get(person, :updated_at) || Map.get(person, "updated_at"),
      match_field: classify_match(query, title, nil, notes)
    }
  end

  defp join_name(nil, nil), do: nil
  defp join_name(first, nil) when is_binary(first), do: first
  defp join_name(nil, last) when is_binary(last), do: last
  defp join_name(first, last) when is_binary(first) and is_binary(last), do: "#{first} #{last}"

  defp truncate(nil), do: nil

  defp truncate(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.length(trimmed) > @snippet_limit do
      String.slice(trimmed, 0, @snippet_limit) <> "..."
    else
      trimmed
    end
  end

  defp truncate(_), do: nil
end
