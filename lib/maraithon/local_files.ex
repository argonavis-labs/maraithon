defmodule Maraithon.LocalFiles do
  @moduledoc """
  Context for macOS files synced from a user's local machine. Owns
  bulk-insert with idempotent dedupe, recent lookups (with optional
  extension filter), in-memory substring search across filename + text
  content, single-record fetch, and per-device purges.

  Source coverage: files under `~/Documents`, `~/Desktop`, and
  `~/Downloads`. Privacy filters (Library/, dotfiles, .ssh/, etc.) are
  enforced client-side; this layer trusts the device payload.
  """

  import Ecto.Query

  require Logger

  alias Maraithon.LocalEmbeddings
  alias Maraithon.LocalFiles.EmbedJob
  alias Maraithon.LocalFiles.LocalFile
  alias Maraithon.LocalSearch
  alias Maraithon.Repo

  @max_text_bytes 200 * 1024

  @doc """
  Ingests a batch of file maps from a device for the given user.

  Each entry should be a string-keyed or atom-keyed map matching the
  payload defined in the companion spec. Inserts are idempotent via the
  `(user_id, device_id, source, guid)` unique constraint — re-sending
  the same payload is a no-op.

  Returns `{:ok, %{accepted: integer, duplicate: integer, invalid: integer}}`.
  """
  def ingest_batch(user_id, device_id, files)
      when is_binary(user_id) and is_list(files) do
    started_at = System.monotonic_time(:millisecond)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {prepared, invalid} =
      files
      |> Enum.map(&prepare_row(&1, user_id, device_id, now))
      |> Enum.split_with(&match?({:ok, _row}, &1))

    rows = Enum.map(prepared, fn {:ok, row} -> row end)

    {inserted_count, inserted_rows} =
      if rows == [] do
        {0, []}
      else
        Repo.insert_all(LocalFile, rows,
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
      [:maraithon, :companion, :files_ingested],
      %{
        count: length(files),
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

  def ingest_batch(_user_id, _device_id, _files), do: {:error, :invalid_batch}

  @doc """
  Returns the most recent files for a user, newest modified first.

  Options:

    * `:limit` — clamp result count (default 50)
    * `:extension` — restrict to a single extension (case-insensitive)
  """
  def recent_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 50)
    extension = normalize_extension(Keyword.get(opts, :extension))

    base =
      from file in LocalFile,
        where: file.user_id == ^user_id,
        order_by: [desc: file.modified_at],
        limit: ^limit

    query =
      if extension do
        from f in base, where: f.extension == ^extension
      else
        base
      end

    Repo.all(query)
  end

  @doc """
  Searches files for a user using a substring match on the encrypted
  `filename` and `text_content` fields and the plaintext `path`.
  Decrypts in memory and filters — fine for the device-bounded volumes
  we expect today.

  Options:

    * `:limit` — clamp result count (default 50)
    * `:extension` — restrict to a single extension
    * `:path_substring` — additionally require the (plaintext) `path`
      to contain this substring (case-insensitive)
  """
  def search(user_id, term, opts \\ [])
      when is_binary(user_id) and is_binary(term) do
    limit = Keyword.get(opts, :limit, 50)
    extension = normalize_extension(Keyword.get(opts, :extension))
    path_substring = optional_substring(Keyword.get(opts, :path_substring))
    query = LocalSearch.compile(term)

    user_id
    |> recent_for_user(limit: 500, extension: extension)
    |> Enum.filter(&matches_term?(&1, query, path_substring))
    |> Enum.take(limit)
  end

  @doc """
  Semantic search for files whose filename, path, or extracted text
  content is semantically similar to `query`. Pairs with `search/3`
  (substring) — use `semantic_search/3` when the user asks "find the
  PDF about something similar" or "what was that doc where I wrote
  about X" and won't recall an exact filename or words.

  Options:
    * `:limit` — max rows to return (default 12)
    * `:extension` — restrict to one file extension (e.g. "pdf")
    * `:path_substring` — additionally require `path` to contain this
  """
  def semantic_search(user_id, query, opts \\ [])

  def semantic_search(user_id, query, opts)
      when is_binary(user_id) and is_binary(query) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 12)
    pool_size = Keyword.get(opts, :pool_size, 200)
    extension = normalize_extension(Keyword.get(opts, :extension))
    path_substring = optional_substring(Keyword.get(opts, :path_substring))

    pool =
      user_id
      |> recent_for_user(limit: pool_size, extension: extension)
      |> Enum.filter(&path_filter?(&1, path_substring))

    Maraithon.LocalSemanticSearch.rank_by_similarity(
      pool,
      query,
      &file_text/1,
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

    case LocalEmbeddings.semantic_search("local_files", user_id, query_vector, opts) do
      [] ->
        []

      rows ->
        ids = Enum.map(rows, fn {id, _sim} -> id end)

        files =
          Repo.all(
            from file in LocalFile,
              where: file.user_id == ^user_id and file.id in ^ids
          )

        sim_by_id = Map.new(rows)

        files
        |> Enum.map(fn file -> {file, Map.get(sim_by_id, file.id, 0.0)} end)
        |> Enum.sort_by(fn {_file, sim} -> -sim end)
        |> Enum.take(limit)
    end
  end

  defp file_text(%LocalFile{filename: filename, path: path, text_content: text}) do
    [filename, path, text]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp path_filter?(_file, nil), do: true

  defp path_filter?(%LocalFile{path: path}, needle)
       when is_binary(path) and is_binary(needle) do
    String.contains?(String.downcase(path), needle)
  end

  defp path_filter?(_file, _needle), do: false

  @doc """
  Fetches one file for a user by its source GUID. Returns `nil` when
  no matching file exists.
  """
  def get_by_guid(user_id, guid) when is_binary(user_id) and is_binary(guid) do
    Repo.one(
      from file in LocalFile,
        where: file.user_id == ^user_id and file.guid == ^guid,
        limit: 1
    )
  end

  def get_by_guid(_user_id, _guid), do: nil

  @doc """
  Purges every file for a (user, device) pair. Returns
  `{:ok, %{deleted: count}}`.
  """
  def purge_device(user_id, device_id) when is_binary(user_id) do
    {deleted, _} =
      Repo.delete_all(
        from file in LocalFile,
          where: file.user_id == ^user_id and file.device_id == ^device_id
      )

    {:ok, %{deleted: deleted}}
  end

  @doc """
  Per-record text content cap (bytes after base64 decode).
  """
  def max_text_bytes, do: @max_text_bytes

  # -- internals ---------------------------------------------------------

  defp prepare_row(file, user_id, device_id, now) when is_map(file) do
    guid = fetch(file, :guid)

    {text_content, text_truncated} =
      decode_text(
        fetch(file, :text_content_base64) || fetch(file, :text_content),
        fetch(file, :text_truncated),
        user_id,
        device_id,
        guid
      )

    attrs = %{
      user_id: user_id,
      device_id: device_id,
      source: fetch(file, :source) || "files",
      guid: guid,
      local_id: fetch(file, :local_id),
      path: fetch(file, :path),
      filename: fetch(file, :filename),
      extension: normalize_extension(fetch(file, :extension)),
      mime_type: fetch(file, :mime_type),
      byte_size: parse_integer(fetch(file, :byte_size)),
      text_content: text_content,
      text_truncated: text_truncated,
      created_at: parse_datetime(fetch(file, :created_at)),
      modified_at: parse_datetime(fetch(file, :modified_at)),
      encrypted_with_device_key: truthy?(fetch(file, :encrypted_with_device_key)),
      key_id: fetch(file, :key_id)
    }

    changeset = LocalFile.changeset(%LocalFile{}, attrs)

    if changeset.valid? do
      struct = Ecto.Changeset.apply_changes(changeset)

      row =
        LocalFile.__schema__(:fields)
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

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(_), do: nil

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

  defp matches_term?(
         %LocalFile{filename: filename, text_content: text, path: path},
         query,
         path_substring
       ) do
    LocalSearch.matches?(query, [filename, text, path]) and
      (is_nil(path_substring) or
         (is_binary(path) and String.contains?(String.downcase(path), path_substring)))
  end

  defp matches_term?(_other, _needle, _path_substring), do: false

  defp normalize_extension(nil), do: nil

  defp normalize_extension(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed |> String.downcase() |> String.trim_leading(".")
    end
  end

  defp normalize_extension(_), do: nil

  defp optional_substring(nil), do: nil

  defp optional_substring(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp optional_substring(_), do: nil

  # Accepts extracted text as either base64 (the wire shape) or as a
  # raw string (helpful for tests + future internal callers). Honors a
  # `text_truncated` flag from the device — if the client already knows
  # it had to truncate, we drop the content and flag the row.
  defp decode_text(nil, truncated_flag, _user_id, _device_id, _guid) do
    {nil, !!truncated_flag}
  end

  defp decode_text("", truncated_flag, _user_id, _device_id, _guid) do
    {nil, !!truncated_flag}
  end

  defp decode_text(value, truncated_flag, user_id, device_id, guid)
       when is_binary(value) do
    case maybe_decode_base64(value) do
      {:ok, bytes} -> cap_text(bytes, !!truncated_flag, user_id, device_id, guid)
      :error -> {nil, !!truncated_flag}
    end
  end

  defp decode_text(_other, truncated_flag, _user_id, _device_id, _guid),
    do: {nil, !!truncated_flag}

  defp maybe_decode_base64(value) do
    cond do
      # Already raw text/bytes: keep as-is. We default to treating
      # printable strings as base64 only when they look base64-shaped,
      # since most file extracts are plain UTF-8.
      printable_text?(value) and not base64_shaped?(value) ->
        {:ok, value}

      true ->
        case Base.decode64(value, ignore: :whitespace) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> if printable_text?(value), do: {:ok, value}, else: :error
        end
    end
  end

  defp printable_text?(value) when is_binary(value), do: String.valid?(value)
  defp printable_text?(_), do: false

  # Cheap heuristic: a base64 payload is mostly alphanumerics + `+/=`
  # with no whitespace beyond optional newlines. Plain UTF-8 prose will
  # almost always contain spaces.
  defp base64_shaped?(value) when is_binary(value) do
    String.length(value) > 0 and
      Regex.match?(~r/\A[A-Za-z0-9+\/=\r\n]+\z/, value)
  end

  defp cap_text(bytes, truncated_flag, user_id, device_id, guid) do
    if byte_size(bytes) > @max_text_bytes do
      :telemetry.execute(
        [:maraithon, :companion, :files_text_truncated],
        %{bytes: byte_size(bytes)},
        %{user_id: user_id, device_id: device_id, guid: guid}
      )

      Logger.warning(
        "local_files text over cap, storing truncated",
        user_id: user_id,
        device_id: device_id,
        guid: guid,
        bytes: byte_size(bytes),
        cap: @max_text_bytes
      )

      {nil, true}
    else
      {bytes, truncated_flag}
    end
  end

  defp enqueue_embed_jobs(_user_id, []), do: :ok

  defp enqueue_embed_jobs(user_id, inserted_rows) do
    if LocalEmbeddings.embedding_storage_available?("local_files") do
      Enum.each(inserted_rows, fn
        %{id: id} when is_binary(id) -> EmbedJob.enqueue(user_id, id)
        %LocalFile{id: id} when is_binary(id) -> EmbedJob.enqueue(user_id, id)
        _ -> :ok
      end)
    end

    :ok
  end
end
