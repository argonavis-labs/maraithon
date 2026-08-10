defmodule Maraithon.DurablePayloadContraction do
  @moduledoc """
  Authoritative stopped-fleet boundary for irreversible durable-payload contraction.

  Every contraction batch runs as the externally provisioned activation role,
  locks the attested legacy protocol row and the closed payload registry, and
  proves that both legacy and partition-coordinated runtime work are drained.
  Reports and errors contain counts and closed classes only.
  """

  alias Maraithon.DurablePayloadRegistry
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Repo

  @confirmation "NON_ROLLING_FLEET_DRAINED"
  @marker "STOPPED_FLEET_EVIDENCE_V1"
  @revision_regex ~r/^[0-9a-f]{40}([0-9a-f]{24})?$/
  @max_timeout 180_000

  @coordination_tables ~w(
    agent_runtime_leases
    runtime_node_incarnations
    runtime_leader_authorities
    runtime_partitions
    runtime_partition_transitions
    runtime_task_assignments
    runtime_partition_rebalance_requests
  )

  @doc "Runs one contraction batch behind the authoritative stopped-fleet barrier."
  def transaction(opts, fun) when is_list(opts) and is_function(fun, 0) do
    with {:ok, evidence} <- evidence(opts) do
      case Repo.transaction(
             fn ->
               assume_activation_role!()
               lock_and_verify_evidence!(evidence)
               lock_payload_registry!()
               lock_coordination_authority!()
               assert_stopped_fleet!()
               assert_work_drained!()
               set_marker!()
               fun.()
             end,
             timeout: @max_timeout
           ) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    _error -> {:error, :durable_payload_contraction_failed}
  catch
    :exit, _reason -> {:error, :durable_payload_contraction_failed}
  end

  def transaction(_opts, _fun), do: {:error, :stopped_fleet_evidence_required}

  @doc false
  def require_authorized! do
    case Repo.query!(
           """
           SELECT current_user,
                  current_setting('maraithon.payload_contraction', true),
                  mode
           FROM public.effect_execution_protocols
           WHERE name = 'effects'
           FOR SHARE
           """,
           [],
           log: false
         ).rows do
      [["maraithon_activation_operator", @marker, "legacy"]] -> :ok
      _invalid -> Repo.rollback(:authoritative_payload_contraction_required)
    end
  end

  @doc "Returns content-free canonical in-flight counts for operator diagnostics."
  def work_preflight do
    counts = work_counts!()
    Map.put(counts, :total, counts |> Map.values() |> Enum.sum())
  rescue
    _error -> %{error: :durable_payload_contraction_preflight_failed}
  end

  defp evidence(opts) do
    confirmation = Keyword.get(opts, :confirmation)
    id = Keyword.get(opts, :evidence_id)
    digest = Keyword.get(opts, :evidence_digest)
    operator = Keyword.get(opts, :operator)
    revision = Keyword.get(opts, :revision)

    if Keyword.keyword?(opts) and confirmation == @confirmation and is_binary(id) and
         byte_size(id) in 1..256 and is_binary(digest) and byte_size(digest) == 32 and
         is_binary(operator) and byte_size(operator) in 1..320 and
         is_binary(revision) and Regex.match?(@revision_regex, revision) do
      {:ok, %{id: id, digest: digest, operator: operator, revision: revision}}
    else
      {:error, :stopped_fleet_evidence_required}
    end
  end

  defp assume_activation_role! do
    Repo.query!("SET LOCAL ROLE maraithon_activation_operator", [], log: false)

    case Repo.query!("SELECT current_user", [], log: false).rows do
      [["maraithon_activation_operator"]] -> :ok
      _invalid -> Repo.rollback(:activation_operator_credential_required)
    end
  end

  defp lock_and_verify_evidence!(evidence) do
    case Repo.query!(
           """
           SELECT mode, activation_evidence_id, activation_evidence_digest,
                  activated_by, exact_revision
           FROM public.effect_execution_protocols
           WHERE name = 'effects'
           FOR UPDATE
           """,
           [],
           log: false
         ).rows do
      [["legacy", id, digest, operator, revision]]
      when id == evidence.id and digest == evidence.digest and operator == evidence.operator and
             revision == evidence.revision ->
        :ok

      _invalid ->
        Repo.rollback(:stopped_fleet_evidence_mismatch)
    end
  end

  defp lock_payload_registry! do
    Enum.each(DurablePayloadRegistry.tables(), fn table ->
      Repo.query!("LOCK TABLE public.#{table} IN SHARE ROW EXCLUSIVE MODE", [], log: false)
    end)
  end

  defp lock_coordination_authority! do
    Enum.each(@coordination_tables, fn table ->
      Repo.query!("LOCK TABLE public.#{table} IN SHARE MODE", [], log: false)
    end)
  end

  defp assert_stopped_fleet! do
    case Repo.query!("SELECT COUNT(*) FROM public.agent_runtime_leases", [], log: false).rows do
      [[0]] -> :ok
      [[count]] -> Repo.rollback({:runtime_workers_require_drain, count})
    end
  end

  defp assert_work_drained! do
    counts = work_counts!()
    total = counts |> Map.values() |> Enum.sum()

    if total == 0,
      do: :ok,
      else: Repo.rollback({:durable_payload_contraction_requires_drain, total})
  end

  defp work_counts! do
    case Repo.query!(work_counts_sql(), [], log: false).rows do
      [row] ->
        keys = [
          :directives,
          :run_steps,
          :effects,
          :agent_runs,
          :assistant_runs,
          :assistant_steps,
          :prepared_actions,
          :background_jobs,
          :scheduled_jobs,
          :work_results,
          :coordination_nodes,
          :coordination_leaders,
          :coordination_partitions,
          :coordination_transitions,
          :coordination_assignments,
          :coordination_rebalances
        ]

        keys |> Enum.zip(row) |> Map.new()
    end
  end

  defp work_counts_sql do
    """
    SELECT
      (SELECT COUNT(*) FROM public.agent_directives
       WHERE status IN ('pending', 'processing')),
      (SELECT COUNT(*) FROM public.agent_run_steps WHERE status = 'requested'),
      (SELECT COUNT(*) FROM public.effects
       WHERE status IN ('pending', 'claimed', 'cancelling')),
      (SELECT COUNT(*) FROM public.agent_runs WHERE status = 'running'),
      (SELECT COUNT(*) FROM public.telegram_assistant_runs
       WHERE status IN ('queued', 'running', 'waiting_confirmation')),
      (SELECT COUNT(*) FROM public.telegram_assistant_steps WHERE status = 'running'),
      (SELECT COUNT(*) FROM public.telegram_prepared_actions
       WHERE status IS NULL OR status NOT IN ('executed', 'rejected', 'expired', 'failed')),
      (SELECT COUNT(*) FROM public.background_jobs WHERE status IN ('pending', 'running')),
      (SELECT COUNT(*) FROM public.scheduled_jobs WHERE status IN ('pending', 'dispatched')),
      (SELECT COUNT(*) FROM public.agent_work_results WHERE status = 'provisional'),
      (SELECT COUNT(*) FROM public.runtime_node_incarnations WHERE state <> 'revoked'),
      (SELECT COUNT(*) FROM public.runtime_leader_authorities WHERE state <> 'unassigned'),
      (SELECT COUNT(*) FROM public.runtime_partitions WHERE state <> 'unassigned'),
      (SELECT COUNT(*) FROM public.runtime_partition_transitions WHERE state <> 'completed'),
      (SELECT COUNT(*) FROM public.runtime_task_assignments
       WHERE state IN ('reserved', 'running', 'termination_requested', 'termination_proven')),
      (SELECT COUNT(*) FROM public.runtime_partition_rebalance_requests WHERE state = 'pending')
    """
  end

  defp set_marker! do
    Repo.query!(
      "SELECT set_config('maraithon.payload_contraction', $1, true)",
      [@marker],
      log: false
    )

    :ok = ProtocolCutover.require_legacy_mutation!()
  end
end
