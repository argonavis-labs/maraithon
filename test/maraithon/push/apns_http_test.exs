defmodule Maraithon.Push.APNS.HTTPTest do
  use ExUnit.Case, async: false

  alias Maraithon.Push.APNS.HTTP

  setup do
    previous = Application.get_env(:maraithon, HTTP)
    finch_name = :"apns-http-test-#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: finch_name})
    Application.put_env(:maraithon, HTTP, finch_name: finch_name)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:maraithon, HTTP)
        config -> Application.put_env(:maraithon, HTTP, config)
      end
    end)

    :ok
  end

  test "warms the connection with a safe HEAD before issuing one POST" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect_once(bypass, "HEAD", "/", fn conn ->
      send(test_pid, :preflight_received)
      Plug.Conn.resp(conn, 405, "")
    end)

    Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:post_received, body})
      Plug.Conn.resp(conn, 200, "")
    end)

    assert {:ok, 200, ""} =
             HTTP.post(
               "http://localhost:#{bypass.port}/3/device/token",
               [{"content-type", "application/json"}],
               ~s({"aps":{}})
             )

    assert_received :preflight_received
    assert_received {:post_received, ~s({"aps":{}})}
    refute_received {:post_received, _other_body}
  end

  test "an HTTP status remains definitive when the diagnostic body exceeds its cap" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "HEAD", "/", fn conn ->
      Plug.Conn.resp(conn, 405, "")
    end)

    Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
      Plug.Conn.resp(conn, 410, String.duplicate("x", 20_000))
    end)

    assert {:ok, 410, ""} =
             HTTP.post(
               "http://localhost:#{bypass.port}/3/device/token",
               [{"content-type", "application/json"}],
               ~s({"aps":{}})
             )
  end
end
