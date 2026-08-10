defmodule Maraithon.Runtime.Coordination.Backfill do
  @moduledoc "Bounded, resumable storage preparation for partition cutover."

  alias Ecto.Adapters.SQL
  alias Maraithon.Repo
  alias Maraithon.Runtime.Coordination.Protocol

  @max_batch 500

  def run_batch(limit \\ 100) when is_integer(limit) and limit in 1..@max_batch do
    Repo.transaction(fn ->
      case Protocol.mode() do
        :dark -> :ok
        other -> Repo.rollback({:coordination_backfill_requires_dark_mode, other})
      end

      background =
        SQL.query!(
          Repo,
          """
          WITH batch AS MATERIALIZED (
            SELECT id FROM public.background_jobs
            WHERE tenant_key IS NULL OR partition_id IS NULL
            ORDER BY inserted_at, id
            LIMIT $1 FOR UPDATE SKIP LOCKED
          )
          UPDATE public.background_jobs AS job
          SET tenant_key = CASE
                WHEN job.user_id IS NOT NULL AND btrim(job.user_id) <> '' THEN 'user:' || job.user_id
                WHEN job.telegram_bot_id IS NOT NULL AND btrim(job.telegram_bot_id) <> ''
                  THEN 'telegram:' || job.telegram_bot_id
                ELSE 'system:' || COALESCE(NULLIF(btrim(job.queue), ''), 'default')
              END,
              partition_id = public.runtime_partition_for(
                CASE
                  WHEN job.user_id IS NOT NULL AND btrim(job.user_id) <> '' THEN 'user:' || job.user_id
                  WHEN job.telegram_bot_id IS NOT NULL AND btrim(job.telegram_bot_id) <> ''
                    THEN 'telegram:' || job.telegram_bot_id
                  ELSE 'system:' || COALESCE(NULLIF(btrim(job.queue), ''), 'default')
                END),
              updated_at = timezone('UTC', clock_timestamp())
          FROM batch WHERE job.id = batch.id
          """,
          [limit]
        ).num_rows

      scheduled =
        SQL.query!(
          Repo,
          """
          WITH batch AS MATERIALIZED (
            SELECT job.id, agent.user_id
            FROM public.scheduled_jobs AS job
            JOIN public.agents AS agent ON agent.id = job.agent_id
            WHERE (job.tenant_key IS NULL OR job.partition_id IS NULL)
              AND agent.user_id IS NOT NULL
            ORDER BY job.inserted_at, job.id
            LIMIT $1 FOR UPDATE OF job SKIP LOCKED
          )
          UPDATE public.scheduled_jobs AS job
          SET tenant_key = 'user:' || batch.user_id,
              partition_id = public.runtime_partition_for('user:' || batch.user_id)
          FROM batch WHERE job.id = batch.id
          """,
          [limit]
        ).num_rows

      %{background_jobs: background, scheduled_jobs: scheduled}
    end)
  end

  def finalize do
    Repo.transaction(fn ->
      case Protocol.mode() do
        :dark -> :ok
        other -> Repo.rollback({:coordination_backfill_requires_dark_mode, other})
      end

      SQL.query!(Repo, "LOCK TABLE public.background_jobs IN SHARE MODE", [])
      SQL.query!(Repo, "LOCK TABLE public.scheduled_jobs IN SHARE MODE", [])

      case remaining() do
        {:ok, %{background_jobs: 0, scheduled_jobs: 0, unbackfillable_scheduled_jobs: 0}} -> :ok
        {:ok, counts} -> Repo.rollback({:coordination_backfill_incomplete, counts})
        {:error, reason} -> Repo.rollback(reason)
      end

      SQL.query!(
        Repo,
        "ALTER TABLE public.background_jobs VALIDATE CONSTRAINT background_jobs_partition_shape",
        []
      )

      SQL.query!(
        Repo,
        "ALTER TABLE public.scheduled_jobs VALIDATE CONSTRAINT scheduled_jobs_partition_shape",
        []
      )

      :finalized
    end)
  end

  def remaining do
    case SQL.query(
           Repo,
           """
           SELECT
             (SELECT count(*) FROM public.background_jobs
              WHERE tenant_key IS NULL OR partition_id IS NULL),
             (SELECT count(*) FROM public.scheduled_jobs
              WHERE tenant_key IS NULL OR partition_id IS NULL),
             (SELECT count(*) FROM public.scheduled_jobs AS job
              LEFT JOIN public.agents AS agent ON agent.id = job.agent_id
              WHERE (job.tenant_key IS NULL OR job.partition_id IS NULL)
                AND agent.user_id IS NULL)
           """,
           []
         ) do
      {:ok, %{rows: [[background, scheduled, unbackfillable]]}} ->
        {:ok,
         %{
           background_jobs: background,
           scheduled_jobs: scheduled,
           unbackfillable_scheduled_jobs: unbackfillable
         }}

      {:error, _} ->
        {:error, :coordination_backfill_unavailable}
    end
  end
end
