defmodule Maraithon.Delegations.GmailTransportTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{Accounts, ConnectedAccounts, OAuth}
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Delegations.Scope

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:maraithon, :gmail, [])
    Application.put_env(:maraithon, :gmail, api_base_url: "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:maraithon, :gmail, original) end)
    user_id = "delegation-mail-#{System.unique_integer([:positive])}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _} =
      OAuth.store_tokens(user_id, "google:eval", %{
        access_token: "bound-mailbox",
        refresh_token: "fixture",
        expires_in: 3600,
        scopes: ["https://www.googleapis.com/auth/gmail.compose"]
      })

    account = ConnectedAccounts.get(user_id, "google:eval")

    %{
      bypass: bypass,
      user_id: user_id,
      attrs: %{
        account_id: account.id,
        from: "kent@runner.now",
        to: "kent.fenwick@gmail.com",
        subject: "[Maraithon eval] Information",
        body: "Can you confirm the test colour?\n\n-Kent",
        thread_id: "aabbcc",
        reply_to_message_id: "112233",
        message_id_header: "<maraithon.eval@maraithon.com>"
      }
    }
  end

  test "both people can be Kent without dropping the counterparty address" do
    message = %{from: "Kent <kent.fenwick@gmail.com>", to: "Kent <kent@runner.now>"}
    assert Scope.counterparties(message, ["kent@runner.now"]) == ["kent.fenwick@gmail.com"]

    assert Scope.counterparties(%{from: message.to, to: message.from}, ["kent@runner.now"]) ==
             ["kent.fenwick@gmail.com"]
  end

  test "verified From, frozen Message-ID and parent references survive the reply", c do
    sender(c.bypass)
    parent(c.bypass)

    Bypass.expect_once(c.bypass, "POST", "/users/me/messages/send", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer bound-mailbox"]
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      assert body["threadId"] == "aabbcc"
      mime = Base.url_decode64!(body["raw"], padding: false)
      assert mime =~ "From: kent@runner.now\r\n"
      assert mime =~ "To: kent.fenwick@gmail.com\r\n"
      assert mime =~ "Message-ID: <maraithon.eval@maraithon.com>\r\n"
      assert mime =~ ~r/Date: \w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} \+0000\r\n/
      assert mime =~ "In-Reply-To: <parent@example.invalid>\r\n"
      assert mime =~ "References: <root@example.invalid> <parent@example.invalid>\r\n"
      json(conn, %{"id" => "445566", "threadId" => "aabbcc"})
    end)

    assert {:ok, %{message_id: "445566", thread_id: "aabbcc", provider: "google:eval"}} =
             Gmail.send_message(c.user_id, c.attrs)
  end

  test "a deleted parent blocks the send instead of starting an unrelated thread", c do
    sender(c.bypass)

    Bypass.expect_once(c.bypass, "GET", "/users/me/messages/112233", fn conn ->
      Plug.Conn.resp(conn, 404, "")
    end)

    assert {:error, _} = Gmail.send_message(c.user_id, c.attrs)
  end

  test "a parent in another thread cannot redirect the reply", c do
    sender(c.bypass)
    parent(c.bypass, "different")
    assert {:error, :reply_thread_mismatch} = Gmail.send_message(c.user_id, c.attrs)
  end

  test "header injection is rejected before a provider write", c do
    assert {:error, :invalid_mail_headers} =
             Gmail.send_message(c.user_id, %{
               c.attrs
               | subject: "Test\r\nBcc: attacker@example.invalid"
             })
  end

  test "an unverified sender cannot send as the other Kent", c do
    sender(c.bypass)

    assert {:error, :unverified_sender} =
             Gmail.send_message(c.user_id, %{c.attrs | from: "kent.fenwick@gmail.com"})
  end

  test "a missing account cannot silently switch mailboxes", c do
    assert {:error, :invalid_google_account} =
             Gmail.send_message(c.user_id, %{c.attrs | account_id: -1})
  end

  defp sender(bypass) do
    Bypass.expect_once(bypass, "GET", "/users/me/settings/sendAs", fn conn ->
      json(conn, %{"sendAs" => [%{"sendAsEmail" => "kent@runner.now", "isPrimary" => true}]})
    end)
  end

  defp parent(bypass, thread \\ "aabbcc") do
    Bypass.expect_once(bypass, "GET", "/users/me/messages/112233", fn conn ->
      json(conn, %{
        "id" => "112233",
        "threadId" => thread,
        "labelIds" => ["INBOX"],
        "payload" => %{
          "headers" => [
            %{"name" => "Message-ID", "value" => "<parent@example.invalid>"},
            %{"name" => "References", "value" => "<root@example.invalid>"}
          ]
        }
      })
    end)
  end

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
end
