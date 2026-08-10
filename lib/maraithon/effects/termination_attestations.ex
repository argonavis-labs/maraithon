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
  alias Maraithon.Effects.TerminationAttestation
  alias Maraithon.Repo
  alias Maraithon.Runtime.DatabaseClock

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
        ProtocolCutover.require_exact_reconciliation!()
        now = DatabaseClock.now!()

        SQL.query!(
          Repo,
          "SELECT set_config('maraithon.effect_termination_attestation', $1, true)",
          [@confirmation]
        )

        existing = lock_existing(identity)

        case existing do
          %TerminationAttestation{} = attestation ->
            if attestation.evidence_digest == evidence_digest and
                 attestation.evidence_id == evidence_id and
                 attestation.attested_by == attested_by do
              attestation
            else
              Repo.rollback(:effect_termination_attestation_conflict)
            end

          nil ->
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
        end
      end)
      |> case do
        {:ok, attestation} -> {:ok, attestation}
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

  defp lock_existing(identity) do
    Repo.one(
      from(attestation in TerminationAttestation,
        where: attestation.effect_id == ^identity.effect_id,
        where: attestation.claim_token == ^identity.claim_token,
        where: attestation.owner_node == ^identity.owner_node,
        where: attestation.supervisor_id == ^identity.supervisor_id,
        where: attestation.task_id == ^identity.task_id,
        lock: "FOR UPDATE"
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
