defmodule Maraithon.Runtime.AgentTerminationProof do
  @moduledoc "Immutable physical termination evidence for one exact Agent lease."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "agent_termination_proofs" do
    field :incident_id, Ecto.UUID
    field :activation_epoch, Ecto.UUID
    field :node_incarnation_id, Ecto.UUID
    field :partition_id, :integer
    field :partition_epoch, :integer
    field :agent_id, Ecto.UUID
    field :lease_token, Ecto.UUID
    field :proof_kind, :string
    field :local_pid, :string
    field :monitor_started_at, :utc_datetime_usec
    field :down_reason, :string
    field :evidence_id, :string
    field :evidence_digest, :binary
    field :attestation_signature, :binary
    field :proved_by, :string
    field :proved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(id incident_id activation_epoch node_incarnation_id partition_id partition_epoch
             agent_id lease_token proof_kind local_pid monitor_started_at down_reason evidence_id
             evidence_digest attestation_signature proved_by proved_at)a

  def changeset(proof, attrs) do
    proof
    |> cast(attrs || %{}, @fields)
    |> validate_required([
      :id,
      :incident_id,
      :agent_id,
      :lease_token,
      :proof_kind,
      :proved_by,
      :proved_at
    ])
    |> validate_inclusion(:proof_kind, ~w(local_down external_node_destroyed))
    |> validate_length(:local_pid, min: 1, max: 255, count: :bytes)
    |> validate_length(:down_reason, min: 1, max: 255, count: :bytes)
    |> validate_length(:evidence_id, min: 1, max: 256, count: :bytes)
    |> validate_length(:proved_by, min: 1, max: 320, count: :bytes)
    |> foreign_key_constraint(:incident_id)
    |> unique_constraint(:incident_id, name: :agent_termination_proofs_incident_index)
    |> unique_constraint(:lease_token, name: :agent_termination_proofs_lease_token_index)
    |> check_constraint(:proof_kind, name: :agent_termination_proofs_shape)
  end
end
