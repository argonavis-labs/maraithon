defmodule Maraithon.Connectors.GmailAccessTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{Accounts, ConnectedAccounts, OAuth}
  alias Maraithon.Connectors.{Gmail, GmailAccess, SourceCursors}
  alias Maraithon.Tools.{GmailApiHelpers, GmailHelpers}

  setup do
    user = "gmail-admission-#{Ecto.UUID.generate()}@example.invalid"
    provider = "google:#{user}"
    {:ok, _} = Accounts.get_or_create_user_by_email(user)

    {:ok, _} =
      OAuth.store_tokens(user, provider, %{
        access_token: "initial-private-token",
        metadata: %{"account_email" => user}
      })

    account = ConnectedAccounts.get(user, provider)
    bypass = Bypass.open()
    previous = Application.get_env(:maraithon, :gmail, [])
    Application.put_env(:maraithon, :gmail, api_base_url: "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:maraithon, :gmail, previous) end)
    %{user: user, provider: provider, account: account, bypass: bypass}
  end

  test "a Google throttle blocks every Gmail surface even after token rotation", c do
    Bypass.expect_once(c.bypass, "GET", "/users/me/messages/aa11", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "90")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        403,
        Jason.encode!(%{
          "error" => %{
            "errors" => [%{"domain" => "usageLimits", "reason" => "userRateLimitExceeded"}]
          }
        })
      )
    end)

    {:ok, original} = GmailAccess.for_account(c.user, c.account.id)
    refute inspect(original) =~ "initial-private-token"

    assert {:error, {:rate_limited, 90, :provider_limited}} =
             Gmail.fetch_message(original, "aa11")

    {:ok, _} = OAuth.store_tokens(c.user, c.provider, %{access_token: "rotated-private-token"})
    {:ok, rotated} = GmailAccess.for_account(c.user, c.account.id)
    assert original.mailbox_key == rotated.mailbox_key
    assert rotated.token == "rotated-private-token"

    assert_cooldown(GmailApiHelpers.get_for_account(c.user, c.account.id, "/users/me/messages"))
    assert_cooldown(GmailHelpers.list_messages(c.user, provider: c.provider))

    assert_cooldown(
      Gmail.send_message(c.user, %{
        account_id: c.account.id,
        to: "recipient@example.invalid",
        subject: "Fixture",
        body: "Fixture"
      })
    )

    for method <- [:get, :post, :put, :patch, :delete] do
      assert_cooldown(
        GmailApiHelpers.request(
          %{"user_id" => c.user, "account" => c.user, "exact_account" => true},
          method,
          "/users/me/drafts",
          %{}
        )
      )
    end

    assert ConnectedAccounts.get(c.user, c.provider).status == "connected"
  end

  test "the mailbox key is shared by connections, ignores credential rotation, and separates mailboxes",
       c do
    first = GmailAccess.bind(c.account, "first-token")

    copy = %{
      c.account
      | id: c.account.id + 1,
        provider: "google",
        metadata: %{"email" => String.upcase(c.user), "account_email" => "  "}
    }

    assert GmailAccess.bind(copy, "second-token").mailbox_key == first.mailbox_key
    different = %{copy | metadata: %{"email" => "different@example.invalid"}}
    refute GmailAccess.bind(different, "first-token").mailbox_key == first.mailbox_key
    refute first.mailbox_key =~ c.user
  end

  test "bare tokens cannot bypass mailbox admission on either Gmail API hostname" do
    for url <- [
          "https://gmail.googleapis.com/gmail/v1/users/me/messages",
          "https://www.googleapis.com/gmail/v1/users/me/messages"
        ] do
      assert {:error, :gmail_account_required} = OAuth.Google.api_request(:get, url, "raw-token")
    end
  end

  test "incremental sync preserves its cursor and retry deadline when hydration is throttled",
       c do
    {:ok, _} = SourceCursors.put(c.account, "gmail_history_id", %{"value" => "100"})

    Bypass.expect_once(c.bypass, "GET", "/users/me/history", fn conn ->
      json(conn, %{
        "historyId" => "101",
        "history" => [
          %{"messagesAdded" => Enum.map(["aa11", "aa22", "aa33"], &%{"message" => %{"id" => &1}})}
        ]
      })
    end)

    throttle_hydration(c)

    assert {:error, {:rate_limited, 90, :provider_limited}} =
             Gmail.sync_history(c.user, c.account)

    assert SourceCursors.get(c.account.id, "gmail_history_id").value == "100"
  end

  test "a full resync cannot report a complete mailbox after hydration is throttled", c do
    Bypass.expect_once(c.bypass, "GET", "/users/me/messages", fn conn ->
      json(conn, %{"messages" => Enum.map(["aa11", "aa22", "aa33"], &%{"id" => &1})})
    end)

    throttle_hydration(c)

    assert {:error, {:rate_limited, 90, :provider_limited}} =
             Gmail.sync_history(c.user, c.account)

    assert SourceCursors.get(c.account.id, "gmail_history_id") == nil
  end

  defp throttle_hydration(c) do
    Bypass.expect_once(c.bypass, "GET", "/users/me/messages/aa11", fn conn ->
      json(conn, %{"id" => "aa11", "threadId" => "bb11", "payload" => %{"headers" => []}})
    end)

    Bypass.expect_once(c.bypass, "GET", "/users/me/messages/aa22", fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "90") |> Plug.Conn.resp(429, "wait")
    end)
  end

  defp assert_cooldown(result) do
    assert {:error, {:rate_limited, seconds, :provider_cooldown}} = result
    assert seconds in 85..90
  end

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
end
