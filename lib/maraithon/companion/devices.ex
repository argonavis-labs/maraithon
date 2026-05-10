defmodule Maraithon.Companion.Devices do
  @moduledoc """
  Companion device registry: register, verify, revoke, and touch
  desktop companion devices that push local context to Maraithon.

  Pattern mirrors `Maraithon.Accounts` `UserSession` flow — plaintext
  bearer tokens are shown to the caller exactly once; only a SHA-256
  hex digest is persisted as `token_hash`.
  """

  import Ecto.Query

  alias Maraithon.Companion.Device
  alias Maraithon.Repo

  @doc """
  Registers (or refreshes) a paired companion device for a user.

  Generates a fresh plaintext bearer token, stores its SHA-256 hex
  digest, and returns `{:ok, %{device: device, token: plaintext}}` so
  the caller can hand the token to the device.

  If a `(user_id, device_id)` row already exists (e.g. the user re-runs
  the pairing flow), the row's `token_hash` is rotated and any prior
  `revoked_at` is cleared.
  """
  def register(user_id, device_id, opts \\ []) when is_binary(user_id) do
    device_name = Keyword.get(opts, :device_name)
    token = generate_token()
    token_hash = hash_token(token)
    now = DateTime.utc_now()

    attrs = %{
      user_id: user_id,
      device_id: device_id,
      device_name: device_name,
      token_hash: token_hash,
      last_seen_at: now,
      revoked_at: nil
    }

    result =
      case Repo.get_by(Device, user_id: user_id, device_id: device_id) do
        nil ->
          %Device{}
          |> Device.changeset(attrs)
          |> Repo.insert()

        %Device{} = existing ->
          existing
          |> Device.changeset(attrs)
          |> Repo.update()
      end

    case result do
      {:ok, device} ->
        :telemetry.execute(
          [:maraithon, :companion, :device_paired],
          %{count: 1},
          %{user_id: user_id, device_id: device_id}
        )

        {:ok, %{device: device, token: token}}

      error ->
        error
    end
  end

  @doc """
  Revokes a paired device by row id (uuid).
  """
  def revoke(user_id, id) when is_binary(user_id) and is_binary(id) do
    case Repo.get_by(Device, id: id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      %Device{revoked_at: %DateTime{}} = device ->
        {:ok, device}

      %Device{} = device ->
        device
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  @doc """
  Lists active (non-revoked) devices for a user, most recently seen first.
  """
  def list_for_user(user_id) when is_binary(user_id) do
    Repo.all(
      from device in Device,
        where: device.user_id == ^user_id,
        order_by: [desc: coalesce(device.last_seen_at, device.inserted_at)]
    )
  end

  @doc """
  Verifies a plaintext bearer token. Returns the device if it exists,
  is not revoked, and the hash matches. Returns `nil` otherwise.
  """
  def verify_token(token) when is_binary(token) and token != "" do
    token_hash = hash_token(token)

    Repo.one(
      from device in Device,
        where: device.token_hash == ^token_hash,
        where: is_nil(device.revoked_at)
    )
  end

  def verify_token(_), do: nil

  @doc """
  Bumps `last_seen_at` on a device. Best-effort — failures are swallowed.
  """
  def touch_last_seen(%Device{} = device) do
    case device
         |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
         |> Repo.update() do
      {:ok, updated} -> updated
      _error -> device
    end
  end

  @doc """
  SHA-256 hex digest used as the on-disk identifier for a token.
  """
  def hash_token(token) when is_binary(token) do
    :sha256
    |> :crypto.hash(token)
    |> Base.encode16(case: :lower)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end
end
