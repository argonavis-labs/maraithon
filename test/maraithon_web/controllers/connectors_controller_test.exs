defmodule MaraithonWeb.ConnectorsControllerTest do
  use MaraithonWeb.ConnCase, async: true

  test "a read-only assistant mailbox shows the missing send permission and the correct consent link",
       %{conn: conn} do
    user = "connector-permissions-#{Ecto.UUID.generate()}@example.invalid"
    conn = log_in_test_user(conn, user)
    provider = "google:october@example.invalid"
    readonly = Maraithon.OAuth.Google.scopes_for(["gmail", "calendar", "contacts"])

    {:ok, _} =
      Maraithon.OAuth.store_tokens(user, provider, %{
        access_token: "connector-test-token",
        refresh_token: "connector-test-refresh",
        expires_in: 3600,
        scopes: readonly,
        metadata: %{"account_email" => "october@example.invalid", "assistant_account" => true}
      })

    response = get(conn, "/connectors/google")
    html = html_response(response, 200)
    assert html =~ "Gmail sending permission needed"
    assert html =~ "Gmail (read only)"
    assert html =~ "Google Calendar (read only)"

    [link] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("a")
      |> Enum.filter(&(LazyHTML.text(&1) =~ "Enable Gmail sending"))

    [href] = LazyHTML.attribute(link, "href")
    params = href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["scopes"] == "gmail_compose"
    assert params["purpose"] == "assistant"
    assert params["login_hint"] == "october@example.invalid"
    assert params["return_to"] == "/connectors/google"
    refute html =~ "connector-test-token"

    {:ok, _} =
      Maraithon.OAuth.store_tokens(user, provider, %{
        access_token: "connector-test-token",
        scopes: readonly ++ Maraithon.OAuth.Google.scopes_for(["gmail_compose"])
      })

    html = response |> recycle() |> get("/connectors/google") |> html_response(200)
    assert html =~ "Gmail (read and send)"
    refute html =~ "Gmail sending permission needed"
    refute html =~ "Enable Gmail sending"
  end

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
    refute html =~ "Connect Telegram first"
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
