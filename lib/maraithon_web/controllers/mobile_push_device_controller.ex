defmodule MaraithonWeb.MobilePushDeviceController do
  use MaraithonWeb, :controller

  alias Maraithon.Push.Devices
  alias Maraithon.Push.Notifier
  alias MaraithonWeb.MobileJSON

  def create(conn, params) do
    user_id = conn.assigns.current_user.id
    first_device? = not Devices.any_active?(user_id)

    attrs = %{
      "device_token" => params["device_token"],
      "platform" => params["platform"] || "ios",
      "app_version" => params["app_version"],
      "environment" => params["environment"]
    }

    case Devices.register(user_id, attrs) do
      {:ok, device} ->
        if first_device?, do: send_welcome_push(user_id)

        conn
        |> put_status(:created)
        |> json(%{device: device_json(device)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: MobileJSON.error(:invalid_params), details: changeset_errors(changeset)})
    end
  end

  def delete(conn, %{"device_token" => device_token}) do
    user_id = conn.assigns.current_user.id
    {:ok, _count} = Devices.unregister(user_id, device_token)
    send_resp(conn, :no_content, "")
  end

  # Confirms the channel works the moment a user's first device comes online —
  # the push the user sees right after granting notification permission.
  defp send_welcome_push(user_id) do
    Task.Supervisor.start_child(Maraithon.Runtime.EffectSupervisor, fn ->
      Notifier.notify(user_id, %{
        title: "Notifications are on",
        body: "Maraithon will reach you here — briefings, nudges, and chat replies.",
        deeplink: "maraithon://today",
        collapse_id: "push-welcome"
      })
    end)
  end

  defp device_json(device) do
    %{
      id: device.id,
      platform: device.platform,
      status: device.status,
      last_seen_at: device.last_seen_at
    }
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
