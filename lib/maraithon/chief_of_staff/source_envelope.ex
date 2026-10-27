defmodule Maraithon.ChiefOfStaff.SourceEnvelope do
  @moduledoc """
  Immutable canonical provider item revision with raw and normalized digests.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chief_source_envelopes" do
    field :envelope_key, :binary
    field :user_id, :string
    field :connected_account_id, :id
    field :provider, :string
    field :provider_account_key, :string
    field :source, :string
    field :scope_key, :string
    field :source_item_key, :string
    field :source_revision_key, :string
    field :raw_payload, :map
    field :normalized_payload, :map
    field :raw_digest, :binary
    field :normalized_digest, :binary
    field :occurred_at, :utc_datetime_usec
    field :received_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(envelope, attrs) do
    envelope
    |> cast(attrs, [
      :id,
      :envelope_key,
      :user_id,
      :connected_account_id,
      :provider,
      :provider_account_key,
      :source,
      :scope_key,
      :source_item_key,
      :source_revision_key,
      :raw_payload,
      :normalized_payload,
      :raw_digest,
      :normalized_digest,
      :occurred_at,
      :received_at,
      :inserted_at
    ])
    |> validate_required([
      :envelope_key,
      :user_id,
      :connected_account_id,
      :provider,
      :provider_account_key,
      :source,
      :scope_key,
      :source_item_key,
      :source_revision_key,
      :raw_payload,
      :normalized_payload,
      :raw_digest,
      :normalized_digest,
      :received_at,
      :inserted_at
    ])
    |> V.validate_digest(:envelope_key)
    |> V.validate_digest(:raw_digest)
    |> V.validate_digest(:normalized_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:provider, min: 1, max: 80)
    |> V.validate_bytes(:provider_account_key, min: 1, max: 255)
    |> V.validate_bytes(:source, min: 1, max: 80)
    |> V.validate_bytes(:scope_key, min: 1, max: 255)
    |> V.validate_bytes(:source_item_key, min: 1, max: 512)
    |> V.validate_bytes(:source_revision_key, min: 1, max: 255)
    |> V.validate_object(:raw_payload)
    |> V.validate_object(:normalized_payload)
    |> unique_constraint(:envelope_key,
      name: :chief_source_envelopes_envelope_key_unique_index
    )
    |> unique_constraint(
      [
        :user_id,
        :connected_account_id,
        :provider,
        :provider_account_key,
        :source,
        :scope_key,
        :source_item_key,
        :source_revision_key
      ],
      name: :chief_source_envelopes_provider_revision_unique_index
    )
    |> foreign_key_constraint(:connected_account_id,
      name: :chief_source_envelopes_account_owner_fkey
    )
    |> check_constraint(:raw_payload, name: :chief_source_envelopes_payload_check)
    |> check_constraint(:raw_digest, name: :chief_source_envelopes_digest_check)
  end
end
