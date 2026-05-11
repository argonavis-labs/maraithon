defmodule Maraithon.Tools.RecallAnywhereHelpers do
  @moduledoc """
  Scoring, normalization, and source dispatch for `recall_anywhere`.

  ## Scoring formula (v5: blended semantic + substring + recency + trust)

  Each hit gets a score in `[0, 1]` computed as:

      score = @semantic_weight     * semantic_score
            + @substring_weight    * substring_quality
            + @recency_weight      * recency_score
            + @source_trust_weight * source_trust

  Where (defaults documented as module attributes so they're easy to tune):

    * `@semantic_weight` (#{0.5}) — cosine similarity of the pgvector hit
      against the query embedding (`0.0` for hits that only matched via
      substring or for sources without embeddings)
    * `@substring_weight` (#{0.3}) — substring-match quality bucket
      (title 1.0 → snippet 0.6 → body 0.4 → none 0.2)
    * `@recency_weight` (#{0.15}) — linear decay from today (1.0) to
      `@recency_horizon_days` (90) days old (0.0)
    * `@source_trust_weight` (#{0.05}) — per-source authority prior, see
      the `@source_trust` table

  Sources fan out to **both** substring search and pgvector semantic
  search. The two lists are merged by record id: when both produced the
  same id, the higher substring-quality is kept and the semantic score
  is attached. Hits that only the semantic search produced default to
  `match_field: :none` so they still get the floor 0.2 substring score.

  Failures or missing pgvector columns make `semantic_score` default to
  `0.0` — the blend gracefully degrades to the v4 substring-only ranking
  in that case.

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
        match_field: :title | :snippet | :body | :none,
        semantic_score: 0.0..1.0  # optional; defaults to 0.0
      }

  Opts may include `:query_embedding` (a list of floats); when present
  the per-source function should also fan out the pgvector
  semantic_search and merge those hits in.
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
  @semantic_weight 0.5
  @substring_weight 0.3
  @recency_weight 0.15
  @source_trust_weight 0.05

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
      semantic: @semantic_weight,
      substring_quality: @substring_weight,
      recency: @recency_weight,
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

  The blend formula is:

      score = 0.5 * semantic_score
            + 0.3 * substring_quality
            + 0.15 * recency_score
            + 0.05 * source_trust

  When a hit has no `:semantic_score` (substring-only fan-out, or pgvector
  unavailable), it defaults to 0.0 and the blend degrades to the v4
  substring-only behaviour rescaled by the new weight slate.
  """
  def score_hit(%{} = hit, %DateTime{} = now) do
    source = Map.get(hit, :source) || "unknown"
    recency = recency_score(Map.get(hit, :timestamp), now)
    substring = substring_quality(Map.get(hit, :match_field))
    semantic = clamp_unit(Map.get(hit, :semantic_score, 0.0))
    trust = Map.get(@source_trust, source, 0.5)

    total =
      @semantic_weight * semantic +
        @substring_weight * substring +
        @recency_weight * recency +
        @source_trust_weight * trust

    %{
      source: source,
      id: Map.get(hit, :id),
      title: Map.get(hit, :title),
      snippet: Map.get(hit, :snippet),
      timestamp: Map.get(hit, :timestamp),
      score: Float.round(total, 4),
      semantic_score: Float.round(semantic, 4),
      recency_score: Float.round(recency, 4),
      substring_quality: Float.round(substring, 4),
      source_trust: trust
    }
  end

  defp clamp_unit(value) when is_number(value) do
    cond do
      value < 0.0 -> 0.0
      value > 1.0 -> 1.0
      true -> value * 1.0
    end
  end

  defp clamp_unit(_other), do: 0.0

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
      substring =
        LocalMessages.search(user_id, query, opts) |> Enum.map(&message_to_hit(&1, query))

      semantic =
        case Keyword.get(opts, :query_embedding) do
          vector when is_list(vector) ->
            user_id
            |> LocalMessages.semantic_search(vector, opts)
            |> Enum.map(fn {record, sim} ->
              record |> message_to_hit(query) |> Map.put(:semantic_score, sim)
            end)

          _ ->
            []
        end

      merge_hits(substring, semantic)
    end
  end

  defp default_source_function("local_notes") do
    fn user_id, query, opts ->
      substring = LocalNotes.search(user_id, query, opts) |> Enum.map(&note_to_hit(&1, query))

      semantic =
        case Keyword.get(opts, :query_embedding) do
          vector when is_list(vector) ->
            user_id
            |> LocalNotes.semantic_search(vector, opts)
            |> Enum.map(fn {record, sim} ->
              record |> note_to_hit(query) |> Map.put(:semantic_score, sim)
            end)

          _ ->
            []
        end

      merge_hits(substring, semantic)
    end
  end

  defp default_source_function("local_voice_memos") do
    fn user_id, query, opts ->
      substring =
        LocalVoiceMemos.search(user_id, query, opts) |> Enum.map(&voice_memo_to_hit(&1, query))

      semantic =
        case Keyword.get(opts, :query_embedding) do
          vector when is_list(vector) ->
            user_id
            |> LocalVoiceMemos.semantic_search(vector, opts)
            |> Enum.map(fn {record, sim} ->
              record |> voice_memo_to_hit(query) |> Map.put(:semantic_score, sim)
            end)

          _ ->
            []
        end

      merge_hits(substring, semantic)
    end
  end

  defp default_source_function("local_calendar") do
    fn user_id, query, opts ->
      substring = LocalCalendar.search(user_id, query, opts) |> Enum.map(&event_to_hit(&1, query))

      semantic =
        case Keyword.get(opts, :query_embedding) do
          vector when is_list(vector) ->
            user_id
            |> LocalCalendar.semantic_search(vector, opts)
            |> Enum.map(fn {record, sim} ->
              record |> event_to_hit(query) |> Map.put(:semantic_score, sim)
            end)

          _ ->
            []
        end

      merge_hits(substring, semantic)
    end
  end

  defp default_source_function("local_reminders") do
    fn user_id, query, opts ->
      substring =
        LocalReminders.search(user_id, query, opts) |> Enum.map(&reminder_to_hit(&1, query))

      semantic =
        case Keyword.get(opts, :query_embedding) do
          vector when is_list(vector) ->
            user_id
            |> LocalReminders.semantic_search(vector, opts)
            |> Enum.map(fn {record, sim} ->
              record |> reminder_to_hit(query) |> Map.put(:semantic_score, sim)
            end)

          _ ->
            []
        end

      merge_hits(substring, semantic)
    end
  end

  defp default_source_function("local_files") do
    fn user_id, query, opts ->
      substring = LocalFiles.search(user_id, query, opts) |> Enum.map(&file_to_hit(&1, query))

      semantic =
        case Keyword.get(opts, :query_embedding) do
          vector when is_list(vector) ->
            user_id
            |> LocalFiles.semantic_search(vector, opts)
            |> Enum.map(fn {record, sim} ->
              record |> file_to_hit(query) |> Map.put(:semantic_score, sim)
            end)

          _ ->
            []
        end

      merge_hits(substring, semantic)
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

  @doc """
  Merge a substring-search hit list with a semantic-search hit list.

  Hits are deduped by `{source, id}`. When both lists produced the same
  record we prefer the substring hit's `:match_field` (because it
  reflects which field literally contained the query) and copy across
  the semantic hit's `:semantic_score` so the blend formula in
  `score_hit/2` can use it. Records that only the semantic search
  produced are kept as-is with their `:semantic_score` and a
  `match_field: :none` default.
  """
  def merge_hits(substring_hits, semantic_hits)
      when is_list(substring_hits) and is_list(semantic_hits) do
    substring_by_key = Enum.into(substring_hits, %{}, &{hit_key(&1), &1})
    semantic_by_key = Enum.into(semantic_hits, %{}, &{hit_key(&1), &1})

    all_keys =
      (Map.keys(substring_by_key) ++ Map.keys(semantic_by_key))
      |> Enum.uniq()

    Enum.map(all_keys, fn key ->
      sub = Map.get(substring_by_key, key)
      sem = Map.get(semantic_by_key, key)

      case {sub, sem} do
        {nil, %{} = sem_hit} ->
          Map.put_new(sem_hit, :match_field, :none)

        {%{} = sub_hit, nil} ->
          Map.put_new(sub_hit, :semantic_score, 0.0)

        {%{} = sub_hit, %{} = sem_hit} ->
          sub_hit
          |> Map.put(:semantic_score, Map.get(sem_hit, :semantic_score, 0.0))
      end
    end)
  end

  defp hit_key(%{source: source, id: id}), do: {source, id}
  defp hit_key(_), do: {nil, nil}

  # Placeholder shown in place of any content field on a row whose
  # `encrypted_with_device_key` flag is true. The assistant sees this and
  # knows the record exists (and what its metadata is) but the actual
  # content is sealed under a key only the device holds — nothing on the
  # server can render it, deliberately.
  @encrypted_placeholder "[encrypted_with_device_key]"

  @doc """
  The string the assistant sees for any title/snippet/body field on a
  record that was sealed under the device key. Returned as a public
  helper so other tools that render records (per-source `notes_get`,
  `messages_get`, etc.) can reuse the same placeholder.
  """
  def encrypted_placeholder, do: @encrypted_placeholder

  # --- Per-source normalizers ---------------------------------------------

  defp message_to_hit(%LocalMessage{} = msg, query) do
    if encrypted?(msg) do
      %{
        source: "local_messages",
        id: msg.guid,
        title: msg.chat_display_name,
        snippet: @encrypted_placeholder,
        timestamp: msg.sent_at,
        match_field: :none
      }
    else
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
  end

  defp note_to_hit(%LocalNote{} = note, query) do
    if encrypted?(note) do
      %{
        source: "local_notes",
        id: note.guid,
        title: @encrypted_placeholder,
        snippet: @encrypted_placeholder,
        timestamp: note.modified_at || note.created_at,
        match_field: :none
      }
    else
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
  end

  defp voice_memo_to_hit(%LocalVoiceMemo{} = memo, query) do
    if encrypted?(memo) do
      %{
        source: "local_voice_memos",
        id: memo.guid,
        title: @encrypted_placeholder,
        snippet: @encrypted_placeholder,
        timestamp: memo.created_at,
        match_field: :none
      }
    else
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
  end

  defp event_to_hit(%LocalEvent{} = event, query) do
    if encrypted?(event) do
      %{
        source: "local_calendar",
        id: event.guid,
        title: @encrypted_placeholder,
        # `location` is plaintext metadata; we still expose it.
        snippet: truncate(event.location) || @encrypted_placeholder,
        timestamp: event.start_at,
        match_field: :none
      }
    else
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
  end

  defp reminder_to_hit(%LocalReminder{} = reminder, query) do
    if encrypted?(reminder) do
      %{
        source: "local_reminders",
        id: reminder.guid,
        title: @encrypted_placeholder,
        snippet: @encrypted_placeholder,
        timestamp:
          reminder.modified_at || reminder.due_at || reminder.completed_at || reminder.created_at,
        match_field: :none
      }
    else
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
  end

  defp file_to_hit(%LocalFile{} = file, query) do
    if encrypted?(file) do
      %{
        source: "local_files",
        id: file.guid,
        # `path` is intentionally stored plain on the row (the client redacts
        # `$HOME` to `~/`), so we still show it as a useful breadcrumb.
        title: file.path || @encrypted_placeholder,
        snippet: @encrypted_placeholder,
        timestamp: file.modified_at || file.created_at,
        match_field: :none
      }
    else
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
  end

  # `encrypted_with_device_key` is a stable column on every encrypted
  # source schema; the `Map.get/2` form lets this helper tolerate old
  # records that pre-date the column (default false).
  defp encrypted?(row) do
    case Map.get(row, :encrypted_with_device_key) do
      true -> true
      _ -> false
    end
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
