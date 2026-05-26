defmodule MaraithonWeb.Plugs.RequireMobileSession do
  @moduledoc """
  Authenticates native mobile API requests with a persisted user session token.
  """

  import Plug.Conn

  alias Maraithon.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         session when not is_nil(session) <- Accounts.get_active_session(token),
         user when not is_nil(user) <- Accounts.get_user(session.user_id) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_user_session, session)
      |> assign(:current_user_session_token, token)
    else
      _ -> unauthorized(conn)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
