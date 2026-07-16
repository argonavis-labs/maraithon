defmodule Maraithon.Push.Devices do
  @moduledoc """
  Registry of mobile devices that can receive push notifications.
  """

  import Ecto.Query

  alias Maraithon.Push.Device
  alias Maraithon.Repo

  require Logger

  @doc """
  Registers (or refreshes) a device token for a user.

  Upserts by token: a token already registered to another user moves to the
  registering user — the phone proved possession by presenting a valid
  session, and a device belongs to whoever is signed in on it.
  """
  def register(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("user_id", user_id)
      |> Map.put("status", "active")
      |> Map.put("last_seen_at", now)

    %Device{}
    |> Device.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace, [:user_id, :status, :app_version, :environment, :last_seen_at, :updated_at]},
      conflict_target: :device_token,
      returning: true
    )
  end

  @doc """
  Removes a device registration (sign-out). Scoped to the owning user so a
  stale client cannot unregister someone else's device.
  """
  def unregister(user_id, device_token) when is_binary(user_id) and is_binary(device_token) do
    Device
    |> where([d], d.user_id == ^user_id and d.device_token == ^device_token)
    |> Repo.delete_all()
    |> then(fn {count, _} -> {:ok, count} end)
  end

  def active_for_user(user_id) when is_binary(user_id) do
    Device
    |> where([d], d.user_id == ^user_id and d.status == "active")
    |> order_by([d], desc: d.last_seen_at)
    |> Repo.all()
  end

  def active_for_user(_user_id), do: []

  def any_active?(user_id) when is_binary(user_id) do
    Device
    |> where([d], d.user_id == ^user_id and d.status == "active")
    |> Repo.exists?()
  end

  def any_active?(_user_id), do: false

  @doc """
  Disables a device APNs reported as gone (410 Unregistered / BadDeviceToken).
  Kept as a row (not deleted) for the audit trail; re-registration reactivates.
  """
  def disable(%Device{} = device) do
    Logger.info("Disabling push device reported unregistered by APNs",
      user_id: device.user_id,
      device_id: device.id
    )

    device
    |> Ecto.Changeset.change(%{status: "disabled"})
    |> Repo.update()
  end
end
