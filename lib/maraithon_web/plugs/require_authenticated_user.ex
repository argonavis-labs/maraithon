defmodule MaraithonWeb.Plugs.RequireAuthenticatedUser do
  @moduledoc """
  Redirects unauthenticated browser requests to the sign-in page.
  """

  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> stash_return_to()
      |> put_flash(:error, "Sign in to continue.")
      |> redirect(to: "/")
      |> halt()
    end
  end

  # Stash the original GET URL so `consume_magic_link` can return the user
  # to where they were going (e.g. /companion/auth?device_id=...).
  defp stash_return_to(conn) do
    if conn.method == "GET" do
      path =
        case conn.query_string do
          "" -> conn.request_path
          qs -> "#{conn.request_path}?#{qs}"
        end

      put_session(conn, :return_to, path)
    else
      conn
    end
  end
end
