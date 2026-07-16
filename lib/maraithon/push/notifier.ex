defmodule Maraithon.Push.Notifier do
  @moduledoc """
  The single "notify this user on their phone" entry point.

  Fans one notification out to every active device the user has registered,
  pruning tokens APNs reports dead. Callers decide *whether* to notify (the
  PushBroker's dedupe/budget/quiet-hours machinery); this module only
  decides *how*.
  """

  alias Maraithon.Push.APNS
  alias Maraithon.Push.Devices

  require Logger

  @doc """
  True when this user's proactive delivery should go to their phone instead
  of Telegram: the global switch is on, APNs is configured, and the user has
  at least one active registered device. The per-user device gate is what
  makes the hard cutover safe — a user with no phone registered keeps
  Telegram until the day they sign in on the app.
  """
  def enabled_for_user?(user_id) do
    enabled?() and APNS.configured?() and Devices.any_active?(user_id)
  end

  @doc """
  Sends an alert to every active device.

  Returns `{:ok, delivered_count}` when at least one device accepted,
  `{:error, :no_devices}` when none are registered, and
  `{:error, :undelivered}` when every send failed (dead tokens are pruned
  along the way; transient failures surface so the broker's cycle retries).
  """
  def notify(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    case Devices.active_for_user(user_id) do
      [] ->
        {:error, :no_devices}

      devices ->
        payload = APNS.payload(attrs)

        delivered =
          Enum.count(devices, fn device ->
            case APNS.send(device.device_token, payload, collapse_id: attrs[:collapse_id]) do
              :ok ->
                true

              {:error, :unregistered} ->
                _ = Devices.disable(device)
                false

              {:error, reason} ->
                Logger.warning("Push notification send failed",
                  user_id: user_id,
                  device_id: device.id,
                  reason: inspect(reason)
                )

                false
            end
          end)

        if delivered > 0, do: {:ok, delivered}, else: {:error, :undelivered}
    end
  end

  def enabled? do
    Application.get_env(:maraithon, :mobile_push, [])
    |> Keyword.get(:enabled, true)
    |> truthy?()
  end

  defp truthy?(value) when value in [true, "true", "1"], do: true
  defp truthy?(_value), do: false
end
