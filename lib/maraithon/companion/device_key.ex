defmodule Maraithon.Companion.DeviceKey do
  @moduledoc """
  Public-key record for a companion device.

  Each row is one Curve25519 public key the device has published. The
  device retains the matching private key in its Keychain; the server
  only ever sees the public half.

  Multiple rows per `(user_id, device_id)` are allowed — that's how we
  support rotation. The active key is the newest non-revoked row with
  the highest `inserted_at`; older `key_id`s remain so ciphertext written
  under a prior key is still meaningfully tagged.

  `key_id` is a short client-chosen identifier (base64-like) and is
  recorded on every encrypted ingest row so the client can pick the right
  private key for decryption after rotation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "companion_device_keys" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :key_id, :string
    field :public_key, :string
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :device_id, :key_id, :public_key]
  @optional_fields [:revoked_at]

  def changeset(device_key, attrs) do
    device_key
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:key_id, min: 1, max: 128)
    |> validate_length(:public_key, min: 1, max: 1024)
    |> unique_constraint([:user_id, :device_id, :key_id],
      name: :companion_device_keys_user_device_key_id_index
    )
  end
end
