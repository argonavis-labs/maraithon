defmodule Maraithon.Runtime.IngressReceipt do
  @moduledoc """
  Immutable, tenant-exact proof that one stable provider event was durably admitted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.DurablePayload
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
    field :payload, Maraithon.Encrypted.Map, source: :payload_ciphertext, redact: true
    field :legacy_payload, :map, source: :payload, default: %{}, redact: true
    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :payload_purged_at, :utc_datetime_usec
    field :request_fingerprint, :binary
    field :provider_occurred_at, :utc_datetime_usec
    field :received_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def kinds, do: @kinds

  @doc false
  def payload_binding_spec do
    %{
      table: "runtime_ingress_receipts",
      identity_fields: [:id],
      scope_fields: [:user_id, :agent_id, :connected_account_id],
      fields: [:payload],
      purge_field: :payload_purged_at
    }
  end

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
    |> mirror_legacy_payload()
    |> put_payload_encryption_version()
    |> reactivate_payload()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
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

  @doc false
  def hydrate_payload(receipt, mode \\ DurablePayload.mode!())

  def hydrate_payload(%__MODULE__{} = receipt, mode) do
    :ok = DurablePayload.verify_binding!(receipt, payload_binding_spec(), mode)
    %{receipt | payload: read_payload!(receipt, mode)}
  end

  def hydrate_payload(other, _mode), do: other

  def read_payload!(%__MODULE__{payload_purged_at: %DateTime{}} = receipt, _mode) do
    if is_nil(receipt.payload) and receipt.legacy_payload == %{},
      do: %{},
      else: raise(ArgumentError, "purged IngressReceipt payload is corrupt or inconsistent")
  end

  def read_payload!(%__MODULE__{} = receipt, :legacy) do
    payload = receipt.payload || legacy_map(receipt.legacy_payload)

    if json_map?(payload),
      do: payload,
      else: raise(ArgumentError, "IngressReceipt payload is corrupt or inconsistent")
  end

  def read_payload!(%__MODULE__{} = receipt, :exact) do
    if receipt.payload_encryption_version == 1 and json_map?(receipt.payload) and
         receipt.legacy_payload == %{} do
      receipt.payload
    else
      raise ArgumentError, "exact IngressReceipt payload is not ciphertext-only"
    end
  end

  defp mirror_legacy_payload(changeset) do
    case fetch_change(changeset, :payload) do
      {:ok, payload} ->
        put_change(
          changeset,
          :legacy_payload,
          if(DurablePayload.legacy_write?(), do: payload, else: %{})
        )

      :error ->
        changeset
    end
  end

  defp put_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :payload),
      do: put_change(changeset, :payload_encryption_version, 1),
      else: changeset
  end

  defp reactivate_payload(changeset) do
    if changeset.data.payload_purged_at && Map.has_key?(changeset.changes, :payload),
      do: put_change(changeset, :payload_purged_at, nil),
      else: changeset
  end

  defp legacy_map(value) when is_map(value) and not is_struct(value), do: value
  defp legacy_map(_value), do: nil
  defp json_map?(value), do: is_map(value) and not is_struct(value)
end
