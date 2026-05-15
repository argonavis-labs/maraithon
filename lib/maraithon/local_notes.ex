defmodule Maraithon.LocalNotes do
  @moduledoc """
  Context for macOS Notes.app notes synced from a user's local machine.
  Owns bulk-insert with idempotent dedupe, recent lookups, simple ILIKE
  search, and per-device purges.
  """

  import Ecto.Query

  alias Maraithon.LocalEmbeddings
  alias Maraithon.LocalNotes.EmbedJob
  alias Maraithon.LocalNotes.LocalNote
  alias Maraithon.Repo

  @doc """
  Ingests a batch of note maps from a device for the given user.

  Each entry should be a string-keyed or atom-keyed map matching the
  payload defined in the companion spec. Re-sends are counted as duplicates
  via the `(user_id, device_id, source, guid)` unique constraint while still
  refreshing mutable fields on the stored note.

  Returns `{:ok, %{accepted: integer, duplicate: integer, invalid: integer}}`.
  """
  def ingest_batch(user_id, device_id, notes)
      when is_binary(user_id) and is_list(notes) do
    started_at = System.monotonic_time(:millisecond)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {prepared, invalid} =
      notes
      |> Enum.map(&prepare_row(&1, user_id, device_id, now))
      |> Enum.split_with(&match?({:ok, _row}, &1))

    rows = Enum.map(prepared, fn {:ok, row} -> row end)
    existing_keys = existing_note_keys(user_id, device_id, rows)
    {accepted_count, duplicate_count} = ingest_counts(rows, existing_keys)

    returned_rows =
      if rows == [] do
        []
      else
        # Replace mutable fields on re-sync so later body decodes
        # (NotesBodyDecoder fallback path) backfill into existing rows
        # instead of being silently dropped by `on_conflict: :nothing`.
        {_affected_count, returned_rows} =
          Repo.insert_all(LocalNote, rows,
            on_conflict:
              {:replace,
               [
                 :title,
                 :snippet,
                 :body,
                 :body_format,
                 :folder,
                 :is_pinned,
                 :modified_at,
                 :updated_at
               ]},
            conflict_target: [:user_id, :device_id, :source, :guid],
            returning: [:id]
          )

        returned_rows
      end

    enqueue_embed_jobs(user_id, returned_rows)

    invalid_count = length(invalid)
    latency_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:maraithon, :companion, :notes_ingested],
      %{
        count: length(notes),
        accepted: accepted_count,
        duplicate: duplicate_count,
        invalid: invalid_count,
        latency_ms: latency_ms
      },
      %{user_id: user_id, device_id: device_id}
    )

    {:ok,
     %{
       accepted: accepted_count,
       duplicate: duplicate_count,
       invalid: invalid_count
     }}
  end

  def ingest_batch(_user_id, _device_id, _notes), do: {:error, :invalid_batch}

  @doc """
  Returns the most recent notes for a user, newest modified first.
  """
  def recent_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from note in LocalNote,
        where: note.user_id == ^user_id,
        order_by: [desc: note.modified_at],
        limit: ^limit
    )
  end

  @doc """
  Searches notes for a user using a substring match on the encrypted
  `title`, `snippet`, and `body` fields. Since these columns are
  encrypted at rest, we decrypt in memory and filter — fine for the
  small, device-bounded note volumes we expect today.
  """
  def search(user_id, term, opts \\ [])
      when is_binary(user_id) and is_binary(term) do
    limit = Keyword.get(opts, :limit, 50)
    needle = String.downcase(term)

    user_id
    |> recent_for_user(limit: 500)
    |> Enum.filter(&matches_term?(&1, needle))
    |> Enum.take(limit)
  end

  @doc """
  Semantic search for notes whose title, snippet, or body are
  semantically similar to `query`. Pairs with `search/3` (substring)
  for narrow lookups — `semantic_search/3` is the right call when the
  user asks "find that note about a similar idea" or "what was that
  thing I jotted down about ..." and exact-substring search would
  miss synonyms.

  Implementation: overfetch a recency window of rows then rank them
  in-memory by cosine similarity (notes are Cloak-encrypted at rest
  so a pure pgvector pushdown is not yet possible). See
  `Maraithon.LocalSemanticSearch` for the ranker.
  """
  def semantic_search(user_id, query, opts \\ [])

  def semantic_search(user_id, query, opts)
      when is_binary(user_id) and is_binary(query) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 12)
    pool_size = Keyword.get(opts, :pool_size, 200)

    user_id
    |> recent_for_user(limit: pool_size)
    |> Maraithon.LocalSemanticSearch.rank_by_similarity(
      query,
      &note_text/1,
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

    case LocalEmbeddings.semantic_search("local_notes", user_id, query_vector, opts) do
      [] ->
        []

      rows ->
        ids = Enum.map(rows, fn {id, _sim} -> id end)

        notes =
          Repo.all(
            from note in LocalNote,
              where: note.user_id == ^user_id and note.id in ^ids
          )

        sim_by_id = Map.new(rows)

        notes
        |> Enum.map(fn note -> {note, Map.get(sim_by_id, note.id, 0.0)} end)
        |> Enum.sort_by(fn {_note, sim} -> -sim end)
        |> Enum.take(limit)
    end
  end

  defp note_text(%LocalNote{title: title, snippet: snippet, body: body}) do
    [title, snippet, body]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc """
  Fetches one note for a user by its source GUID. Returns `nil` when no
  matching note exists.

  TODO: depends on server schema agent for the durable query semantics
  shared with the assistant tool surface (`Maraithon.Tools.NotesGet`).
  """
  def get_by_guid(user_id, guid) when is_binary(user_id) and is_binary(guid) do
    Repo.one(
      from note in LocalNote,
        where: note.user_id == ^user_id and note.guid == ^guid,
        limit: 1
    )
  end

  def get_by_guid(_user_id, _guid), do: nil

  @doc """
  Purges every note for a (user, device) pair. Returns
  `{:ok, %{deleted: count}}`.
  """
  def purge_device(user_id, device_id) when is_binary(user_id) do
    {deleted, _} =
      Repo.delete_all(
        from note in LocalNote,
          where: note.user_id == ^user_id and note.device_id == ^device_id
      )

    {:ok, %{deleted: deleted}}
  end

  # -- internals ---------------------------------------------------------

  defp existing_note_keys(_user_id, _device_id, []), do: MapSet.new()

  defp existing_note_keys(user_id, device_id, rows) do
    keys =
      rows
      |> Enum.map(&note_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    if MapSet.size(keys) == 0 do
      MapSet.new()
    else
      sources = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      guids = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      LocalNote
      |> where([note], note.user_id == ^user_id)
      |> where([note], note.device_id == ^device_id)
      |> where([note], note.source in ^sources)
      |> where([note], note.guid in ^guids)
      |> select([note], {note.source, note.guid})
      |> Repo.all()
      |> MapSet.new()
    end
  end

  defp ingest_counts(rows, existing_keys) do
    {accepted, duplicate, _seen} =
      Enum.reduce(rows, {0, 0, MapSet.new()}, fn row, {accepted, duplicate, seen} ->
        key = note_key(row)

        cond do
          is_nil(key) ->
            {accepted + 1, duplicate, seen}

          MapSet.member?(existing_keys, key) or MapSet.member?(seen, key) ->
            {accepted, duplicate + 1, seen}

          true ->
            {accepted + 1, duplicate, MapSet.put(seen, key)}
        end
      end)

    {accepted, duplicate}
  end

  defp note_key(%{source: source, guid: guid}) when is_binary(source) and is_binary(guid),
    do: {source, guid}

  defp note_key(_row), do: nil

  defp prepare_row(note, user_id, device_id, now) when is_map(note) do
    attrs = %{
      user_id: user_id,
      device_id: device_id,
      source: fetch(note, :source) || "notes",
      guid: fetch(note, :guid),
      local_id: fetch(note, :local_id),
      title: Maraithon.TextSanitize.scrub(fetch(note, :title)),
      snippet: Maraithon.TextSanitize.scrub(fetch(note, :snippet)),
      body: Maraithon.TextSanitize.scrub(fetch(note, :body)),
      body_format: fetch(note, :body_format) || "plain",
      folder: fetch(note, :folder),
      is_pinned: truthy?(fetch(note, :is_pinned)),
      created_at: parse_datetime(fetch(note, :created_at)),
      modified_at: parse_datetime(fetch(note, :modified_at)),
      encrypted_with_device_key: truthy?(fetch(note, :encrypted_with_device_key)),
      key_id: fetch(note, :key_id)
    }

    changeset = LocalNote.changeset(%LocalNote{}, attrs)

    if changeset.valid? do
      struct = Ecto.Changeset.apply_changes(changeset)

      row =
        LocalNote.__schema__(:fields)
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

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_other), do: false

  defp parse_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp matches_term?(%LocalNote{title: title, snippet: snippet, body: body}, needle) do
    haystack =
      [title, snippet, body]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.join(" ")

    String.contains?(haystack, needle)
  end

  defp enqueue_embed_jobs(_user_id, []), do: :ok

  defp enqueue_embed_jobs(user_id, inserted_rows) do
    if LocalEmbeddings.embedding_storage_available?("local_notes") do
      Enum.each(inserted_rows, fn
        %{id: id} when is_binary(id) -> EmbedJob.enqueue(user_id, id)
        %LocalNote{id: id} when is_binary(id) -> EmbedJob.enqueue(user_id, id)
        _ -> :ok
      end)
    end

    :ok
  end
end
