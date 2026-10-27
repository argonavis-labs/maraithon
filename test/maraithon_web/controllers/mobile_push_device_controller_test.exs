defmodule MaraithonWeb.MobilePushDeviceControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Push.Devices

  setup do
    email = "mobile-push-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)
    %{user: user, session_token: session_token}
  end

  test "registers and unregisters a device", %{conn: conn, user: user, session_token: token} do
    device_token = String.duplicate("a1", 32)

    conn =
      conn
      |> auth(token)
      |> post(~p"/api/mobile/push/devices", %{
        "device_token" => device_token,
        "app_version" => "1.4.0",
        "environment" => "production"
      })

    assert %{"device" => %{"status" => "active", "platform" => "ios"}} =
             json_response(conn, 201)

    assert [device] = Devices.active_for_user(user.id)
    assert device.device_token == device_token
    assert device.app_version == "1.4.0"

    conn =
      build_conn()
      |> auth(token)
      |> delete(~p"/api/mobile/push/devices/#{device_token}")

    assert response(conn, 204)
    assert Devices.active_for_user(user.id) == []
  end

  test "re-registering the same token is an upsert, not a duplicate", %{
    conn: conn,
    user: user,
    session_token: token
  } do
    device_token = String.duplicate("b2", 32)

    for version <- ["1.0.0", "1.1.0"] do
      build_conn()
      |> auth(token)
      |> post(~p"/api/mobile/push/devices", %{
        "device_token" => device_token,
        "app_version" => version
      })
      |> json_response(201)
    end

    assert [device] = Devices.active_for_user(user.id)
    assert device.app_version == "1.1.0"
    _ = conn
  end

  test "rejects unauthenticated registration", %{conn: conn} do
    conn = post(conn, ~p"/api/mobile/push/devices", %{"device_token" => "tok"})
    assert conn.status == 401
  end

  test "rejects an invalid token", %{conn: conn, session_token: token} do
    conn =
      conn
      |> auth(token)
      |> post(~p"/api/mobile/push/devices", %{"device_token" => "short"})

    assert %{"error" => _} = json_response(conn, 422)
  end

  defp auth(conn, session_token) do
    put_req_header(conn, "authorization", "Bearer #{session_token}")
  end
end
