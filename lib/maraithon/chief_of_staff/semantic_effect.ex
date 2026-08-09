defmodule Maraithon.ChiefOfStaff.SemanticEffect do
  @moduledoc """
  Immutable deterministic Chief semantic effect backed by complete source envelopes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(todo decision)

  schema "chief_semantic_effects" do
    field :effect_key, :binary
    field :user_id, :string
    field :agent_id, :binary_id
    field :agent_directive_id, :binary_id
    field :acquisition_run_id, :binary_id
    field :kind, :string
    field :subject_key, :string
    field :contract_version, :integer
    field :extractor_version, :string
    field :payload, :map
    field :payload_digest, :binary

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def kinds, do: @kinds

  def changeset(effect, attrs) do
    effect
    |> cast(attrs, [
      :id,
      :effect_key,
      :user_id,
      :agent_id,
      :agent_directive_id,
      :acquisition_run_id,
      :kind,
      :subject_key,
      :contract_version,
      :extractor_version,
      :payload,
      :payload_digest,
      :inserted_at
    ])
    |> validate_required([
      :effect_key,
      :user_id,
      :agent_id,
      :agent_directive_id,
      :acquisition_run_id,
      :kind,
      :subject_key,
      :contract_version,
      :extractor_version,
      :payload,
      :payload_digest,
      :inserted_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:contract_version, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> V.validate_digest(:effect_key)
    |> V.validate_digest(:payload_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:subject_key, min: 1, max: 1024)
    |> V.validate_bytes(:extractor_version, min: 1, max: 80)
    |> V.validate_object(:payload)
    |> unique_constraint([:user_id, :effect_key],
      name: :chief_semantic_effects_user_key_unique_index
    )
    |> foreign_key_constraint(:agent_id, name: :chief_semantic_effects_agent_owner_fkey)
    |> foreign_key_constraint(:agent_directive_id,
      name: :chief_semantic_effects_directive_owner_fkey
    )
    |> foreign_key_constraint(:acquisition_run_id,
      name: :chief_semantic_effects_acquisition_owner_fkey
    )
    |> check_constraint(:payload, name: :chief_semantic_effects_payload_check)
    |> check_constraint(:payload_digest, name: :chief_semantic_effects_digest_check)
  end
end
