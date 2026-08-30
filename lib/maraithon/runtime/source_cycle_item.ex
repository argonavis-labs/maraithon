defmodule Maraithon.Runtime.SourceCycleItem do
  @moduledoc "Immutable, privacy-safe identity proof for one item in a source cycle."

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "source_cycle_items" do
    field :cycle_id, :binary_id
    field :user_id, :string
    field :connected_account_id, :id
    field :provider, :string
    field :ordinal, :integer
    field :source_ref_digest, :binary
    field :source_identity_digest, :binary
    field :source_revision_digest, :binary
    field :provider_occurred_at, :utc_datetime_usec
    field :ingress_sequence, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :id,
      :cycle_id,
      :user_id,
      :connected_account_id,
      :provider,
      :ordinal,
      :source_ref_digest,
      :source_identity_digest,
      :source_revision_digest,
      :provider_occurred_at,
      :ingress_sequence,
      :inserted_at
    ])
    |> validate_required([
      :cycle_id,
      :user_id,
      :connected_account_id,
      :provider,
      :ordinal,
      :source_ref_digest,
      :source_identity_digest,
      :source_revision_digest,
      :inserted_at
    ])
    |> validate_number(:connected_account_id, greater_than: 0)
    |> validate_number(:ordinal, greater_than_or_equal_to: 0)
    |> validate_number(:ingress_sequence, greater_than_or_equal_to: 0)
    |> V.validate_digest(:source_ref_digest)
    |> V.validate_digest(:source_identity_digest)
    |> V.validate_digest(:source_revision_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:provider, min: 1, max: 80)
    |> unique_constraint([:cycle_id, :ordinal],
      name: :source_cycle_items_ordinal_unique_index
    )
    |> unique_constraint([:cycle_id, :source_ref_digest],
      name: :source_cycle_items_ref_unique_index
    )
    |> foreign_key_constraint(:cycle_id, name: :source_cycle_items_cycle_owner_fkey)
    |> check_constraint(:ordinal, name: :source_cycle_items_shape_check)
    |> check_constraint(:source_ref_digest, name: :source_cycle_items_digest_check)
  end
end
