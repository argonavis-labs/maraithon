defmodule Maraithon.Accounts.MagicLinkSenderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Maraithon.Accounts.MagicLinkSender

  setup do
    previous = Application.get_env(:maraithon, MagicLinkSender)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:maraithon, MagicLinkSender)
        config -> Application.put_env(:maraithon, MagicLinkSender, config)
      end
    end)

    :ok
  end

  test "classifies suppressed recipients without logging provider or credential detail" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/email", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-postmark-server-token") == ["server-token"]
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(request_body)
      send(test_pid, {:postmark_recipient, decoded["To"]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        422,
        Jason.encode!(%{
          "ErrorCode" => 406,
          "Message" => "provider-secret-detail"
        })
      )
    end)

    Application.put_env(:maraithon, MagicLinkSender,
      server_token: "server-token",
      from: "Maraithon <login@example.com>",
      message_stream: "outbound",
      api_url: "http://localhost:#{bypass.port}/email"
    )

    recipient = "suppressed@example.com"
    link = "https://example.com/auth/magic/secret-link-token"

    log =
      capture_log(fn ->
        assert {:error, :email_suppressed} = MagicLinkSender.deliver(recipient, link)
      end)

    assert_received {:postmark_recipient, ^recipient}
    assert log =~ "Magic sign-in email rejected"
    refute log =~ "provider-secret-detail"
    refute log =~ recipient
    refute log =~ "secret-link-token"
    refute log =~ "server-token"
  end

  test "does not follow redirects with credentials or issue a second POST" do
    source = Bypass.open()
    sink = Bypass.open()
    test_pid = self()

    Bypass.stub(sink, "POST", "/capture", fn conn ->
      send(test_pid, :redirected_postmark_request)
      Plug.Conn.resp(conn, 200, "{}")
    end)

    Bypass.expect_once(source, "POST", "/email", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://localhost:#{sink.port}/capture")
      |> Plug.Conn.resp(307, "")
    end)

    Application.put_env(:maraithon, MagicLinkSender,
      server_token: "redirect-server-token",
      from: "Maraithon <login@example.com>",
      api_url: "http://localhost:#{source.port}/email"
    )

    assert {:error, :email_delivery_rejected} =
             MagicLinkSender.deliver_code("redirect@example.com", "123 456")

    refute_received :redirected_postmark_request
  end

  test "treats provider server responses as ambiguous without retrying" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/email", fn conn ->
      send(test_pid, :postmark_server_request)
      Plug.Conn.resp(conn, 500, ~s({"ErrorCode":0,"Message":"provider detail"}))
    end)

    Application.put_env(:maraithon, MagicLinkSender,
      server_token: "server-error-token",
      from: "Maraithon <login@example.com>",
      api_url: "http://localhost:#{bypass.port}/email"
    )

    assert {:error, :email_delivery_unknown} =
             MagicLinkSender.deliver_code("server-error@example.com", "123 456")

    assert_receive :postmark_server_request
    refute_received :postmark_server_request
  end

  test "transport ambiguity is not retried and exposes no delivery content" do
    bypass = Bypass.open()
    Bypass.down(bypass)

    Application.put_env(:maraithon, MagicLinkSender,
      server_token: "transport-server-token",
      from: "Maraithon <login@example.com>",
      api_url: "http://localhost:#{bypass.port}/email"
    )

    recipient = "transport@example.com"
    code = "123 456"

    log =
      capture_log(fn ->
        assert {:error, :email_delivery_unknown} =
                 MagicLinkSender.deliver_code(recipient, code)
      end)

    assert log =~ "Magic sign-in email result is unknown"
    refute log =~ recipient
    refute log =~ code
    refute log =~ "transport-server-token"
  end

  test "invalid provider configuration fails closed without string crashes" do
    Application.put_env(:maraithon, MagicLinkSender, %{server_token: <<255>>})

    assert {:error, :email_provider_unavailable} =
             MagicLinkSender.deliver("valid@example.com", "https://example.com/auth/magic/value")

    Application.put_env(:maraithon, MagicLinkSender,
      server_token: "   ",
      from: "   "
    )

    assert :ok =
             MagicLinkSender.deliver("valid@example.com", "https://example.com/auth/magic/value")
  end

  test "disabled delivery logs only a fingerprint and never the link or recipient" do
    Application.put_env(:maraithon, MagicLinkSender, server_token: "", from: "")

    recipient = "fallback@example.com"
    link = "https://example.com/auth/magic/fallback-secret"

    log = capture_log(fn -> assert :ok = MagicLinkSender.deliver(recipient, link) end)

    assert log =~ "Magic sign-in delivery fallback (log-only)"
    refute log =~ recipient
    refute log =~ "fallback-secret"
  end

  test "rejects oversized and invalid UTF-8 delivery inputs before rendering" do
    Application.put_env(:maraithon, MagicLinkSender, server_token: "", from: "")

    assert {:error, :invalid_delivery_payload} =
             MagicLinkSender.deliver(String.duplicate("a", 321), "https://example.com")

    assert {:error, :invalid_delivery_payload} =
             MagicLinkSender.deliver("valid@example.com", <<255>>)
  end
end
