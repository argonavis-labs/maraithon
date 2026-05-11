defmodule Maraithon.LocalEmbeddings do
  @moduledoc """
  Shared helpers for storing and querying pgvector embeddings on the local
  content tables (`local_messages`, `local_notes`, `local_voice_memos`,
  `local_calendar_events`, `local_reminders`, `local_files`).

  Embeddings are written through raw SQL because the per-source schemas
  intentionally do not declare the `embedding` column as an Ecto field —
  that keeps the existing changeset / insert_all paths working on
  environments that haven't been upgraded to pgvector yet.

  All write helpers no-op (and `semantic_search/4` returns `[]`) when the
  embedding column isn't present on the target table, so the rest of the
  system keeps working without semantic recall until the extension is
  installed.
  """

  alias Maraithon.LLM.Embeddings
  alias Maraithon.Repo

  require Logger

  @type source_record :: %{
          required(:id) => binary(),
          required(:text) => String.t() | nil
        }

  @doc """
  Stable hash of the text that produced an embedding. Used so embed jobs
  can skip recomputing when nothing changed.
  """
  def source_hash(nil), do: nil
  def source_hash(""), do: nil

  def source_hash(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  def source_hash(_other), do: nil

  @doc """
  Computes an embedding and writes it to the row in `table` with `id`.

  Returns `{:ok, :stored}`, `{:ok, :unchanged}`, `{:ok, :empty}`,
  `{:ok, :pgvector_unavailable}`, `{:ok, :not_found}`, or `{:error, reason}`.

  When the underlying embedding call fails we surface `{:error, reason}` so
  the background job runner can retry; we never raise.
  """
  def refresh(table, id, text, opts \\ [])

  def refresh(table, id, text, opts)
      when is_binary(table) and is_binary(id) do
    normalized_text = normalize_text(text)
    hash = source_hash(normalized_text)
    force? = Keyword.get(opts, :force, false)

    cond do
      normalized_text in [nil, ""] ->
        {:ok, :empty}

      not embedding_storage_available?(table) ->
        {:ok, :pgvector_unavailable}

      true ->
        case current_hash(table, id) do
          :not_found ->
            {:ok, :not_found}

          current when not force? and current == hash ->
            {:ok, :unchanged}

          _other ->
            do_embed_and_store(table, id, normalized_text, hash, opts)
        end
    end
  end

  def refresh(_table, _id, _text, _opts), do: {:error, :invalid_args}

  defp do_embed_and_store(table, id, text, hash, opts) do
    case safe_embed(text, opts) do
      {:ok, vector} ->
        store(table, id, vector, hash)

      {:error, reason} ->
        Logger.warning("local embedding refresh failed",
          table: table,
          id: id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp safe_embed(text, opts) do
    Embeddings.embed(text, opts)
  rescue
    error ->
      {:error, Exception.message(error)}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp store(table, id, vector, hash) do
    pgvector = Pgvector.new(vector)
    now = DateTime.utc_now()

    sql = """
    UPDATE #{table}
    SET embedding = $1::vector,
        embedding_source_hash = $2,
        embedding_refreshed_at = $3
    WHERE id = $4
    """

    case Repo.query(sql, [pgvector, hash, now, Ecto.UUID.dump!(id)]) do
      {:ok, %{num_rows: 1}} ->
        {:ok, :stored}

      {:ok, %{num_rows: 0}} ->
        {:ok, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the top-k rows from `table` whose embedding is most similar
  (cosine) to `query_vector`, restricted to the given `user_id`. Each row is
  returned as `{id, similarity}` where similarity is in `[-1, 1]` (typically
  `[0, 1]` for embeddings).

  Opts:
    * `:limit` — max rows to return (default 10)
    * `:min_similarity` — discard rows below this similarity (default 0.0)
  """
  def semantic_search(table, user_id, query_vector, opts \\ [])

  def semantic_search(table, user_id, query_vector, opts)
      when is_binary(table) and is_binary(user_id) and is_list(query_vector) do
    limit = Keyword.get(opts, :limit, 10)
    min_similarity = Keyword.get(opts, :min_similarity, 0.0)

    if embedding_storage_available?(table) do
      pgvector = Pgvector.new(query_vector)

      sql = """
      SELECT id, 1 - (embedding <=> $1::vector) AS similarity
      FROM #{table}
      WHERE user_id = $2 AND embedding IS NOT NULL
      ORDER BY embedding <=> $1::vector
      LIMIT $3
      """

      case Repo.query(sql, [pgvector, user_id, limit]) do
        {:ok, %{rows: rows}} ->
          rows
          |> Enum.map(fn [uuid_bin, similarity] ->
            {:ok, uuid} = Ecto.UUID.load(uuid_bin)
            {uuid, ensure_float(similarity)}
          end)
          |> Enum.filter(fn {_id, sim} -> sim >= min_similarity end)

        {:error, reason} ->
          Logger.warning("local semantic_search failed",
            table: table,
            user_id: user_id,
            reason: inspect(reason)
          )

          []
      end
    else
      []
    end
  end

  def semantic_search(_table, _user_id, _vector, _opts), do: []

  @doc """
  Quick check whether the `embedding` column exists on a given table.

  We cache the result in the process dictionary because the lookup runs
  inside hot paths (every ingest call + every semantic_search call).
  """
  def embedding_storage_available?(table) when is_binary(table) do
    key = {:maraithon_pgvector_available, table}

    case Process.get(key) do
      nil ->
        available = check_column_present(table)
        Process.put(key, available)
        available

      cached when is_boolean(cached) ->
        cached
    end
  end

  @doc """
  Invalidate the cached column presence check. Tests use this so that a
  fresh migration becomes visible inside the same process.
  """
  def reset_storage_cache!(table) when is_binary(table) do
    Process.delete({:maraithon_pgvector_available, table})
    :ok
  end

  def reset_storage_cache! do
    Process.get_keys()
    |> Enum.filter(fn
      {:maraithon_pgvector_available, _} -> true
      _ -> false
    end)
    |> Enum.each(&Process.delete/1)

    :ok
  end

  defp check_column_present(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns " <>
          "WHERE table_name = $1 AND column_name = 'embedding'",
        [table]
      )

    rows != []
  rescue
    _ -> false
  end

  defp current_hash(table, id) do
    if embedding_storage_available?(table) do
      sql = "SELECT embedding_source_hash FROM #{table} WHERE id = $1"

      case Repo.query(sql, [Ecto.UUID.dump!(id)]) do
        {:ok, %{rows: [[hash]]}} -> hash
        {:ok, %{rows: []}} -> :not_found
        _ -> nil
      end
    else
      nil
    end
  end

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_other), do: nil

  defp ensure_float(value) when is_float(value), do: value
  defp ensure_float(value) when is_integer(value), do: value * 1.0
  defp ensure_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp ensure_float(_other), do: 0.0
end
