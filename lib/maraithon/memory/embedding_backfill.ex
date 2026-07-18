defmodule Maraithon.Memory.EmbeddingBackfill do
  @moduledoc """
  Lazy backfill for `memory_items.embedding` (SPEC 07 R2).

  New/updated memory items get an embedding on write via
  `Maraithon.Memory.Embedding.refresh_async/2`. Rows that predate the
  `embedding` column (or whose async write-time refresh failed) are picked up
  here instead of a standing cron: `enqueue_for_user/2` is cheap to call from
  hot write paths (dedupe key collapses concurrent enqueues per user), so a
  user's backlog drains the next time they have write traffic rather than
  requiring a dedicated scheduler. Recall works before backfill completes —
  `Recall.score/5` falls back to lexical matching for items without an
  embedding yet.
  """

  alias Maraithon.LocalEmbeddings
  alias Maraithon.Memory.Embedding
  alias Maraithon.Memory.Item
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs

  require Logger

  @job_type "memory_items_embedding_backfill"
  @queue "memory_embeddings"
  @default_limit 25

  @doc "Job type string that BackgroundJobHandler dispatches on."
  def job_type, do: @job_type

  @doc """
  Enqueue a bounded backfill sweep for `user_id`. Best-effort: failures to
  enqueue are logged, never raised. The dedupe key means calling this
  repeatedly (e.g. on every `Memory.write/3`) only ever keeps one active job
  per user.
  """
  def enqueue_for_user(user_id, opts \\ [])

  def enqueue_for_user(user_id, opts) when is_binary(user_id) do
    BackgroundJobs.enqueue(@job_type, %{
      "user_id" => user_id,
      "queue" => @queue,
      "payload" => %{"limit" => Keyword.get(opts, :limit, @default_limit)},
      "dedupe_key" => "#{@job_type}:#{user_id}"
    })
    |> handle_enqueue(user_id)
  rescue
    exception ->
      Logger.warning("memory_items_embedding_backfill enqueue crashed",
        user_id: user_id,
        reason: Exception.message(exception)
      )

      :ok
  end

  def enqueue_for_user(_user_id, _opts), do: :ok

  defp handle_enqueue({:ok, _job}, _user_id), do: :ok

  defp handle_enqueue({:error, reason}, user_id) do
    Logger.warning("memory_items_embedding_backfill enqueue failed",
      user_id: user_id,
      reason: inspect(reason)
    )

    :ok
  end

  @doc """
  Runs the backfill for up to `:limit` memory items missing an embedding.
  Returns `{:ok, %{refreshed:, skipped:, failed:}}`. Never raises — this is
  called from `BackgroundJobHandler.execute/1`.
  """
  def run_for_user(user_id, opts \\ [])

  def run_for_user(user_id, opts) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, @default_limit)

    if LocalEmbeddings.embedding_storage_available?(Embedding.table()) do
      user_id
      |> pending_ids(limit)
      |> Enum.reduce(%{refreshed: 0, skipped: 0, failed: 0}, fn id, acc ->
        case refresh_one(id, opts) do
          :refreshed -> Map.update!(acc, :refreshed, &(&1 + 1))
          :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
          :failed -> Map.update!(acc, :failed, &(&1 + 1))
        end
      end)
      |> then(&{:ok, &1})
    else
      {:ok, %{refreshed: 0, skipped: 0, failed: 0, reason: "pgvector_unavailable"}}
    end
  end

  def run_for_user(_user_id, _opts), do: {:error, :invalid_user}

  defp refresh_one(id, opts) do
    case Repo.get(Item, id) do
      nil ->
        :skipped

      %Item{} = item ->
        case Embedding.refresh(item, opts) do
          {:ok, :stored} ->
            :refreshed

          {:ok, _other} ->
            :skipped

          {:error, reason} ->
            Logger.warning("memory item embedding backfill failed",
              memory_id: id,
              reason: inspect(reason)
            )

            :failed
        end
    end
  rescue
    error ->
      Logger.warning("memory item embedding backfill crashed",
        memory_id: id,
        reason: Exception.message(error)
      )

      :failed
  end

  defp pending_ids(user_id, limit) do
    table = Embedding.table()

    %{rows: rows} =
      Repo.query!(
        "SELECT id FROM #{table} WHERE user_id = $1 AND status = 'active' " <>
          "AND embedding IS NULL ORDER BY updated_at DESC LIMIT $2",
        [user_id, limit]
      )

    Enum.flat_map(rows, fn [id] ->
      case Ecto.UUID.load(id) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
  rescue
    _error -> []
  end
end
