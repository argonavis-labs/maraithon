defmodule Maraithon.Runtime.IngressReceipt do
  @moduledoc """
  Immutable, tenant-exact proof that one stable provider event was durably admitted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(webhook push poll scheduled manual replay)

  schema "runtime_ingress_receipts" do
    field :receipt_key, :binary
    field :user_id, :string
    field :agent_id, :binary_id
    field :connected_account_id, :id
    field :provider, :string
    field :provider_account_key, :string
    field :ingress_kind, :string
    field :provider_event_key, :string
    field :payload, :map
    field :request_fingerprint, :binary
    field :provider_occurred_at, :utc_datetime_usec
    field :received_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def kinds, do: @kinds

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :id,
      :receipt_key,
      :user_id,
      :agent_id,
      :connected_account_id,
      :provider,
      :provider_account_key,
      :ingress_kind,
      :provider_event_key,
      :payload,
      :request_fingerprint,
      :provider_occurred_at,
      :received_at,
      :inserted_at
    ])
    |> validate_required([
      :receipt_key,
      :user_id,
      :agent_id,
      :connected_account_id,
      :provider,
      :provider_account_key,
      :ingress_kind,
      :provider_event_key,
      :payload,
      :request_fingerprint,
      :received_at,
      :inserted_at
    ])
    |> validate_inclusion(:ingress_kind, @kinds)
    |> V.validate_digest(:receipt_key)
    |> V.validate_digest(:request_fingerprint)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:provider, min: 1, max: 80)
    |> V.validate_bytes(:provider_account_key, min: 1, max: 255)
    |> V.validate_bytes(:provider_event_key, min: 1, max: 512)
    |> V.validate_object(:payload)
    |> unique_constraint(:receipt_key,
      name: :runtime_ingress_receipts_receipt_key_unique_index
    )
    |> unique_constraint(
      [
        :user_id,
        :agent_id,
        :connected_account_id,
        :provider,
        :provider_account_key,
        :ingress_kind,
        :provider_event_key
      ],
      name: :runtime_ingress_receipts_provider_identity_unique_index
    )
    |> foreign_key_constraint(:agent_id, name: :runtime_ingress_receipts_agent_owner_fkey)
    |> foreign_key_constraint(:connected_account_id,
      name: :runtime_ingress_receipts_account_owner_fkey
    )
    |> check_constraint(:payload, name: :runtime_ingress_receipts_payload_check)
    |> check_constraint(:receipt_key, name: :runtime_ingress_receipts_digest_check)
  end
end
