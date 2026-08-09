defmodule Maraithon.ChiefOfStaff.AcquisitionEnvelope do
  @moduledoc """
  Immutable association proving that a source envelope appeared in one exact acquisition page.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "chief_acquisition_envelopes" do
    field :acquisition_run_id, :binary_id, primary_key: true
    field :source_envelope_id, :binary_id, primary_key: true
    field :acquisition_page_id, :binary_id
    field :user_id, :string
    field :connected_account_id, :id
    field :provider, :string
    field :provider_account_key, :string
    field :item_ordinal, :integer
    field :provenance, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(association, attrs) do
    association
    |> cast(attrs, [
      :acquisition_run_id,
      :source_envelope_id,
      :acquisition_page_id,
      :user_id,
      :connected_account_id,
      :provider,
      :provider_account_key,
      :item_ordinal,
      :provenance,
      :inserted_at
    ])
    |> validate_required([
      :acquisition_run_id,
      :source_envelope_id,
      :acquisition_page_id,
      :user_id,
      :connected_account_id,
      :provider,
      :provider_account_key,
      :item_ordinal,
      :provenance,
      :inserted_at
    ])
    |> validate_number(:item_ordinal, greater_than_or_equal_to: 0)
    |> validate_change(:provenance, fn :provenance, value ->
      if is_map(value) and not is_struct(value),
        do: [],
        else: [provenance: "must be an object"]
    end)
    |> unique_constraint([:acquisition_run_id, :source_envelope_id],
      name: :chief_acquisition_envelopes_pkey
    )
    |> unique_constraint([:acquisition_page_id, :item_ordinal],
      name: :chief_acquisition_envelopes_page_ordinal_unique_index
    )
    |> foreign_key_constraint(:acquisition_page_id,
      name: :chief_acquisition_envelopes_page_run_fkey
    )
    |> foreign_key_constraint(:source_envelope_id)
    |> check_constraint(:provenance, name: :chief_acquisition_envelopes_provenance_check)
  end
end
