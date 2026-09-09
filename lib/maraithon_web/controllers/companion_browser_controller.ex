defmodule MaraithonWeb.CompanionBrowserController do
  use MaraithonWeb, :controller
  alias Maraithon.TodoBrowser

  def claim(conn, params) do
    {:ok, command} = TodoBrowser.claim(conn.assigns.current_device, params["available"] == true)
    json(conn, %{command: command, user_id: conn.assigns.current_user_id})
  end

  def complete(conn, %{"id" => id, "result" => result}) do
    case TodoBrowser.complete(conn.assigns.current_device, id, result) do
      :ok -> json(conn, %{accepted: true})
      {:error, :already_settled} -> json(conn, %{accepted: false})
      {:error, _} -> conn |> put_status(:bad_request) |> json(%{error: "invalid_browser_result"})
    end
  end
end
