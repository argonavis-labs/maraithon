defmodule MaraithonWeb.MobilePushDeviceController do
  use MaraithonWeb, :controller

  alias Maraithon.Push.Devices
  alias MaraithonWeb.MobileJSON

  def create(conn, params) do
    user_id = conn.assigns.current_user.id

    attrs = %{
      "device_token" => params["device_token"],
      "platform" => params["platform"] || "ios",
      "app_version" => params["app_version"],
      "environment" => params["environment"]
    }

    case Devices.register(user_id, attrs) do
      {:ok, device} ->
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
