defmodule MaraithonWeb.ControlController do
  use MaraithonWeb, :controller

  alias Maraithon.ControlProtocol

  def handle(conn, params) do
    if payload_too_large?(conn) do
      conn
      |> put_status(:payload_too_large)
      |> json(%{
        "jsonrpc" => "2.0",
        "id" => request_id(params),
        "error" => %{
          "code" => -32075,
          "message" => "Control payload exceeds max size",
          "data" => %{"max_bytes" => ControlProtocol.max_payload_bytes()}
        }
      })
    else
      json(conn, ControlProtocol.response_for(params))
    end
  end

  defp payload_too_large?(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) -> byte_size(body) > ControlProtocol.max_payload_bytes()
      _other -> false
    end
  end

  defp request_id(%{"id" => id}), do: id
  defp request_id(_params), do: nil
end
