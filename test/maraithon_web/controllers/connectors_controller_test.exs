defmodule MaraithonWeb.ConnectorsControllerTest do
  use MaraithonWeb.ConnCase, async: true

  test "oauth flash messages hide technical details", %{conn: conn} do
    conn =
      conn
      |> log_in_test_user("connector-flash@example.com")
      |> get(
        "/connectors?oauth_status=error&oauth_message=DBConnection.ConnectionError token=secret stacktrace"
      )

    html = html_response(conn, 200)

    assert html =~ "App connection did not finish. Reopen the connector and complete sign-in."
    refute html =~ "try again"
    refute html =~ "DBConnection"
    refute html =~ "token=secret"
    refute html =~ "stacktrace"
  end

  test "connected apps page avoids implementation setup language", %{conn: conn} do
    conn =
      conn
      |> log_in_test_user("connected-apps-copy@example.com")
      |> get("/connectors")

    html = html_response(conn, 200)

    assert html =~ "Connected Apps"
    assert html =~ "Connect Telegram first so Maraithon can send proactive updates."
    assert html =~ "Connection needed"
    refute html =~ "OAuth"
    refute html =~ "Configure OAuth first"
    refute html =~ "Setup needed"
  end

  test "unknown connector paths use product-safe copy", %{conn: conn} do
    conn =
      conn
      |> log_in_test_user("connector-unknown@example.com")
      |> get("/connectors/%7Btoken%3Dsecret%7D")

    assert redirected_to(conn) == "/connectors"

    conn = get(recycle(conn), "/connectors")
    html = html_response(conn, 200)

    assert html =~ "That app connection is not available."
    refute html =~ "token=secret"
  end
end
