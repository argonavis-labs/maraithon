defmodule Maraithon.Tools.CompanionDevicesList do
  @moduledoc """
  List the Macs (and other companion devices) currently paired to the
  user, with last-seen timestamps and per-source mirrored-row counts.

  The assistant uses this to answer "what Macs am I paired on?" without
  guessing at hostnames or asking for the sync UI.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Companion.Devices

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      devices_with_stats =
        user_id
        |> Devices.list_for_user()
        |> Devices.enrich_with_stats()

      {:ok,
       %{
         source: "companion_devices",
         count: length(devices_with_stats),
         devices: Enum.map(devices_with_stats, &serialize/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp serialize({device, stats}) do
    %{
      id: device.id,
      device_id: device.device_id,
      device_name: device.device_name,
      last_seen_at: device.last_seen_at,
      paired_at: device.inserted_at,
      revoked: not is_nil(device.revoked_at),
      revoked_at: device.revoked_at,
      counts: stats
    }
  end
end
