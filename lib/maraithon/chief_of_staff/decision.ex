defmodule Maraithon.ChiefOfStaff.Decision do
  @moduledoc """
  Immutable source-backed Chief decision projection with a deterministic domain key.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(approval choice clarification review)

  schema "chief_decisions" do
    field :decision_key, :binary
    field :decision_identity, :string
    field :user_id, :string
    field :agent_id, :binary_id
    field :semantic_effect_id, :binary_id
    field :kind, :string
    field :payload, :map
    field :payload_digest, :binary

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def kinds, do: @kinds

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :id,
      :decision_key,
      :decision_identity,
      :user_id,
      :agent_id,
      :semantic_effect_id,
      :kind,
      :payload,
      :payload_digest,
      :inserted_at
    ])
    |> validate_required([
      :decision_key,
      :decision_identity,
      :user_id,
      :agent_id,
      :semantic_effect_id,
      :kind,
      :payload,
      :payload_digest,
      :inserted_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> V.validate_digest(:decision_key)
    |> V.validate_digest(:payload_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:decision_identity, min: 1, max: 512)
    |> V.validate_object(:payload)
    |> unique_constraint([:user_id, :decision_key],
      name: :chief_decisions_user_key_unique_index
    )
    |> unique_constraint(:semantic_effect_id,
      name: :chief_decisions_semantic_effect_unique_index
    )
    |> foreign_key_constraint(:agent_id, name: :chief_decisions_agent_owner_fkey)
    |> foreign_key_constraint(:semantic_effect_id,
      name: :chief_decisions_effect_owner_fkey
    )
    |> check_constraint(:payload, name: :chief_decisions_payload_check)
    |> check_constraint(:payload_digest, name: :chief_decisions_digest_check)
  end
end
