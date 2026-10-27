defmodule MaraithonWeb.MarketingControllerTest do
  use MaraithonWeb.ConnCase, async: true

  test "support page uses connected-app account language", %{conn: conn} do
    conn = get(conn, "/support")
    html = html_response(conn, 200)

    assert html =~ "connected-app access"
    assert html =~ "How do I disconnect an app?"
    assert html =~ "Open <strong>Connected Apps</strong>"
    refute html =~ "OAuth tokens"
    refute html =~ "OAuth token"
    refute html =~ "Settings &rarr; Connections"
    refute html =~ "disconnect an integration"
  end

  test "privacy page avoids implementation access terms", %{conn: conn} do
    conn = get(conn, "/privacy")
    html = html_response(conn, 200)

    assert html =~ "When you connect an app"
    assert html =~ "connection access encrypted at rest"
    assert html =~ "connected-app access"
    refute html =~ "OAuth tokens"
    refute html =~ "OAuth token"
    refute html =~ "todos"
  end

  test "terms page describes app permissions instead of the protocol", %{conn: conn} do
    conn = get(conn, "/terms")
    html = html_response(conn, 200)

    assert html =~ "Connected apps"
    assert html =~ "permissions shown during connection"
    refute html =~ "Connected integrations"
    refute html =~ "scopes shown during OAuth"
  end
end
