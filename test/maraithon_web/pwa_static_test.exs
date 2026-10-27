defmodule MaraithonWeb.PwaStaticTest do
  use MaraithonWeb.ConnCase, async: true

  test "serves PWA manifest, service worker, and offline shell", %{conn: conn} do
    manifest_conn = get(conn, "/manifest.webmanifest")
    manifest = response(manifest_conn, 200)

    assert get_resp_header(manifest_conn, "content-type") == ["application/manifest+json"]
    assert manifest =~ ~s("name": "Maraithon")
    assert manifest =~ ~s("display": "standalone")
    assert manifest =~ ~s("/images/app-icon-512.png")
    assert manifest =~ "focused todo list"
    assert manifest =~ ~s("id": "/todos")
    assert manifest =~ ~s("start_url": "/todos")
    assert manifest =~ ~s("name": "Todos")
    assert manifest =~ "Open your todo list"
    assert manifest =~ ~s("name": "Apps")
    assert manifest =~ "Manage connected apps and sources"
    refute manifest =~ ~s("name": "Dashboard")
    refute manifest =~ ~s("name": "People")
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
    assert offline =~ "todo list"
    assert offline =~ "supporting details"
    assert offline =~ "next-step guidance"
    refute offline =~ "relationships"
    refute offline =~ "live agents"
  end

  test "authenticated app shell renders PWA metadata without competing navigation", %{conn: conn} do
    conn =
      conn
      |> log_in_test_user("pwa-shell@example.com")
      |> get("/todos")

    html = html_response(conn, 200)

    assert html =~ ~s(content="width=device-width, initial-scale=1, viewport-fit=cover")
    assert html =~ ~s(name="theme-color")
    assert html =~ ~s(name="apple-mobile-web-app-capable")
    assert html =~ ~s(rel="manifest")
    assert html =~ ~s(src="/assets/app.js")
    assert html =~ "Maraithon"
    assert html =~ "Todos"
    refute html =~ ~s(id="maraithon-mobile-tabbar")
    refute html =~ ~s(id="maraithon-sidebar")
    assert html =~ ~s(href="/connectors")
    assert html =~ "Apps"
  end
end
