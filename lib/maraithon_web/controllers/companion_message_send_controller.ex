defmodule MaraithonWeb.CompanionMessageSendController do
  use MaraithonWeb, :controller

  def claim(conn, params) do
    case Maraithon.MessageSend.claim(conn.assigns.current_device, params["available"] == true) do
      {:ok, command} ->
        json(conn, %{command: command})

      {:error, _} ->
        conn |> put_status(:forbidden) |> json(%{error: "Message sending is unavailable."})
    end
  end

  def complete(conn, %{"id" => id, "result" => result}) do
    case Maraithon.MessageSend.complete(conn.assigns.current_device, id, result) do
      :ok ->
        json(conn, %{accepted: true})

      {:error, :already_settled} ->
        json(conn, %{accepted: false})

      {:error, _} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid message receipt."})
    end
  end
end
