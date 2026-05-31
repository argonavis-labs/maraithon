defmodule MaraithonWeb.NavigationControllerTest do
  use MaraithonWeb.ConnCase, async: true

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Agents
  alias Maraithon.Companion.Devices
  alias Maraithon.ConnectedAccounts
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
  alias Maraithon.OAuth
  alias Maraithon.Repo

  describe "tab pages" do
    test "GET /connectors renders the connected apps page", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors")
      html = html_response(conn, 200)

      assert html =~ "Connected Apps"
      assert html =~ "Connect Telegram first so Maraithon can send proactive updates."
      assert html =~ "Maraithon Mac companion"
      assert html =~ "Google Workspace"
      assert html =~ "Notaui"
      assert html =~ "Slack"
      assert html =~ "Telegram required"
      assert html =~ "Connect Telegram first"
      assert html =~ "Set up Mac companion"
    end

    test "GET /connectors surfaces detected Mac companion sources without requiring Telegram", %{
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

      assert html =~ "Maraithon Mac companion"
      assert html =~ "1 Mac connected"
      assert html =~ "Synced 2 iMessages, 1 Apple Note."
      assert html =~ "View Mac companion"

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
      refute detail_html =~ "Connection Setup"
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
      assert detail_html =~ "2 Google permissions granted"
      assert detail_html =~ "1 Google permission granted"
      assert detail_html =~ "Disconnect"
      refute detail_html =~ "Stored Grant"
      refute detail_html =~ "Access Details"
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
      refute html =~ "re-authenticated"

      detail_conn = conn |> recycle() |> get("/connectors/google")
      detail_html = html_response(detail_conn, 200)

      assert detail_html =~ "Connected Accounts"
      assert detail_html =~ "founder@example.com"

      assert detail_html =~
               "Reconnect this account so Maraithon can keep syncing in the background."

      assert detail_html =~ "reconnect needed"
      assert detail_html =~ "Reconnect"
      assert detail_html =~ "Disconnect"
      refute detail_html =~ "Stored Grant"
      refute detail_html =~ "Token refresh failed"
      refute detail_html =~ "refresh token"
      refute detail_html =~ "re-authenticated"
    end

    test "GET /connectors/:provider renders provider details", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors/github")
      html = html_response(conn, 200)

      assert html =~ "Connected Apps"
      assert html =~ "GitHub"
      assert html =~ "0 accounts connected"
      assert html =~ "Connect Telegram first, then add GitHub."
      refute html =~ "No accounts connected."
      refute html =~ "No connected accounts yet."
      refute html =~ "Connection Setup"
      refute html =~ "Return URLs"
      refute html =~ "Setup Checklist"
    end

    test "GET /connectors/slack hides setup details for standard users", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors/slack")
      html = html_response(conn, 200)

      assert html =~ "Slack"
      refute html =~ "Connection Setup"
      refute html =~ "SLACK_SIGNING_SECRET"
      refute html =~ "/webhooks/slack"
    end

    test "GET /connectors/slack renders setup details for admins", %{conn: conn} do
      conn = conn |> log_in_admin_user() |> get("/connectors/slack")
      html = html_response(conn, 200)

      assert html =~ "Slack"
      assert html =~ "Connection Setup"
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
      assert html =~ "1 GitHub permission granted"
      refute html =~ ">Reconnect<"
      refute html =~ "Scopes:"
      refute html =~ "Permissions: repo"
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
      assert html =~ "1 Linear permission granted"
      refute html =~ ">Reconnect<"
      refute html =~ "Scopes:"
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
      refute html =~ "workspace-123"
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
      assert html =~ "Found 2 Notaui accounts Maraithon can use."
      assert html =~ "Task sync endpoint connected"
      assert html =~ "2 Notaui permissions granted"
      refute html =~ ">Reconnect<"
      refute html =~ "tasks:read"
      refute html =~ "tasks:write"
      refute html =~ "https://api.notaui.com/mcp"
      refute html =~ "MCP:"
      refute html =~ "Scopes:"
      assert html =~ "Disconnect"
    end

    test "GET /connectors/telegram shows connected chat details without linked copy", %{
      conn: conn
    } do
      user_id = "telegram-user@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _agent} =
        Agents.create_agent(%{
          user_id: user_id,
          behavior: "founder_followthrough_agent",
          config: %{"timezone" => "America/Toronto", "timezone_offset_hours" => -5}
        })

      {:ok, account} =
        ConnectedAccounts.upsert_manual(user_id, "telegram", %{
          external_account_id: "6114124042",
          metadata: %{"username" => "kentfenwick"}
        })

      Repo.update_all(
        from(connected_account in ConnectedAccount, where: connected_account.id == ^account.id),
        set: [updated_at: ~U[2026-05-30 18:30:00Z]]
      )

      conn = conn |> log_in_test_user(user_id) |> get("/connectors/telegram")
      html = html_response(conn, 200)

      assert html =~ "Delivery linked to @kentfenwick"
      assert html =~ "Last updated May 30, 2026 at 2:30 PM ET"
      refute html =~ "2026-05-30 18:30 UTC"
      refute html =~ "Chat ID 6114124042"
      refute html =~ "6114124042"
      refute html =~ "Linked chat"
    end

    test "GET /how-it-works renders the guide page", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/how-it-works")
      html = html_response(conn, 200)

      assert html =~ "How it works"
      assert html =~ "Operating loop"
      assert html =~ "Product standards"
      assert html =~ "Prepare the brief"
      assert html =~ "recommended next move"
      refute html =~ "webhook endpoints"
      refute html =~ "API ingress"
      refute html =~ "LLM provider"
      refute html =~ "queue depth"
      refute html =~ "raw logs"
      refute html =~ "Engineering principles"
    end

    test "GET /settings renders settings page", %{conn: conn} do
      conn = conn |> log_in_admin_user() |> get("/settings")
      html = html_response(conn, 200)

      assert html =~ "Settings"
      assert html =~ "Assistant readiness"
      assert html =~ "Access readiness"
      assert html =~ "Connected app readiness"
      assert html =~ "Assistant provider"
      assert html =~ "Response quality"
      assert html =~ "Analysis depth"
      assert html =~ "Action window"
      assert html =~ "Check-in cadence"
      assert html =~ "Account owner email"
      assert html =~ "Primary sign-in account for workspace administration."
      assert html =~ "setup status"
      refute html =~ "Primary model"
      refute html =~ "Connector readiness"
      refute html =~ "Assistant engine"
      refute html =~ "Response configuration"
      refute html =~ "Reasoning profile"
      refute html =~ "LLM provider"
      refute html =~ "LLM provider module"
      refute html =~ "Tool timeout (ms)"
      refute html =~ "Heartbeat interval (ms)"
      refute html =~ "PRIMARY_ADMIN_EMAIL"
      refute html =~ "POSTMARK_SERVER_TOKEN"
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
               "Connect Telegram before linking other apps."
    end
  end

  describe "connector actions" do
    test "POST /connectors/:provider/disconnect handles unsupported providers", %{conn: conn} do
      conn = conn |> log_in_test_user() |> post("/connectors/invalid/disconnect", %{})

      assert redirected_to(conn) == "/connectors"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That app connection is not available."
    end

    test "GET /connectors/:provider redirects unknown provider", %{conn: conn} do
      conn = conn |> log_in_test_user() |> get("/connectors/unknown")

      assert redirected_to(conn) == "/connectors"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That app connection is not available."
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
