defmodule Maraithon.Runtime.Coordination.FairScheduler do
  @moduledoc "Deterministic PostgreSQL tenant fairness and bounded rate admission."

  alias Ecto.Adapters.SQL
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.Coordination.{NodeIncarnation, TaskClaims, TaskSupervisor}

  @microunits 1_000_000

  def reserve_next(%NodeIncarnation{} = session, partitions, opts \\ [])
      when is_list(partitions) do
    max_attempts = Keyword.get(opts, :conflict_attempts, 8) |> min(32) |> max(1)
    task_ttl_ms = Keyword.get(opts, :task_ttl_ms, 30_000)
    do_reserve(session, partitions, task_ttl_ms, max_attempts)
  end

  def activate_job(%BackgroundJob{} = job, assignment) do
    Repo.transaction(fn ->
      assignment = unwrap!(TaskClaims.activate(assignment))
      set_task_action!(assignment.id)

      result =
        SQL.query!(
          Repo,
          """
          UPDATE public.background_jobs
          SET status = 'running', updated_at = timezone('UTC', clock_timestamp())
          WHERE id = $1::uuid AND status = 'pending' AND claim_token = $2::uuid
            AND coordination_task_assignment_id = $3::uuid
          RETURNING id, user_id, queue, job_type, payload, status, dedupe_key,
                    telegram_bot_id, telegram_update_id, attempts, max_attempts,
                    scheduled_at, claimed_by, claimed_at, claim_token, completed_at,
                    failed_at, cancelled_at, result, last_error, tenant_key, partition_id,
                    coordination_activation_epoch, coordination_partition_epoch,
                    coordination_node_incarnation_id, coordination_task_assignment_id,
                    coordination_task_supervisor_id, coordination_local_task_id,
                    inserted_at, updated_at
          """,
          [
            Ecto.UUID.dump!(job.id),
            Ecto.UUID.dump!(assignment.claim_token),
            Ecto.UUID.dump!(assignment.id)
          ]
        )

      {load_job!(result), assignment}
    end)
  end

  def configure_tenant(tenant_key, opts) when is_binary(tenant_key) and is_list(opts) do
    max_concurrency = Keyword.fetch!(opts, :max_concurrency)
    rate = Keyword.fetch!(opts, :rate_per_minute)
    burst = Keyword.fetch!(opts, :burst)

    if max_concurrency in 1..64 and rate in 1..100_000 and burst in 1..10_000 do
      SQL.query(
        Repo,
        """
        UPDATE public.runtime_tenant_fairness
        SET max_concurrency = $2, rate_per_minute = $3, burst = $4,
            available_microunits = LEAST(available_microunits, $4::bigint * #{@microunits}),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE tenant_key = $1
        """,
        [tenant_key, max_concurrency, rate, burst]
      )
    else
      {:error, :invalid_tenant_quota}
    end
  end

  defp do_reserve(_session, [], _ttl, _attempts), do: {:ok, nil}
  defp do_reserve(_session, _partitions, _ttl, 0), do: {:error, :fair_claim_conflict_limit}

  defp do_reserve(session, partitions, task_ttl_ms, attempts) do
    result = Repo.transaction(fn -> reserve_locked(session, partitions, task_ttl_ms) end)

    case result do
      {:ok, value} -> {:ok, value}
      {:error, :fair_claim_conflict} -> do_reserve(session, partitions, task_ttl_ms, attempts - 1)
      other -> other
    end
  end

  defp reserve_locked(session, partitions, task_ttl_ms) do
    partition_ids = Enum.map(partitions, & &1.partition_id)
    partition_epochs = Enum.map(partitions, & &1.ownership_epoch)
    ensure_tenants!(session, partition_ids, partition_epochs)

    case candidate(session, partition_ids, partition_epochs) do
      nil -> nil
      candidate -> reserve_candidate!(session, candidate, task_ttl_ms)
    end
  end

  defp candidate(session, ids, epochs) do
    result =
      SQL.query!(
        Repo,
        """
        WITH owned(partition_id, partition_epoch) AS (
          SELECT * FROM unnest($1::smallint[], $2::bigint[])
        ), active_tenants AS MATERIALIZED (
          SELECT job.tenant_key, count(*)::integer AS active_count
          FROM public.runtime_task_assignments AS assignment
          JOIN public.background_jobs AS job ON job.id = assignment.work_id
          WHERE assignment.work_kind = 'background_job'
            AND assignment.state IN ('reserved', 'running', 'termination_requested', 'termination_proven')
          GROUP BY job.tenant_key
        ), candidates AS MATERIALIZED (
          SELECT job.id, job.tenant_key, job.partition_id, owned.partition_epoch,
                 tenant.max_concurrency, tenant.rate_per_minute, tenant.burst,
                 LEAST(tenant.burst::bigint * #{@microunits},
                   tenant.available_microunits + GREATEST(
                     floor(EXTRACT(EPOCH FROM
                       (timezone('UTC', clock_timestamp()) - tenant.refilled_at)) *
                       tenant.rate_per_minute * #{@microunits} / 60)::bigint, 0
                   )) AS refilled_tokens,
                 tenant.last_served_sequence, job.scheduled_at, job.inserted_at
          FROM public.background_jobs AS job
          JOIN owned ON owned.partition_id = job.partition_id
          JOIN public.runtime_partitions AS partition
            ON partition.partition_id = owned.partition_id
           AND partition.ownership_epoch = owned.partition_epoch
           AND partition.owner_node_incarnation_id = $3::uuid
           AND partition.activation_epoch = $4::uuid
           AND partition.state = 'ready' AND partition.ready_at IS NOT NULL
           AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
          JOIN public.runtime_tenant_fairness AS tenant ON tenant.tenant_key = job.tenant_key
          LEFT JOIN active_tenants AS active ON active.tenant_key = job.tenant_key
          WHERE job.status = 'pending'
            AND job.scheduled_at <= timezone('UTC', clock_timestamp())
            AND job.claim_token IS NULL
            AND NOT EXISTS (
              SELECT 1 FROM public.runtime_task_assignments AS existing
              WHERE existing.work_kind = 'background_job' AND existing.work_id = job.id
                AND existing.state IN ('reserved', 'running', 'termination_requested', 'termination_proven')
            )
            AND COALESCE(active.active_count, 0) < tenant.max_concurrency
            AND LEAST(tenant.burst::bigint * #{@microunits},
                  tenant.available_microunits + GREATEST(
                    floor(EXTRACT(EPOCH FROM
                      (timezone('UTC', clock_timestamp()) - tenant.refilled_at)) *
                      tenant.rate_per_minute * #{@microunits} / 60)::bigint, 0
                  )) >= #{@microunits}
            AND (job.job_type <> 'telegram_webhook_event' OR job.id = (
              SELECT head.id FROM public.background_jobs AS head
              WHERE head.job_type = 'telegram_webhook_event'
                AND head.telegram_bot_id = job.telegram_bot_id
                AND head.status IN ('pending', 'running')
              ORDER BY (head.status = 'running') DESC, head.telegram_update_id, head.id
              LIMIT 1
            ))
          ORDER BY tenant.last_served_sequence, tenant.tenant_key,
                   job.scheduled_at, job.inserted_at, job.id
          LIMIT 1
        )
        SELECT candidate.id, candidate.tenant_key, candidate.partition_id,
               candidate.partition_epoch, candidate.refilled_tokens
        FROM candidates AS candidate
        JOIN public.runtime_tenant_fairness AS tenant ON tenant.tenant_key = candidate.tenant_key
        JOIN public.background_jobs AS job ON job.id = candidate.id
        FOR UPDATE OF tenant, job SKIP LOCKED
        """,
        [ids, epochs, Ecto.UUID.dump!(session.id), Ecto.UUID.dump!(session.activation_epoch)]
      )

    case result.rows do
      [[id, tenant_key, partition_id, epoch, tokens]] ->
        %{
          id: Ecto.UUID.load!(id),
          tenant_key: tenant_key,
          partition_id: partition_id,
          ownership_epoch: epoch,
          refilled_tokens: tokens
        }

      [] ->
        nil
    end
  end

  defp reserve_candidate!(session, candidate, task_ttl_ms) do
    claim_token = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()

    case TaskSupervisor.reserve("background_job", candidate.id, claim_token, assignment_id) do
      {:ok, physical} ->
        partition = %{
          partition_id: candidate.partition_id,
          ownership_epoch: candidate.ownership_epoch
        }

        identity =
          Map.merge(physical, %{
            work_kind: "background_job",
            work_id: candidate.id,
            claim_token: claim_token,
            assignment_id: assignment_id
          })

        try do
          assignment =
            unwrap!(TaskClaims.reserve(session, partition, identity, ttl_ms: task_ttl_ms))

          set_task_action!(assignment.id)

          result =
            SQL.query!(
              Repo,
              """
              UPDATE public.background_jobs
              SET claimed_by = $2, claimed_at = timezone('UTC', clock_timestamp()),
                  claim_token = $3::uuid, coordination_activation_epoch = $4::uuid,
                  coordination_partition_epoch = $5,
                  coordination_node_incarnation_id = $6::uuid,
                  coordination_task_assignment_id = $7::uuid,
                  coordination_task_supervisor_id = $8::uuid,
                  coordination_local_task_id = $9::uuid,
                  updated_at = timezone('UTC', clock_timestamp())
              WHERE id = $1::uuid AND status = 'pending' AND claim_token IS NULL
              RETURNING id, user_id, queue, job_type, payload, status, dedupe_key,
                        telegram_bot_id, telegram_update_id, attempts, max_attempts,
                        scheduled_at, claimed_by, claimed_at, claim_token, completed_at,
                        failed_at, cancelled_at, result, last_error, tenant_key, partition_id,
                        coordination_activation_epoch, coordination_partition_epoch,
                        coordination_node_incarnation_id, coordination_task_assignment_id,
                        coordination_task_supervisor_id, coordination_local_task_id,
                        inserted_at, updated_at
              """,
              [
                Ecto.UUID.dump!(candidate.id),
                Atom.to_string(node()),
                Ecto.UUID.dump!(claim_token),
                Ecto.UUID.dump!(session.activation_epoch),
                candidate.ownership_epoch,
                Ecto.UUID.dump!(session.id),
                Ecto.UUID.dump!(assignment.id),
                Ecto.UUID.dump!(physical.supervisor_id),
                Ecto.UUID.dump!(physical.local_task_id)
              ]
            )

          if result.num_rows != 1, do: Repo.rollback(:fair_claim_conflict)

          [[sequence]] =
            SQL.query!(
              Repo,
              """
              UPDATE public.runtime_partitions
              SET fair_sequence = fair_sequence + 1,
                  updated_at = timezone('UTC', clock_timestamp())
              WHERE partition_id = $1 AND ownership_epoch = $2
              RETURNING fair_sequence
              """,
              [candidate.partition_id, candidate.ownership_epoch]
            ).rows

          SQL.query!(
            Repo,
            """
            UPDATE public.runtime_tenant_fairness
            SET available_microunits = $2 - #{@microunits},
                refilled_at = timezone('UTC', clock_timestamp()),
                last_served_sequence = $3, served_count = served_count + 1,
                updated_at = timezone('UTC', clock_timestamp())
            WHERE tenant_key = $1
            """,
            [candidate.tenant_key, candidate.refilled_tokens, sequence]
          )

          {load_job!(result), assignment, identity}
        catch
          kind, reason ->
            _ = TaskSupervisor.release(identity)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, reason} ->
        Repo.rollback({:task_supervisor_reservation_failed, reason})
    end
  end

  defp ensure_tenants!(session, ids, epochs) do
    SQL.query!(
      Repo,
      """
      WITH owned(partition_id, partition_epoch) AS (
        SELECT * FROM unnest($1::smallint[], $2::bigint[])
      )
      INSERT INTO public.runtime_tenant_fairness
        (tenant_key, partition_id, max_concurrency, rate_per_minute, burst,
         available_microunits, refilled_at, last_served_sequence, served_count,
         inserted_at, updated_at)
      SELECT DISTINCT job.tenant_key, job.partition_id, 1, 60, 10, 10000000,
             timezone('UTC', clock_timestamp()), 0, 0,
             timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
      FROM public.background_jobs AS job
      JOIN owned ON owned.partition_id = job.partition_id
      JOIN public.runtime_partitions AS partition
        ON partition.partition_id = owned.partition_id
       AND partition.ownership_epoch = owned.partition_epoch
       AND partition.owner_node_incarnation_id = $3::uuid
       AND partition.activation_epoch = $4::uuid
       AND partition.state = 'ready'
       AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
      WHERE job.status = 'pending'
      ON CONFLICT (tenant_key) DO NOTHING
      """,
      [ids, epochs, Ecto.UUID.dump!(session.id), Ecto.UUID.dump!(session.activation_epoch)]
    )
  end

  defp load_job!(%{columns: columns, rows: [row]}),
    do: Repo.load(BackgroundJob, {columns, decode_payload(columns, row)})

  defp load_job!(_), do: Repo.rollback(:fair_claim_conflict)

  defp decode_payload(columns, row) do
    Enum.reduce(["payload", "result"], row, fn field, acc ->
      case Enum.find_index(columns, &(&1 == field)) do
        nil ->
          acc

        index ->
          case Enum.at(acc, index) do
            value when is_binary(value) -> List.replace_at(acc, index, Jason.decode!(value))
            _ -> acc
          end
      end
    end)
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
  defp unwrap!(value), do: value

  defp set_task_action!(id),
    do: SQL.query!(Repo, "SELECT set_config('maraithon.runtime_task_action', $1, true)", [id])
end
