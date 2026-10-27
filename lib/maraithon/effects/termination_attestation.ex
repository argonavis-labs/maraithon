defmodule Maraithon.Effects.TerminationAttestation do
  @moduledoc """
  Durable operator proof that one exact physical Effect task can no longer run.

  Attestations are claim-generation specific and immutable. They never assert a
  provider outcome; they authorize cancellation settlement as outcome-ambiguous.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "effect_termination_attestations" do
    field :claim_token, Ecto.UUID
    field :owner_node, :string
    field :supervisor_id, Ecto.UUID
    field :task_id, Ecto.UUID
    field :evidence_id, :string
    field :evidence_digest, :binary
    field :attested_by, :string
    field :attested_at, :utc_datetime_usec

    field :effect_id, Ecto.UUID

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(attestation, attrs) do
    attestation
    |> cast(attrs, [
      :effect_id,
      :claim_token,
      :owner_node,
      :supervisor_id,
      :task_id,
      :evidence_id,
      :evidence_digest,
      :attested_by,
      :attested_at
    ])
    |> validate_required([
      :effect_id,
      :claim_token,
      :owner_node,
      :supervisor_id,
      :task_id,
      :evidence_id,
      :evidence_digest,
      :attested_by,
      :attested_at
    ])
    |> validate_length(:owner_node, min: 1, max: 255)
    |> validate_length(:evidence_id, min: 1, max: 256)
    |> validate_length(:attested_by, min: 1, max: 320)
    |> validate_change(:evidence_digest, fn :evidence_digest, digest ->
      if is_binary(digest) and byte_size(digest) == 32,
        do: [],
        else: [evidence_digest: "must be a SHA-256 digest"]
    end)
    |> unique_constraint(
      [:effect_id, :claim_token, :supervisor_id, :task_id],
      name: :effect_termination_attestations_claim_identity_index
    )
    |> check_constraint(:evidence_digest,
      name: :effect_termination_attestations_shape_check
    )
  end
end
