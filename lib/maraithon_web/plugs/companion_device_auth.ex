defmodule MaraithonWeb.Plugs.CompanionDeviceAuth do
  @moduledoc """
  Bearer-token plug for companion desktop endpoints.

  Reads `Authorization: Bearer <token>`, looks the token up via
  `Maraithon.Companion.Devices.verify_token/1`, and on success:

    * assigns `:current_device` and `:current_user_id` on the conn
    * bumps `last_seen_at` so connector health surfaces "stale" devices

  On failure, halts with `401` and a JSON `{"error": "unauthorized"}`.
  """

  import Plug.Conn

  alias Maraithon.Companion.Devices

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer_token(conn) do
      {:ok, token} ->
        case Devices.verify_token(token) do
          nil ->
            auth_failure(conn, :invalid_token)

          device ->
            device = Devices.touch_last_seen(device)

            conn
            |> assign(:current_device, device)
            |> assign(:current_user_id, device.user_id)
        end

      :error ->
        auth_failure(conn, :missing_token)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp auth_failure(conn, reason) do
    :telemetry.execute(
      [:maraithon, :companion, :auth_failure],
      %{count: 1},
      %{reason: reason}
    )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
