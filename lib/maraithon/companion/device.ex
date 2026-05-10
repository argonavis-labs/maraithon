defmodule Maraithon.Companion.Device do
  @moduledoc """
  Companion desktop device registration.

  A device represents one signed-and-paired macOS (or other) companion app
  instance that pushes local context (iMessages, files, etc.) to Maraithon
  for a single user. Tokens are stored as a SHA-256 hex digest; the plaintext
  token only exists in the device's Keychain.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "companion_devices" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :device_name, :string
    field :token_hash, :string
    field :last_seen_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :device_id, :token_hash]
  @optional_fields [:device_name, :last_seen_at, :revoked_at]

  def changeset(device, attrs) do
    device
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:device_name, max: 255)
    |> unique_constraint([:user_id, :device_id])
    |> unique_constraint(:token_hash)
  end
end
