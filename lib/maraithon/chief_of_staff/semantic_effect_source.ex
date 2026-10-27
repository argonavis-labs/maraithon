defmodule Maraithon.ChiefOfStaff.SemanticEffectSource do
  @moduledoc """
  Immutable source membership for a deterministic Chief semantic effect.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "chief_semantic_effect_sources" do
    field :semantic_effect_id, :binary_id, primary_key: true
    field :acquisition_run_id, :binary_id
    field :source_envelope_id, :binary_id, primary_key: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:semantic_effect_id, :acquisition_run_id, :source_envelope_id, :inserted_at])
    |> validate_required([
      :semantic_effect_id,
      :acquisition_run_id,
      :source_envelope_id,
      :inserted_at
    ])
    |> unique_constraint([:semantic_effect_id, :source_envelope_id])
    |> foreign_key_constraint(:semantic_effect_id)
    |> foreign_key_constraint(:source_envelope_id)
  end
end
