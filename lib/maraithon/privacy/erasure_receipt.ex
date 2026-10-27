defmodule Maraithon.Privacy.ErasureReceipt do
  @moduledoc """
  Explicitly classified, content-free proof that local erasure completed.

  Receipts never contain subject identifiers, content hashes, provider
  evidence, free-form operator text, or ciphertext. They expire under the
  bounded receipt-retention policy.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "privacy_erasure_receipts" do
    field :request_id, Ecto.UUID
    field :classification, :string
    field :scope, :string
    field :outcome, :string
    field :local_data_deleted, :boolean
    field :credentials_locally_revoked, :boolean
    field :provider_revocation_outcome, :string
    field :erased_agent_count, :integer
    field :issued_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
