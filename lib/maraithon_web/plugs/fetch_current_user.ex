defmodule MaraithonWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Loads the current user from the persisted session token.
  """

  import Plug.Conn

  alias Maraithon.Accounts

  require Logger

  @session_key "user_session_token"

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, @session_key) do
      token when is_binary(token) and token != "" ->
        case Accounts.get_user_by_session_token(token) do
          nil ->
            log_diag(conn, "token_present_lookup_nil")
            conn
            |> delete_session(@session_key)
            |> assign(:current_user, nil)

          user ->
            log_diag(conn, "ok", user.email)
            assign(conn, :current_user, user)
        end

      _ ->
        log_diag(conn, "no_token")
        assign(conn, :current_user, nil)
    end
  end

  defp log_diag(conn, outcome, email \\ nil) do
    if String.starts_with?(conn.request_path, "/companion") or
         String.starts_with?(conn.request_path, "/auth") do
      Logger.info("FetchCurrentUser",
        path: conn.request_path,
        query: conn.query_string,
        outcome: outcome,
        email: email,
        cookie_header_present: get_req_header(conn, "cookie") != [],
        session_keys: get_session(conn) |> Map.keys()
      )
    end
  end
end
