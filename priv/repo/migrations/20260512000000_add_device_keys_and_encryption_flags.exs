defmodule Maraithon.Repo.Migrations.AddDeviceKeysAndEncryptionFlags do
  @moduledoc """
  v4 client-side encryption support.

    1. Adds a `companion_device_keys` table that pairs a companion device
       with one or more Curve25519 public keys it has published. Multiple
       rows per device allow rotation: the newest non-revoked key with the
       highest `inserted_at` is the active key, and older `key_id`s remain
       so existing ciphertext can still be decrypted by the device.

    2. Adds `encrypted_with_device_key` (bool) + `key_id` (text, nullable)
       to every `local_*` table that mirrors user content. The columns are
       additive: existing rows default to `encrypted_with_device_key = false`
       and continue to be decryptable through the Cloak vault as before.
       Rows ingested with the flag set carry an opaque base64-encoded blob
       in the existing encrypted column (the Cloak `Binary` type stores it
       verbatim because the value already passed through ChaChaPoly on the
       device and is now just a byte string from the server's perspective).
  """

  use Ecto.Migration

  @encrypted_tables ~w(
    local_messages
    local_notes
    local_voice_memos
    local_calendar_events
    local_reminders
    local_files
  )a

  def change do
    create table(:companion_device_keys, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :string, null: false
      add :device_id, :uuid, null: false
      # `key_id` is the device-chosen short identifier (base64-ish). The
      # device sends it on every encrypted record so we can record which
      # key was used and the device can pick the right private key for
      # decryption after a future rotation.
      add :key_id, :string, null: false
      # Base64-encoded Curve25519 public key. The server never uses it to
      # encrypt anything itself — it stores it so the device can compare
      # what the server thinks the current key is against what's in the
      # Keychain (a "did I rotate behind my own back?" check).
      add :public_key, :text, null: false
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:companion_device_keys, [:user_id, :device_id, :key_id],
             name: :companion_device_keys_user_device_key_id_index
           )

    create index(:companion_device_keys, [:user_id, :device_id])

    for table_name <- @encrypted_tables do
      alter table(table_name) do
        add :encrypted_with_device_key, :boolean, default: false, null: false
        add :key_id, :string
      end

      create index(table_name, [:user_id, :encrypted_with_device_key])
    end
  end
end
