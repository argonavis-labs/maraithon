defmodule Maraithon.Companion.DeviceKeys do
  @moduledoc """
  CRUD + lookup for companion device public keys.

  The companion app generates a Curve25519 keypair on first pair and
  uploads the public half here. The private half stays in the device's
  Keychain and is the root of the per-record content-encryption key
  derivation chain.

  This module is intentionally narrow — it owns:

    * `upsert/3` — register a new key (or refresh an existing row, e.g.
      after re-pair).
    * `current_for/2` — fetch the newest non-revoked key for a device.
    * `get_by_key_id/3` — fetch a specific key row for an inbound ingest
      that names a `key_id` so we can validate it belongs to the calling
      device.
    * `revoke/3` — mark a key revoked. We never delete rows because
      historical `key_id`s still appear in encrypted ingest rows.
  """

  import Ecto.Query

  alias Maraithon.Companion.DeviceKey
  alias Maraithon.Repo

  @doc """
  Inserts a new public key for a device, or refreshes the matching
  `(user_id, device_id, key_id)` row when the device re-uploads the same
  identifier (e.g. on app restart). Clears any prior `revoked_at` so a
  device that previously revoked-then-republished the same key resumes
  as the active key for the device.

  Returns `{:ok, %DeviceKey{}}` on success.
  """
  def upsert(user_id, device_id, attrs)
      when is_binary(user_id) and is_binary(device_id) and is_map(attrs) do
    key_id = Map.get(attrs, :key_id) || Map.get(attrs, "key_id")
    public_key = Map.get(attrs, :public_key) || Map.get(attrs, "public_key")

    base = %{
      user_id: user_id,
      device_id: device_id,
      key_id: key_id,
      public_key: public_key,
      revoked_at: nil
    }

    case Repo.get_by(DeviceKey, user_id: user_id, device_id: device_id, key_id: key_id) do
      nil ->
        %DeviceKey{}
        |> DeviceKey.changeset(base)
        |> Repo.insert()

      %DeviceKey{} = existing ->
        existing
        |> DeviceKey.changeset(base)
        |> Repo.update()
    end
  end

  @doc """
  Returns the newest non-revoked key for `(user_id, device_id)`, or `nil`
  if the device has never uploaded one.
  """
  def current_for(user_id, device_id)
      when is_binary(user_id) and is_binary(device_id) do
    Repo.one(
      from key in DeviceKey,
        where: key.user_id == ^user_id,
        where: key.device_id == ^device_id,
        where: is_nil(key.revoked_at),
        order_by: [desc: key.inserted_at],
        limit: 1
    )
  end

  @doc """
  Looks up a specific `(user_id, device_id, key_id)` row. Used during
  ingest to confirm the inbound `key_id` belongs to the calling device.
  Returns `nil` for unknown identifiers.
  """
  def get_by_key_id(user_id, device_id, key_id)
      when is_binary(user_id) and is_binary(device_id) and is_binary(key_id) do
    Repo.get_by(DeviceKey, user_id: user_id, device_id: device_id, key_id: key_id)
  end

  def get_by_key_id(_user_id, _device_id, _key_id), do: nil

  @doc """
  Marks a key revoked. The row stays so existing `key_id` references on
  encrypted records still point at something.
  """
  def revoke(user_id, device_id, key_id)
      when is_binary(user_id) and is_binary(device_id) and is_binary(key_id) do
    case get_by_key_id(user_id, device_id, key_id) do
      nil ->
        {:error, :not_found}

      %DeviceKey{} = row ->
        row
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  @doc """
  Lists every key (revoked or not) for a device, most recently created
  first. Used by tests and a future Privacy UI.
  """
  def list_for(user_id, device_id)
      when is_binary(user_id) and is_binary(device_id) do
    Repo.all(
      from key in DeviceKey,
        where: key.user_id == ^user_id,
        where: key.device_id == ^device_id,
        order_by: [desc: key.inserted_at]
    )
  end
end
