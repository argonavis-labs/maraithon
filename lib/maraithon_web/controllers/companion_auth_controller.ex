defmodule MaraithonWeb.CompanionAuthController do
  @moduledoc """
  Browser-facing pairing flow for the Maraithon Companion macOS app.

  The desktop app opens `/companion/auth?device_id=...&device_name=...`
  in the user's default browser. We render a one-screen consent. On
  approve we register the device, mint a long-lived bearer token, and
  redirect back to the app via the `maraithon://device-token/<token>`
  custom URL scheme. On deny we redirect to a denial page that the user
  can close.
  """

  use MaraithonWeb, :controller

  alias Maraithon.Companion.Devices

  @device_id_re ~r/\A[0-9a-fA-F-]{8,64}\z/

  def show(conn, params) do
    case sanitize(params) do
      {:ok, device_id, device_name} ->
        render(conn, :show,
          page_title: "Pair Companion",
          device_id: device_id,
          device_name: device_name,
          current_user: conn.assigns.current_user
        )

      :error ->
        conn
        |> put_flash(:error, "Missing or invalid device information.")
        |> redirect(to: ~p"/")
    end
  end

  def approve(conn, params) do
    case sanitize(params) do
      {:ok, device_id, device_name} ->
        user = conn.assigns.current_user

        case Devices.register(user.id, device_id, device_name: device_name) do
          {:ok, %{token: token}} ->
            redirect(conn, external: "maraithon://device-token/#{token}")

          {:error, _changeset} ->
            conn
            |> put_flash(
              :error,
              "Could not pair this device. Reopen the pairing request from the companion app."
            )
            |> redirect(
              to: ~p"/companion/auth?#{[device_id: device_id, device_name: device_name]}"
            )
        end

      :error ->
        conn
        |> put_flash(:error, "Missing or invalid device information.")
        |> redirect(to: ~p"/")
    end
  end

  def deny(conn, _params) do
    render(conn, :denied, page_title: "Pairing Denied", current_user: conn.assigns.current_user)
  end

  defp sanitize(params) do
    device_id = params["device_id"]
    device_name = params["device_name"]

    cond do
      is_binary(device_id) and Regex.match?(@device_id_re, device_id) ->
        {:ok, device_id, sanitize_name(device_name)}

      true ->
        :error
    end
  end

  defp sanitize_name(name) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "", do: nil, else: String.slice(trimmed, 0, 120)
  end

  defp sanitize_name(_), do: nil
end
