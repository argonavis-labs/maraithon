defmodule MaraithonWeb.PwaStaticTest do
  use MaraithonWeb.ConnCase, async: true

  test "serves PWA manifest, service worker, and offline shell", %{conn: conn} do
    manifest_conn = get(conn, "/manifest.webmanifest")
    manifest = response(manifest_conn, 200)

    assert get_resp_header(manifest_conn, "content-type") == ["application/manifest+json"]
    assert manifest =~ ~s("name": "Maraithon")
    assert manifest =~ ~s("display": "standalone")
    assert manifest =~ ~s("/images/app-icon-512.png")
    assert manifest =~ "chief-of-staff workspace"
    assert manifest =~ ~s("name": "Work")
    assert manifest =~ "current work queue"
    assert manifest =~ "Open relationship context"
    refute manifest =~ "agent runtime"
    refute manifest =~ ~s("name": "Todos")
    refute manifest =~ "todo command surface"
    refute manifest =~ "relationship CRM"

    sw_conn = conn |> recycle() |> get("/sw.js")
    sw = response(sw_conn, 200)

    assert get_resp_header(sw_conn, "content-type") == ["text/javascript"]
    assert sw =~ "maraithon-pwa-v1"
    assert sw =~ "/offline.html"
    assert sw =~ "request.mode === \"navigate\""

    offline_conn = conn |> recycle() |> get("/offline.html")
    offline = html_response(offline_conn, 200)

    assert offline =~ "You are offline"
    assert offline =~ "Maraithon needs a connection"
    assert offline =~ "current work"
    assert offline =~ "relationships"
    refute offline =~ "live agents"
    refute offline =~ "todos"
  end

  test "authenticated app shell renders mobile PWA metadata and tab bar", %{conn: conn} do
    conn =
      conn
      |> log_in_test_user("pwa-shell@example.com")
      |> get("/connectors")

    html = html_response(conn, 200)

    assert html =~ ~s(content="width=device-width, initial-scale=1, viewport-fit=cover")
    assert html =~ ~s(name="theme-color")
    assert html =~ ~s(name="apple-mobile-web-app-capable")
    assert html =~ ~s(rel="manifest")
    assert html =~ "navigator.serviceWorker.register"
    assert html =~ ~s(id="maraithon-mobile-tabbar")
    assert html =~ ~s(data-command-palette-trigger="true")
  end
end
