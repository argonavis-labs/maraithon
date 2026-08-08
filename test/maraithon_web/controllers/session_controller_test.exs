defmodule MaraithonWeb.SessionControllerTest do
  use MaraithonWeb.ConnCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Accounts.MagicLinkSender
  alias Maraithon.Accounts.{MagicLink, UserSession}
  alias Maraithon.Repo

  test "GET / renders magic-link sign-in page", %{conn: conn} do
    conn = get(conn, "/")

    assert html_response(conn, 200) =~ "Sign in"
  end

  test "POST /auth/magic-link issues a magic link", %{conn: conn} do
    email = "magic-link-#{System.unique_integer([:positive])}@example.com"

    conn = post(conn, "/auth/magic-link", %{"magic_link" => %{"email" => email}})

    assert redirected_to(conn, 303) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Check your email"

    assert %MagicLink{sent_to_email: ^email} = Repo.get_by(MagicLink, sent_to_email: email)
  end

  test "POST /auth/magic-link reports a definitive email rejection", %{conn: conn} do
    bypass = Bypass.open()
    previous = Application.get_env(:maraithon, MagicLinkSender)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:maraithon, MagicLinkSender)
        config -> Application.put_env(:maraithon, MagicLinkSender, config)
      end
    end)

    Bypass.expect_once(bypass, "POST", "/email", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(422, Jason.encode!(%{"ErrorCode" => 406}))
    end)

    Application.put_env(:maraithon, MagicLinkSender,
      server_token: "server-token",
      from: "Maraithon <login@example.com>",
      api_url: "http://localhost:#{bypass.port}/email"
    )

    email = "suppressed-#{System.unique_integer([:positive])}@example.com"
    conn = post(conn, "/auth/magic-link", %{"magic_link" => %{"email" => email}})

    assert redirected_to(conn, 303) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "cannot receive sign-in links"
    refute Phoenix.Flash.get(conn.assigns.flash, :info)
  end

  test "GET /auth/magic/:token signs in and creates session", %{conn: conn} do
    email = "session-#{System.unique_integer([:positive])}@example.com"
    {:ok, %{token: token, user: user}} = Accounts.request_magic_link(email)

    conn = get(conn, "/auth/magic/#{token}")

    assert redirected_to(conn) == "/dashboard"
    assert token = get_session(conn, "user_session_token")
    assert %UserSession{user_id: user_id} = Accounts.get_active_session(token)
    assert user_id == user.id
  end

  test "DELETE /logout revokes active session", %{conn: conn} do
    conn = log_in_test_user(conn, "user@example.com")
    token = get_session(conn, "user_session_token")

    conn = delete(conn, "/logout")

    assert redirected_to(conn, 303) == "/"

    session = Accounts.get_active_session(token)
    assert is_nil(session)
  end

  test "protected pages redirect when unauthenticated", %{conn: conn} do
    conn = get(conn, "/connectors")

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign in"
  end
end
