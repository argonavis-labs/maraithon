defmodule Maraithon.Effects.TerminationAttestations do
  @moduledoc """
  Records and verifies explicit task-bound physical-termination attestations.

  The operator confirmation is a deliberate-action interlock, not an
  authorization secret. Production authorization comes from granting INSERT on
  the attestation table only to the separately scoped operator database role.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Effects.{Effect, TerminationAttestation}
  alias Maraithon.Repo
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.Coordination.{TaskAssignment, TaskClaims}
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol

  @confirmation "PHYSICAL_TASK_TERMINATED"

  def confirmation, do: @confirmation

  def record(identity, evidence_id, attested_by, confirmation)
      when is_map(identity) and is_binary(evidence_id) and is_binary(attested_by) do
    with :ok <- confirm(confirmation),
         {:ok, identity} <- validate_identity(identity),
         :ok <- validate_text(evidence_id, 256),
         :ok <- validate_text(attested_by, 320) do
      evidence_digest = :crypto.hash(:sha256, evidence_id)

      Repo.transaction(fn ->
        runtime_mode = CoordinationProtocol.locked_mode!()
        ProtocolCutover.require_exact_reconciliation!()
        now = DatabaseClock.now!()

        SQL.query!(
          Repo,
          "SELECT set_config('maraithon.effect_termination_attestation', $1, true)",
          [@confirmation]
        )

        lock_identity!(identity)

        case find_existing(identity) do
          %TerminationAttestation{} = attestation ->
            verify_existing_attestation!(
              attestation,
              evidence_id,
              evidence_digest,
              attested_by
            )

            lock_effect_row!(attestation.effect_id)
            assignment = lock_historical_assignment_or_uncoordinated!(identity)
            validate_runtime_binding!(runtime_mode, assignment)
            proven = maybe_prove_external_assignment!(assignment, evidence_id, attested_by)
            %{attestation: attestation, task_assignment: proven}

          nil ->
            effect = lock_exact_effect!(identity)
            assignment = lock_exact_assignment_or_uncoordinated!(effect, identity)
            validate_runtime_binding!(runtime_mode, assignment)

            attestation =
              %TerminationAttestation{}
              |> TerminationAttestation.changeset(%{
                effect_id: identity.effect_id,
                claim_token: identity.claim_token,
                owner_node: identity.owner_node,
                supervisor_id: identity.supervisor_id,
                task_id: identity.task_id,
                evidence_id: evidence_id,
                evidence_digest: evidence_digest,
                attested_by: attested_by,
                attested_at: now
              })
              |> Repo.insert!()

            proven = maybe_prove_external_assignment!(assignment, evidence_id, attested_by)
            %{attestation: attestation, task_assignment: proven}
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    _error in [Postgrex.Error, Ecto.ConstraintError] ->
      {:error, :effect_termination_attestation_refused}
  catch
    :exit, _reason -> {:error, :effect_termination_attestation_storage_unavailable}
  end

  def record(_identity, _evidence_id, _attested_by, _confirmation),
    do: {:error, :invalid_effect_termination_attestation}

  def proof?(identity) when is_map(identity) do
    with {:ok, identity} <- validate_identity(identity) do
      Repo.exists?(
        from(attestation in TerminationAttestation,
          where: attestation.effect_id == ^identity.effect_id,
          where: attestation.claim_token == ^identity.claim_token,
          where: attestation.owner_node == ^identity.owner_node,
          where: attestation.supervisor_id == ^identity.supervisor_id,
          where: attestation.task_id == ^identity.task_id
        )
      )
    else
      _invalid -> false
    end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  def proof?(_identity), do: false

  defp lock_identity!(identity) do
    SQL.query!(
      Repo,
      """
      SELECT pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
          pg_catalog.concat_ws(
            pg_catalog.chr(31), $1::text::uuid::text, $2::text::uuid::text, $3::text,
            $4::text::uuid::text, $5::text::uuid::text
          ),
          20260811
        )
      )
      """,
      [
        identity.effect_id,
        identity.claim_token,
        identity.owner_node,
        identity.supervisor_id,
        identity.task_id
      ]
    )

    :ok
  end

  defp verify_existing_attestation!(attestation, evidence_id, evidence_digest, attested_by) do
    unless attestation.evidence_digest == evidence_digest and
             attestation.evidence_id == evidence_id and
             attestation.attested_by == attested_by,
           do: Repo.rollback(:effect_termination_attestation_conflict)

    :ok
  end

  defp lock_historical_assignment_or_uncoordinated!(identity) do
    case Repo.one(
           from assignment in TaskAssignment,
             where: assignment.work_kind == "effect",
             where: assignment.work_id == ^identity.effect_id,
             where: assignment.claim_token == ^identity.claim_token,
             where: assignment.supervisor_id == ^identity.supervisor_id,
             where: assignment.local_task_id == ^identity.task_id
         ) do
      %TaskAssignment{} = candidate ->
        actual = TaskClaims.lock_effect_assignment_in_transaction!(candidate)

        if exact_historical_assignment?(actual, identity),
          do: actual,
          else: Repo.rollback(:effect_termination_attestation_assignment_lost)

      nil ->
        case Repo.one(
               from effect in Effect,
                 where: effect.id == ^identity.effect_id,
                 where: is_nil(effect.coordination_activation_epoch),
                 where: is_nil(effect.coordination_partition_id),
                 where: is_nil(effect.coordination_partition_epoch),
                 where: is_nil(effect.coordination_node_incarnation_id),
                 where: is_nil(effect.coordination_task_assignment_id),
                 lock: "FOR UPDATE"
             ) do
          %Effect{} -> :uncoordinated
          nil -> Repo.rollback(:effect_termination_attestation_assignment_lost)
        end
    end
  end

  defp exact_historical_assignment?(assignment, identity) do
    assignment.work_kind == "effect" and
      assignment.work_id == identity.effect_id and
      assignment.claim_token == identity.claim_token and
      assignment.supervisor_id == identity.supervisor_id and
      assignment.local_task_id == identity.task_id
  end

  defp lock_effect_row!(effect_id) do
    case Repo.one(from effect in Effect, where: effect.id == ^effect_id, lock: "FOR UPDATE") do
      %Effect{} -> :ok
      nil -> Repo.rollback(:effect_termination_attestation_effect_lost)
    end
  end

  defp lock_exact_effect!(identity) do
    case Repo.one(
           from effect in Effect,
             where: effect.id == ^identity.effect_id,
             where: effect.claim_token == ^identity.claim_token,
             where: effect.claim_owner_node == ^identity.owner_node,
             where: effect.claim_supervisor_id == ^identity.supervisor_id,
             where: effect.claim_task_id == ^identity.task_id,
             where: effect.status == "cancelling",
             where: effect.cancellation_state == "requested",
             lock: "FOR UPDATE"
         ) do
      %Effect{} = effect -> effect
      nil -> Repo.rollback(:effect_termination_attestation_identity_lost)
    end
  end

  defp lock_exact_assignment_or_uncoordinated!(effect, identity) do
    expected =
      case effect do
        %Effect{
          id: work_id,
          claim_token: claim_token,
          coordination_activation_epoch: activation_epoch,
          coordination_partition_id: partition_id,
          coordination_partition_epoch: partition_epoch,
          coordination_node_incarnation_id: node_incarnation_id,
          coordination_task_assignment_id: assignment_id
        }
        when is_binary(activation_epoch) and is_integer(partition_id) and
               is_integer(partition_epoch) and is_binary(node_incarnation_id) and
               is_binary(assignment_id) ->
          %TaskAssignment{
            id: assignment_id,
            activation_epoch: activation_epoch,
            work_kind: "effect",
            work_id: work_id,
            claim_token: claim_token,
            partition_id: partition_id,
            partition_epoch: partition_epoch,
            node_incarnation_id: node_incarnation_id,
            supervisor_id: identity.supervisor_id,
            local_task_id: identity.task_id
          }

        %Effect{
          coordination_activation_epoch: nil,
          coordination_partition_id: nil,
          coordination_partition_epoch: nil,
          coordination_node_incarnation_id: nil,
          coordination_task_assignment_id: nil
        } ->
          :uncoordinated

        _mismatched ->
          Repo.rollback(:effect_termination_attestation_assignment_required)
      end

    case expected do
      :uncoordinated ->
        :uncoordinated

      %TaskAssignment{} ->
        actual = TaskClaims.lock_effect_assignment_in_transaction!(expected)

        fields = [
          :id,
          :activation_epoch,
          :work_kind,
          :work_id,
          :claim_token,
          :partition_id,
          :partition_epoch,
          :node_incarnation_id,
          :supervisor_id,
          :local_task_id
        ]

        if Map.take(actual, fields) == Map.take(expected, fields),
          do: actual,
          else: Repo.rollback(:effect_termination_attestation_assignment_lost)
    end
  end

  defp validate_runtime_binding!(:dark, :uncoordinated), do: :ok

  defp validate_runtime_binding!(
         {:active, epoch},
         %TaskAssignment{activation_epoch: epoch}
       ),
       do: :ok

  defp validate_runtime_binding!(runtime_mode, assignment_shape),
    do:
      Repo.rollback(
        {:effect_termination_attestation_runtime_mismatch, runtime_mode, assignment_shape}
      )

  defp maybe_prove_external_assignment!(:uncoordinated, _evidence_id, _attested_by),
    do: nil

  defp maybe_prove_external_assignment!(%TaskAssignment{} = assignment, evidence_id, attested_by),
    do: prove_external_assignment!(assignment, evidence_id, attested_by)

  defp prove_external_assignment!(assignment, evidence_id, attested_by) do
    case assignment.state do
      state when state in ["reserved", "termination_requested"] ->
        case TaskClaims.record_external_termination(assignment, evidence_id, attested_by) do
          {:ok, %TaskAssignment{state: "termination_proven"} = proven} -> proven
          _lost -> Repo.rollback(:effect_external_task_proof_lost)
        end

      state when state in ["termination_proven", "settled", "outcome_ambiguous"] ->
        if matching_external_task_proof?(assignment, evidence_id),
          do: assignment,
          else: Repo.rollback(:effect_external_task_proof_lost)

      _not_provable ->
        Repo.rollback(:effect_external_task_proof_requires_termination_request)
    end
  end

  defp matching_external_task_proof?(assignment, evidence_id) do
    case SQL.query!(
           Repo,
           """
           SELECT 1
           FROM public.runtime_task_termination_proofs
           WHERE assignment_id = $1::uuid AND activation_epoch = $2::uuid
             AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
             AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
             AND proof_kind = 'external_destroyed' AND evidence_id = $7
             AND evidence_digest = $8
           """,
           [
             Ecto.UUID.dump!(assignment.id),
             Ecto.UUID.dump!(assignment.activation_epoch),
             Ecto.UUID.dump!(assignment.claim_token),
             Ecto.UUID.dump!(assignment.node_incarnation_id),
             Ecto.UUID.dump!(assignment.supervisor_id),
             Ecto.UUID.dump!(assignment.local_task_id),
             evidence_id,
             :crypto.hash(:sha256, evidence_id)
           ]
         ).rows do
      [[1]] -> true
      _missing -> false
    end
  end

  defp find_existing(identity) do
    Repo.one(
      from(attestation in TerminationAttestation,
        where: attestation.effect_id == ^identity.effect_id,
        where: attestation.claim_token == ^identity.claim_token,
        where: attestation.owner_node == ^identity.owner_node,
        where: attestation.supervisor_id == ^identity.supervisor_id,
        where: attestation.task_id == ^identity.task_id
      )
    )
  end

  defp validate_identity(identity) do
    with {:ok, effect_id} <- uuid(Map.get(identity, :effect_id)),
         {:ok, claim_token} <- uuid(Map.get(identity, :claim_token)),
         {:ok, supervisor_id} <- uuid(Map.get(identity, :supervisor_id)),
         {:ok, task_id} <- uuid(Map.get(identity, :task_id)),
         owner_node when is_binary(owner_node) <- Map.get(identity, :owner_node),
         :ok <- validate_text(owner_node, 255) do
      {:ok,
       %{
         effect_id: effect_id,
         claim_token: claim_token,
         owner_node: owner_node,
         supervisor_id: supervisor_id,
         task_id: task_id
       }}
    else
      _invalid -> {:error, :invalid_effect_termination_attestation}
    end
  end

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_effect_termination_attestation}
    end
  end

  defp uuid(_value), do: {:error, :invalid_effect_termination_attestation}

  defp validate_text(value, max_bytes)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max_bytes do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch,
      do: :ok,
      else: {:error, :invalid_effect_termination_attestation}
  end

  defp validate_text(_value, _max_bytes),
    do: {:error, :invalid_effect_termination_attestation}

  defp confirm(@confirmation), do: :ok
  defp confirm(_confirmation), do: {:error, :effect_termination_confirmation_required}
end
