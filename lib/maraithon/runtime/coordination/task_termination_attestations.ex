defmodule Maraithon.Runtime.Coordination.TaskTerminationAttestations do
  @moduledoc """
  Records separately authorized external physical-termination proof for one
  exact coordinated background-job Task assignment.

  Use only when independent infrastructure evidence proves that the node
  incarnation which owned the assignment can no longer execute, and its
  original TaskGuardian proof is permanently unavailable. The canonical case is
  a provider-entered recurring job caught mid-flight by a Cloud Run revision
  replacement: the assignment stays `termination_requested`, the planner keeps
  its partition `draining`, and every job on that partition is frozen.

  The operator confirmation is a deliberate-action interlock, not an
  authorization secret. Production authorization comes from the
  incident-operator database role, the only role granted INSERT on
  `runtime_task_termination_proofs`.

  This proves only physical destruction. It never claims a provider outcome:
  ordinary runtime reconciliation (`TaskClaims.reconcile_proven/1`) later
  settles the assignment as `provider_outcome_ambiguous` or
  `cancelled_before_provider`, releases the job, and lets the planner move the
  partition.
  """

  alias Ecto.Adapters.SQL
  alias Maraithon.Repo
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol
  alias Maraithon.Runtime.Coordination.{TaskAssignment, TaskClaims}

  @confirmation "PHYSICAL_TASK_TERMINATED"
  @work_kind "background_job"
  @identity_keys [
    :assignment_id,
    :job_id,
    :claim_token,
    :node_incarnation_id,
    :supervisor_id,
    :task_id
  ]

  def confirmation, do: @confirmation

  @doc """
  Records an `external_destroyed` proof for the exact assignment identity.

  Returns `{:ok, %{task_assignment: assignment}}` with the assignment in
  `termination_proven` (or its already-reconciled successor state when the
  identical attestation is replayed). Every identity field must match the
  stored assignment exactly; a mismatch, a different evidence reference on an
  already-proven assignment, or an assignment that is not awaiting termination
  proof is refused without writing anything.
  """
  def record(identity, evidence_id, attested_by, confirmation)
      when is_map(identity) and is_binary(evidence_id) and is_binary(attested_by) do
    with :ok <- confirm(confirmation),
         {:ok, identity} <- validate_identity(identity),
         :ok <- validate_text(evidence_id, 256),
         :ok <- validate_text(attested_by, 320) do
      Repo.transaction(fn ->
        activation_epoch = CoordinationProtocol.locked_active!()
        assignment = load_exact_assignment!(identity, activation_epoch)
        %{task_assignment: prove!(assignment, evidence_id, attested_by)}
      end)
    end
  rescue
    _error in [Postgrex.Error, Ecto.ConstraintError] ->
      {:error, :task_termination_attestation_refused}
  catch
    :exit, _reason -> {:error, :task_termination_attestation_storage_unavailable}
  end

  def record(_identity, _evidence_id, _attested_by, _confirmation),
    do: {:error, :invalid_task_termination_attestation}

  defp confirm(@confirmation), do: :ok
  defp confirm(_other), do: {:error, :task_termination_attestation_confirmation_required}

  defp validate_identity(identity) do
    Enum.reduce_while(@identity_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Ecto.UUID.cast(Map.get(identity, key)) do
        {:ok, uuid} -> {:cont, {:ok, Map.put(acc, key, uuid)}}
        :error -> {:halt, {:error, :invalid_task_termination_attestation}}
      end
    end)
  end

  defp validate_text(value, max) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and byte_size(value) <= max and String.valid?(value),
      do: :ok,
      else: {:error, :invalid_task_termination_attestation}
  end

  defp load_exact_assignment!(identity, activation_epoch) do
    case TaskClaims.get(identity.assignment_id) do
      %TaskAssignment{} = assignment ->
        expected = %{
          work_kind: @work_kind,
          activation_epoch: activation_epoch,
          work_id: identity.job_id,
          claim_token: identity.claim_token,
          node_incarnation_id: identity.node_incarnation_id,
          supervisor_id: identity.supervisor_id,
          local_task_id: identity.task_id
        }

        if Map.take(assignment, Map.keys(expected)) == expected,
          do: assignment,
          else: Repo.rollback(:task_termination_attestation_identity_mismatch)

      nil ->
        Repo.rollback(:task_termination_attestation_assignment_missing)
    end
  end

  defp prove!(%TaskAssignment{state: state} = assignment, evidence_id, attested_by)
       when state in ["reserved", "termination_requested"] do
    case TaskClaims.record_external_termination(assignment, evidence_id, attested_by) do
      {:ok, %TaskAssignment{state: "termination_proven"} = proven} -> proven
      {:error, reason} -> Repo.rollback(reason)
      _lost -> Repo.rollback(:task_external_proof_lost)
    end
  end

  defp prove!(%TaskAssignment{state: state} = assignment, evidence_id, _attested_by)
       when state in ["termination_proven", "settled", "outcome_ambiguous"] do
    if matching_external_proof?(assignment, evidence_id),
      do: assignment,
      else: Repo.rollback(:task_external_proof_mismatch)
  end

  defp prove!(_assignment, _evidence_id, _attested_by),
    do: Repo.rollback(:task_external_proof_requires_termination_request)

  defp matching_external_proof?(assignment, evidence_id) do
    SQL.query!(
      Repo,
      """
      SELECT 1 FROM public.runtime_task_termination_proofs
      WHERE assignment_id = $1::uuid AND proof_kind = 'external_destroyed'
        AND evidence_id = $2
      LIMIT 1
      """,
      [Ecto.UUID.dump!(assignment.id), evidence_id]
    ).rows != []
  end
end
