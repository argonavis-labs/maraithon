defmodule Maraithon.LocalCalendar do
  @moduledoc """
  Context for macOS Calendar.app events synced from a user's local
  machine via EventKit. Owns bulk-insert with idempotent dedupe,
  date-window lookups, attendee filtering, substring search, and
  per-device purges.

  macOS Calendar.app aggregates every calendar account the user has
  added locally (iCloud, Exchange, Google via CalDAV, etc.), so this
  mirror is the full cross-account picture — strictly more complete
  than the Google Calendar connector alone.
  """

  import Ecto.Query

  alias Maraithon.LocalCalendar.EmbedJob
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.LocalEmbeddings
  alias Maraithon.Repo

  @doc """
  Ingests a batch of event maps from a device for the given user.

  Each entry should be a string-keyed or atom-keyed map matching the
  payload defined in the companion spec. Inserts are idempotent via the
  `(user_id, device_id, source, guid)` unique constraint — re-sending the
  same payload is a no-op.

  Returns `{:ok, %{accepted: integer, duplicate: integer, invalid: integer}}`.
  """
  def ingest_batch(user_id, device_id, events)
      when is_binary(user_id) and is_list(events) do
    started_at = System.monotonic_time(:millisecond)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {prepared, invalid} =
      events
      |> Enum.map(&prepare_row(&1, user_id, device_id, now))
      |> Enum.split_with(&match?({:ok, _row}, &1))

    rows = Enum.map(prepared, fn {:ok, row} -> row end)

    {inserted_count, inserted_rows} =
      if rows == [] do
        {0, []}
      else
        Repo.insert_all(LocalEvent, rows,
          on_conflict: :nothing,
          conflict_target: [:user_id, :device_id, :source, :guid],
          returning: [:id]
        )
      end

    enqueue_embed_jobs(user_id, inserted_rows)

    total = length(rows)
    duplicate_count = total - inserted_count
    invalid_count = length(invalid)
    latency_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:maraithon, :companion, :calendar_events_ingested],
      %{
        count: length(events),
        accepted: inserted_count,
        duplicate: duplicate_count,
        invalid: invalid_count,
        latency_ms: latency_ms
      },
      %{user_id: user_id, device_id: device_id}
    )

    {:ok,
     %{
       accepted: inserted_count,
       duplicate: duplicate_count,
       invalid: invalid_count
     }}
  end

  def ingest_batch(_user_id, _device_id, _events), do: {:error, :invalid_batch}

  @doc """
  Returns events that overlap `[since, until]`, ordered by `start_at` asc.

  Opts:
    * `:since`  — `%DateTime{}` lower bound (default: now)
    * `:until`  — `%DateTime{}` upper bound (default: now + 7 days)
    * `:limit`  — integer (default: 50)
  """
  def events_around(user_id, opts \\ []) when is_binary(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    since = parse_datetime_arg(Keyword.get(opts, :since), now)
    until = parse_datetime_arg(Keyword.get(opts, :until), DateTime.add(now, 7 * 86_400, :second))
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from event in LocalEvent,
        where: event.user_id == ^user_id,
        where: event.start_at <= ^until and event.end_at >= ^since,
        order_by: [asc: event.start_at],
        limit: ^limit
    )
  end

  @doc """
  Returns events whose attendee list, organizer email, or title contains
  the given substring (case-insensitive). Useful for "meetings with
  Charlie" style queries.

  Opts:
    * `:since` — lower bound for `start_at` (default: 30 days ago)
    * `:limit` — integer (default: 50)
  """
  def events_for_attendee(user_id, email_or_substring, opts \\ [])
      when is_binary(user_id) and is_binary(email_or_substring) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    since =
      parse_datetime_arg(Keyword.get(opts, :since), DateTime.add(now, -30 * 86_400, :second))

    limit = Keyword.get(opts, :limit, 50)
    needle = email_or_substring |> String.trim() |> String.downcase()

    user_id
    |> recent_events_query(since: since, limit: 500)
    |> Repo.all()
    |> Enum.filter(&attendee_matches?(&1, needle))
    |> Enum.take(limit)
  end

  @doc """
  Searches events for `term` (case-insensitive substring) against title,
  notes, and location. Since `title` and `notes` are encrypted at rest,
  we pull a window of recent events and filter in memory — matches the
  pattern used by `LocalNotes.search/3`.

  Opts:
    * `:since` — lower bound for `start_at` (default: 90 days ago)
    * `:limit` — integer (default: 50)
  """
  def search(user_id, term, opts \\ [])
      when is_binary(user_id) and is_binary(term) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    since =
      parse_datetime_arg(Keyword.get(opts, :since), DateTime.add(now, -90 * 86_400, :second))

    limit = Keyword.get(opts, :limit, 50)
    needle = term |> String.trim() |> String.downcase()

    user_id
    |> recent_events_query(since: since, limit: 500)
    |> Repo.all()
    |> Enum.filter(&matches_term?(&1, needle))
    |> Enum.take(limit)
  end

  @doc """
  Semantic search for events whose title, notes, or location are
  semantically similar to `query`. Pairs with `search/3` (substring) —
  use `semantic_search/3` when the user asks "when's the launch
  meeting" or "find the meeting about something similar" and won't
  recall the exact title.

  Options:
    * `:since` — lower bound for `start_at` (default 90 days ago)
    * `:limit` — max rows to return (default 12)
  """
  def semantic_search(user_id, query, opts \\ [])

  def semantic_search(user_id, query, opts)
      when is_binary(user_id) and is_binary(query) and is_list(opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    since =
      parse_datetime_arg(Keyword.get(opts, :since), DateTime.add(now, -90 * 86_400, :second))

    limit = Keyword.get(opts, :limit, 12)
    pool_size = Keyword.get(opts, :pool_size, 300)

    user_id
    |> recent_events_query(since: since, limit: pool_size)
    |> Repo.all()
    |> Maraithon.LocalSemanticSearch.rank_by_similarity(
      query,
      &event_text/1,
      Keyword.put(opts, :limit, limit)
    )
  end

  def semantic_search(user_id, query_vector, opts)
      when is_binary(user_id) and is_list(query_vector) and is_list(opts) do
    pgvector_semantic_search(user_id, query_vector, opts)
  end

  def semantic_search(_user_id, _query, _opts), do: []

  defp pgvector_semantic_search(user_id, query_vector, opts) do
    limit = Keyword.get(opts, :limit, 10)

    case LocalEmbeddings.semantic_search("local_calendar_events", user_id, query_vector, opts) do
      [] ->
        []

      rows ->
        ids = Enum.map(rows, fn {id, _sim} -> id end)

        events =
          Repo.all(
            from event in LocalEvent,
              where: event.user_id == ^user_id and event.id in ^ids
          )

        sim_by_id = Map.new(rows)

        events
        |> Enum.map(fn event -> {event, Map.get(sim_by_id, event.id, 0.0)} end)
        |> Enum.sort_by(fn {_event, sim} -> -sim end)
        |> Enum.take(limit)
    end
  end

  defp event_text(%LocalEvent{title: title, notes: notes, location: location}) do
    [title, notes, location]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc """
  Fetches one event for a user by its source GUID. Returns `nil` when no
  matching event exists.
  """
  def get_by_guid(user_id, guid) when is_binary(user_id) and is_binary(guid) do
    Repo.one(
      from event in LocalEvent,
        where: event.user_id == ^user_id and event.guid == ^guid,
        limit: 1
    )
  end

  def get_by_guid(_user_id, _guid), do: nil

  @doc """
  Purges every calendar event for a (user, device) pair. Returns
  `{:ok, %{deleted: count}}`.
  """
  def purge_device(user_id, device_id) when is_binary(user_id) do
    {deleted, _} =
      Repo.delete_all(
        from event in LocalEvent,
          where: event.user_id == ^user_id and event.device_id == ^device_id
      )

    {:ok, %{deleted: deleted}}
  end

  # -- internals ---------------------------------------------------------

  defp recent_events_query(user_id, opts) do
    since = Keyword.fetch!(opts, :since)
    limit = Keyword.fetch!(opts, :limit)

    from event in LocalEvent,
      where: event.user_id == ^user_id and event.start_at >= ^since,
      order_by: [asc: event.start_at],
      limit: ^limit
  end

  defp prepare_row(event, user_id, device_id, now) when is_map(event) do
    attendee_emails =
      event
      |> fetch(:attendee_emails)
      |> normalize_string_list()

    attendees_count =
      case parse_integer(fetch(event, :attendees_count)) do
        nil -> length(attendee_emails)
        n when is_integer(n) -> n
      end

    attrs = %{
      user_id: user_id,
      device_id: device_id,
      source: fetch(event, :source) || "calendar",
      guid: fetch(event, :guid),
      local_id: fetch(event, :local_id),
      calendar_name: fetch(event, :calendar_name),
      calendar_color: fetch(event, :calendar_color),
      title: fetch(event, :title),
      notes: fetch(event, :notes),
      location: fetch(event, :location),
      start_at: parse_datetime(fetch(event, :start_at)),
      end_at: parse_datetime(fetch(event, :end_at)),
      is_all_day: truthy?(fetch(event, :is_all_day)),
      is_recurring: truthy?(fetch(event, :is_recurring)),
      organizer_email: fetch(event, :organizer_email),
      attendees_count: attendees_count,
      attendee_emails: attendee_emails,
      created_at: parse_datetime(fetch(event, :created_at)),
      modified_at: parse_datetime(fetch(event, :modified_at)),
      encrypted_with_device_key: truthy?(fetch(event, :encrypted_with_device_key)),
      key_id: fetch(event, :key_id)
    }

    changeset = LocalEvent.changeset(%LocalEvent{}, attrs)

    if changeset.valid? do
      struct = Ecto.Changeset.apply_changes(changeset)

      row =
        LocalEvent.__schema__(:fields)
        |> Kernel.--([:id, :inserted_at, :updated_at])
        |> Enum.into(%{}, fn field -> {field, Map.get(struct, field)} end)
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)

      {:ok, row}
    else
      {:error, changeset}
    end
  end

  defp prepare_row(_other, _user_id, _device_id, _now), do: {:error, :invalid}

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(_), do: []

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_other), do: false

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp parse_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp parse_datetime_arg(nil, default), do: default
  defp parse_datetime_arg(%DateTime{} = dt, _default), do: DateTime.truncate(dt, :microsecond)

  defp parse_datetime_arg(value, default) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> default
    end
  end

  defp parse_datetime_arg(_value, default), do: default

  defp attendee_matches?(%LocalEvent{} = event, needle) do
    haystack_parts =
      [event.organizer_email, event.title]
      |> Enum.concat(event.attendee_emails || [])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)

    Enum.any?(haystack_parts, &String.contains?(&1, needle))
  end

  defp matches_term?(%LocalEvent{} = event, needle) do
    haystack =
      [event.title, event.notes, event.location]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.join(" ")

    String.contains?(haystack, needle)
  end

  defp enqueue_embed_jobs(_user_id, []), do: :ok

  defp enqueue_embed_jobs(user_id, inserted_rows) do
    if LocalEmbeddings.embedding_storage_available?("local_calendar_events") do
      Enum.each(inserted_rows, fn
        %{id: id} when is_binary(id) -> EmbedJob.enqueue(user_id, id)
        %LocalEvent{id: id} when is_binary(id) -> EmbedJob.enqueue(user_id, id)
        _ -> :ok
      end)
    end

    :ok
  end
end
