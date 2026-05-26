defmodule MaraithonWeb.NavigationControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Companion.Devices
  alias Maraithon.ConnectedAccounts
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
  alias Maraithon.OAuth

  describe "tab pages" do
    test "GET /connectors renders the connectors page", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors")
      html = html_response(conn, 200)

      assert html =~ "Connectors"
      assert html =~ "Maraithon needs a Telegram chat"
      assert html =~ "Maraithon Desktop App"
      assert html =~ "Google Workspace"
      assert html =~ "Notaui"
      assert html =~ "Slack"
      assert html =~ "Telegram required"
      assert html =~ "Connect Telegram first"
      assert html =~ "Set up Desktop App"
    end

    test "GET /connectors surfaces detected Desktop App sources without requiring Telegram", %{
      conn: conn
    } do
      user_id = "desktop-connectors@example.com"
      device_id = Ecto.UUID.generate()
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      {:ok, %{device: device}} = Devices.register(user_id, device_id, device_name: "Kent MacBook")

      {:ok, %{accepted: 2}} =
        LocalMessages.ingest_batch(user_id, device.device_id, [
          %{
            "guid" => "message-1",
            "text" => "Can you send the files?",
            "sent_at" => "2026-05-25T10:00:00Z"
          },
          %{
            "guid" => "message-2",
            "text" => "Following up here.",
            "sent_at" => "2026-05-25T10:05:00Z"
          }
        ])

      {:ok, %{accepted: 1}} =
        LocalNotes.ingest_batch(user_id, device.device_id, [
          %{
            "guid" => "note-1",
            "title" => "Family weekend plan",
            "modified_at" => "2026-05-25T12:00:00Z"
          }
        ])

      conn = conn |> log_in_test_user(user_id) |> get("/connectors")
      html = html_response(conn, 200)

      assert html =~ "Maraithon Desktop App"
      assert html =~ "1 Mac connected"
      assert html =~ "Synced 2 iMessages, 1 Apple Note."
      assert html =~ "View Desktop App"

      detail_conn = conn |> recycle() |> get("/connectors/desktop")
      detail_html = html_response(detail_conn, 200)

      assert detail_html =~ "Paired Macs"
      assert detail_html =~ "Kent MacBook"
      assert detail_html =~ "2 iMessages"
      assert detail_html =~ "1 Apple Note"
      assert detail_html =~ "iMessage"
      assert detail_html =~ "Apple Notes"
      assert detail_html =~ "Secure local sync"
      refute detail_html =~ "Telegram required"
      refute detail_html =~ "OAuth setup"
      refute detail_html =~ "Disconnect"
    end

    test "GET /connectors renders with connected Slack tokens", %{conn: conn} do
      user_id = "slack-connectors@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _bot} =
        OAuth.store_tokens(user_id, "slack:T12345", %{
          access_token: "xoxb-test-token",
          scopes: ["channels:read", "im:read"],
          metadata: %{"team_id" => "T12345", "team_name" => "Agora"}
        })

      {:ok, _user_token} =
        OAuth.store_tokens(user_id, "slack:T12345:user:U99999", %{
          access_token: "xoxp-test-token",
          scopes: ["search:read", "im:read", "chat:write"],
          metadata: %{
            "team_id" => "T12345",
            "team_name" => "Agora",
            "slack_user_id" => "U99999"
          }
        })

      conn = conn |> log_in_test_user(user_id) |> get("/connectors")
      html = html_response(conn, 200)

      assert html =~ "Slack"
      assert html =~ "1 workspace connected"
      refute html =~ "Agora"

      detail_conn = conn |> recycle() |> get("/connectors/slack")
      detail_html = html_response(detail_conn, 200)

      assert detail_html =~ "Connected Workspaces"
      assert detail_html =~ "Agora"
      assert detail_html =~ "1 workspace connected"
      assert detail_html =~ "DMs, private context, and posting as you enabled"
      assert detail_html =~ "Channel events and mentions enabled"
      refute detail_html =~ "Agora · Bot"
      refute detail_html =~ "Agora · DM user"
      refute detail_html =~ "Stored Grant"
      refute detail_html =~ "Connection Details"
    end

    test "GET /connectors summarizes Google accounts and detail page lists each email", %{
      conn: conn
    } do
      user_id = "google-multi@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _first} =
        OAuth.store_tokens(user_id, "google:founder@example.com", %{
          access_token: "google-token-1",
          scopes: [
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/calendar.readonly"
          ],
          metadata: %{"account_email" => "founder@example.com"}
        })

      {:ok, _second} =
        OAuth.store_tokens(user_id, "google:ops@example.com", %{
          access_token: "google-token-2",
          scopes: ["https://www.googleapis.com/auth/contacts.readonly"],
          metadata: %{"account_email" => "ops@example.com"}
        })

      conn = conn |> log_in_test_user(user_id) |> get("/connectors")
      html = html_response(conn, 200)

      assert html =~ "2 accounts connected"
      refute html =~ "founder@example.com"
      refute html =~ "ops@example.com"
      refute html =~ "Disconnect"

      detail_conn = conn |> recycle() |> get("/connectors/google")
      detail_html = html_response(detail_conn, 200)

      assert detail_html =~ "Connected Accounts"
      assert detail_html =~ "2 accounts connected"
      assert detail_html =~ "founder@example.com"
      assert detail_html =~ "ops@example.com"
      assert detail_html =~ "Enabled: Gmail, Google Calendar"
      assert detail_html =~ "Enabled: Google Contacts"
      assert detail_html =~ "Granted 2 Google OAuth scopes"
      assert detail_html =~ "Granted 1 Google OAuth scope"
      assert detail_html =~ "Disconnect"
      refute detail_html =~ "Stored Grant"
      refute detail_html =~ "Connection Details"
    end

    test "GET /connectors shows refresh-required summary and detail-level Google account action",
         %{
           conn: conn
         } do
      user_id = "google-refresh-needed@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      connect_telegram(user_id)

      {:ok, _token} =
        OAuth.store_tokens(user_id, "google:founder@example.com", %{
          access_token: "google-token-1",
          refresh_token: "refresh-token-1",
          metadata: %{"account_email" => "founder@example.com"}
        })

      {:ok, _account} =
        ConnectedAccounts.mark_error(
          user_id,
          "google:founder@example.com",
          "oauth_reauth_required"
        )

      conn = conn |> log_in_test_user(user_id) |> get("/connectors")
      html = html_response(conn, 200)

      assert html =~ "1 account needs attention"
      refute html =~ "Token refresh failed and the account must be re-authenticated."

      detail_conn = conn |> recycle() |> get("/connectors/google")
      detail_html = html_response(detail_conn, 200)

      assert detail_html =~ "Connected Accounts"
      assert detail_html =~ "founder@example.com"
      assert detail_html =~ "Token refresh failed and the account must be re-authenticated."
      assert detail_html =~ "refresh inactive"
      assert detail_html =~ "Reconnect"
      assert detail_html =~ "Disconnect"
      refute detail_html =~ "Stored Grant"
    end

    test "GET /connectors/:provider renders provider details", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors/github")
      html = html_response(conn, 200)

      assert html =~ "Connectors"
      assert html =~ "GitHub"
      assert html =~ "OAuth setup"
    end

    test "GET /connectors/slack renders slack setup details", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors/slack")
      html = html_response(conn, 200)

      assert html =~ "Slack"
      assert html =~ "OAuth setup"
      assert html =~ "SLACK_SIGNING_SECRET"
      assert html =~ "/webhooks/slack"
    end

    test "GET /connectors/github shows account-level disconnect controls for healthy account", %{
      conn: conn
    } do
      user_id = "github-detail@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      connect_telegram(user_id)

      {:ok, _token} =
        OAuth.store_tokens(user_id, "github", %{
          access_token: "github-token",
          scopes: ["repo"],
          metadata: %{"login" => "octocat", "email" => "octocat@example.com"}
        })

      conn = conn |> log_in_test_user(user_id) |> get("/connectors/github")
      html = html_response(conn, 200)

      assert html =~ "Connected Accounts"
      assert html =~ "@octocat"
      refute html =~ ">Reconnect<"
      assert html =~ "Disconnect"
    end

    test "GET /connectors/linear shows account-level disconnect controls for healthy account", %{
      conn: conn
    } do
      user_id = "linear-detail@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      connect_telegram(user_id)

      {:ok, _token} =
        OAuth.store_tokens(user_id, "linear", %{
          access_token: "linear-token",
          scopes: ["read"],
          metadata: %{"teams" => [%{"name" => "Platform", "key" => "PLT"}]}
        })

      conn = conn |> log_in_test_user(user_id) |> get("/connectors/linear")
      html = html_response(conn, 200)

      assert html =~ "Connected Accounts"
      assert html =~ "Platform"
      refute html =~ ">Reconnect<"
      assert html =~ "Disconnect"
    end

    test "GET /connectors/notion shows account-level disconnect controls for healthy account", %{
      conn: conn
    } do
      user_id = "notion-detail@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      connect_telegram(user_id)

      {:ok, _token} =
        OAuth.store_tokens(user_id, "notion", %{
          access_token: "notion-token",
          scopes: [],
          metadata: %{"workspace_name" => "Agora Docs", "workspace_id" => "workspace-123"}
        })

      conn = conn |> log_in_test_user(user_id) |> get("/connectors/notion")
      html = html_response(conn, 200)

      assert html =~ "Connected Accounts"
      assert html =~ "Agora Docs"
      refute html =~ ">Reconnect<"
      assert html =~ "Disconnect"
    end

    test "GET /connectors/notaui shows account-level disconnect controls for healthy account", %{
      conn: conn
    } do
      user_id = "notaui-detail@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      connect_telegram(user_id)

      {:ok, _token} =
        OAuth.store_tokens(user_id, "notaui", %{
          access_token: "notaui-token",
          refresh_token: "notaui-refresh",
          scopes: ["tasks:read", "tasks:write"],
          external_account_id: "acct-default",
          metadata: %{
            "issuer" => "https://api.notaui.com",
            "mcp_url" => "https://api.notaui.com/mcp",
            "default_account_id" => "acct-default",
            "default_account_label" => "Personal",
            "account_count" => 2,
            "accounts" => [
              %{"id" => "acct-default", "label" => "Personal", "is_default" => true},
              %{"id" => "acct-team", "label" => "Team Workspace", "is_default" => false}
            ]
          }
        })

      conn = conn |> log_in_test_user(user_id) |> get("/connectors/notaui")
      html = html_response(conn, 200)

      assert html =~ "Connected Accounts"
      assert html =~ "Default account: Personal"
      assert html =~ "Discovered 2 accessible accounts"
      assert html =~ "https://api.notaui.com/mcp"
      refute html =~ ">Reconnect<"
      assert html =~ "Disconnect"
    end

    test "GET /connectors/telegram shows connected chat details without linked copy", %{
      conn: conn
    } do
      user_id = "telegram-user@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _account} =
        ConnectedAccounts.upsert_manual(user_id, "telegram", %{
          external_account_id: "6114124042",
          metadata: %{"username" => "kentfenwick"}
        })

      conn = conn |> log_in_test_user(user_id) |> get("/connectors/telegram")
      html = html_response(conn, 200)

      assert html =~ "Chat ID 6114124042"
      assert html =~ "@kentfenwick"
      refute html =~ "Linked chat"
    end

    test "GET /how-it-works renders the guide page", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/how-it-works")
      html = html_response(conn, 200)

      assert html =~ "How it works"
      assert html =~ "Execution flow"
      assert html =~ "Engineering principles"
    end

    test "GET /settings renders settings page", %{conn: conn} do
      conn = conn |> log_in_admin_user() |> get("/settings")
      html = html_response(conn, 200)

      assert html =~ "Settings"
      assert html =~ "Security secrets"
      assert html =~ "OAuth provider readiness"
    end

    test "GET /conenctors redirects to /connectors", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/conenctors")
      assert redirected_to(conn) == "/connectors"
    end

    test "GET /auth/google requires telegram before starting OAuth", %{conn: conn} do
      user_id = "oauth-telegram-required-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      conn =
        conn
        |> log_in_test_user(user_id)
        |> get("/auth/google", %{
          "user_id" => user_id,
          "scopes" => "gmail",
          "return_to" => "/connectors"
        })

      assert redirected_to(conn) == "/connectors"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Connect Telegram before linking other connectors."
    end
  end

  describe "connector actions" do
    test "POST /connectors/:provider/disconnect handles unsupported providers", %{conn: conn} do
      conn = conn |> log_in_test_user() |> post("/connectors/invalid/disconnect", %{})

      assert redirected_to(conn) == "/connectors"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Unsupported provider"
    end

    test "GET /connectors/:provider redirects unknown provider", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors/unknown")

      assert redirected_to(conn) == "/connectors"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Unknown connector: unknown"
    end

    test "POST /connectors/google/disconnect can remove a specific Google account", %{conn: conn} do
      user_id = "google-disconnect@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _first} =
        OAuth.store_tokens(user_id, "google:founder@example.com", %{
          access_token: "google-token-1",
          metadata: %{"account_email" => "founder@example.com"}
        })

      {:ok, _second} =
        OAuth.store_tokens(user_id, "google:ops@example.com", %{
          access_token: "google-token-2",
          metadata: %{"account_email" => "ops@example.com"}
        })

      conn =
        conn
        |> log_in_test_user(user_id)
        |> post("/connectors/google/disconnect", %{
          "provider_key" => "google:ops@example.com",
          "account_label" => "ops@example.com"
        })

      assert redirected_to(conn) == "/connectors"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Google account ops@example.com disconnected"

      assert OAuth.get_token(user_id, "google:ops@example.com") == nil
      assert OAuth.get_token(user_id, "google:founder@example.com")
    end
  end

  defp connect_telegram(user_id) do
    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "telegram-chat-#{System.unique_integer([:positive])}",
        metadata: %{"username" => "test-user"}
      })

    :ok
  end
end
