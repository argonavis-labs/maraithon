defmodule MaraithonWeb.AdminControllerTest do
  use MaraithonWeb.ConnCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentSubscriptions
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.ActionLedger
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Effects.Effect
  alias Maraithon.Events
  alias Maraithon.Insights
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Repo
  alias Maraithon.Runtime.ScheduledJob
  alias Maraithon.Todos

  defmodule RefreshRuntimeStub do
    def send_message(agent_id, "refresh_insights", metadata) do
      send(self(), {:refresh_message, agent_id, metadata})
      {:ok, %{message_id: "refresh-" <> String.slice(agent_id, 0, 8)}}
    end
  end

  setup do
    Repo.delete_all(Agent)

    previous_refresh = Application.get_env(:maraithon, Maraithon.Insights.Refresh, [])

    Application.put_env(:maraithon, Maraithon.Insights.Refresh,
      runtime_module: RefreshRuntimeStub
    )

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Insights.Refresh, previous_refresh)
    end)

    :ok
  end

  describe "GET /api/v1/admin/dashboard" do
    test "returns fleet snapshot with spend and logs", %{conn: conn} do
      Maraithon.LogBuffer.clear()

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "stopped"
        })

      {:ok, _event} = Events.append(agent.id, "dashboard_event", %{ok: true})

      Maraithon.LogBuffer.record(%{
        level: :info,
        message: "dashboard log entry",
        metadata: %{agent_id: agent.id}
      })

      _ = :sys.get_state(Maraithon.LogBuffer)

      on_exit(fn ->
        Maraithon.LogBuffer.clear()
      end)

      conn = get(conn, "/api/v1/admin/dashboard")

      response = json_response(conn, 200)
      assert Map.has_key?(response, "health")
      assert Map.has_key?(response, "queue_metrics")
      assert Map.has_key?(response, "total_spend")
      assert Enum.any?(response["recent_activity"], &(&1["event_type"] == "dashboard_event"))
      assert Enum.any?(response["recent_logs"], &(&1["message"] == "dashboard log entry"))
    end
  end

  describe "POST /api/v1/admin/diagnostics/export" do
    test "generates a redacted diagnostics bundle and ledgers the export", %{conn: conn} do
      user_id = "diagnostics-admin-#{System.unique_integer([:positive])}@example.com"

      output_dir =
        Path.join(
          System.tmp_dir!(),
          "maraithon-diagnostics-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf(output_dir) end)

      conn =
        post(conn, "/api/v1/admin/diagnostics/export", %{
          "user_id" => user_id,
          "limit" => "5",
          "output_dir" => output_dir
        })

      response = json_response(conn, 200)

      assert response["output_dir"] == output_dir
      assert "manifest.json" in response["files"]
      assert "trust_metrics.json" in response["files"]
      assert File.exists?(Path.join(output_dir, "redaction_manifest.json"))

      assert [action | _] =
               ActionLedger.list_recent(user_id,
                 event_type: "external_action.changed",
                 limit: 5
               )

      assert action.surface == "admin_api"
      assert action.metadata["file_count"] == length(response["files"])
    end
  end

  describe "POST /api/v1/admin/chief-of-staff/ensure" do
    test "repairs a chief of staff agent from live source scope", %{conn: conn} do
      user_id = "ensure-chief@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _google} =
        OAuth.store_tokens(user_id, "google:kent@example.com", %{
          access_token: "google-token",
          scopes: Google.scopes_for(["gmail", "calendar"]),
          metadata: %{"account_email" => "kent@example.com"}
        })

      {:ok, _slack} =
        OAuth.store_tokens(user_id, "slack:T12345", %{
          access_token: "xoxb-token",
          scopes: ["channels:read"],
          metadata: %{"team_id" => "T12345", "team_name" => "Agora"}
        })

      {:ok, _telegram} =
        ConnectedAccounts.upsert_manual(user_id, "telegram", %{
          external_account_id: "6114124042",
          metadata: %{"chat_id" => "6114124042"}
        })

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "ai_chief_of_staff",
          config: %{"user_id" => user_id, "name" => "Kent Chief"},
          status: "stopped"
        })

      conn = post(conn, "/api/v1/admin/chief_of_staff/ensure", %{"user_id" => user_id})

      response = json_response(conn, 200)
      assert response["status"] == "updated"
      assert response["agent"]["id"] == agent.id
      assert response["agent"]["user_id"] == user_id
      assert response["agent"]["config"]["name"] == "Kent Chief"
      assert response["source_scope"]["telegram_connected"] == true

      assert response["subscriptions"] == [
               "email:kent@example.com",
               "calendar:ensure-chief@example.com",
               "slack:T12345"
             ]

      updated = Agents.get_agent(agent.id)
      assert updated.user_id == user_id

      assert AgentSubscriptions.list_for_agent(agent.id)
             |> Enum.map(&{&1.user_id, &1.topic})
             |> Enum.sort() == [
               {user_id, "calendar:ensure-chief@example.com"},
               {user_id, "email:kent@example.com"},
               {user_id, "slack:T12345"}
             ]
    end
  end

  describe "GET /api/v1/admin/agents/:id/inspection" do
    test "returns agent inspection payload", %{conn: conn} do
      Maraithon.LogBuffer.clear()

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{"name" => "inspectable"},
          status: "stopped"
        })

      {:ok, _event} = Events.append(agent.id, "inspection_event", %{message: "ready"})

      {:ok, _effect} =
        %Effect{}
        |> Effect.changeset(%{
          id: Ecto.UUID.generate(),
          agent_id: agent.id,
          idempotency_key: Ecto.UUID.generate(),
          effect_type: "tool_call",
          status: "pending",
          attempts: 1
        })
        |> Maraithon.Repo.insert()

      {:ok, _job} =
        %ScheduledJob{}
        |> ScheduledJob.changeset(%{
          agent_id: agent.id,
          job_type: "heartbeat",
          fire_at: DateTime.utc_now(),
          status: "pending",
          attempts: 1
        })
        |> Maraithon.Repo.insert()

      Maraithon.LogBuffer.record(%{
        level: :warning,
        message: "inspection log entry",
        metadata: %{agent_id: agent.id}
      })

      _ = :sys.get_state(Maraithon.LogBuffer)

      on_exit(fn ->
        Maraithon.LogBuffer.clear()
      end)

      conn = get(conn, "/api/v1/admin/agents/#{agent.id}/inspection")

      response = json_response(conn, 200)
      assert response["agent"]["id"] == agent.id
      assert response["spend"]["llm_calls"] == 0
      assert Enum.any?(response["events"], &(&1["event_type"] == "inspection_event"))
      assert response["inspection"]["effect_counts"]["pending"] == 1
      assert response["inspection"]["job_counts"]["pending"] == 1

      assert Enum.any?(
               response["inspection"]["recent_logs"],
               &(&1["message"] == "inspection log entry")
             )
    end
  end

  describe "GET /api/v1/admin/fly/logs" do
    test "returns configured Fly platform logs", %{conn: conn} do
      previous = Application.get_env(:maraithon, Maraithon.FlyLogs, [])
      bypass = Bypass.open()

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.FlyLogs, previous)
      end)

      Application.put_env(:maraithon, Maraithon.FlyLogs,
        api_token: "FlyV1 test-token",
        api_base_url: "http://localhost:#{bypass.port}/api/v1",
        apps: ["maraithon", "maraithon-db"],
        region: "yyz",
        receive_timeout_ms: 1_000
      )

      Bypass.expect_once(bypass, "GET", "/api/v1/apps/maraithon-db/logs", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["FlyV1 test-token"]
        assert URI.decode_query(conn.query_string) == %{"region" => "yyz"}

        body = %{
          "data" => [
            %{
              "id" => "db-log-1",
              "attributes" => %{
                "timestamp" => "2026-03-09T12:15:00Z",
                "message" => "database machine restarted",
                "level" => "warn",
                "instance" => "db-machine",
                "region" => "yyz",
                "meta" => %{"event" => %{"provider" => "runner"}}
              }
            }
          ],
          "meta" => %{"next_token" => "db-next"}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      conn = get(conn, "/api/v1/admin/fly/logs?app=maraithon-db&limit=25")

      response = json_response(conn, 200)
      assert response["available"] == true
      assert response["apps"] == ["maraithon-db"]
      assert response["next_tokens"] == %{"maraithon-db" => "db-next"}

      assert Enum.any?(response["logs"], fn log ->
               log["message"] == "database machine restarted" and
                 log["metadata"]["provider"] == "runner"
             end)
    end

    test "falls back to configured Fly app list when app param is omitted", %{conn: conn} do
      previous = Application.get_env(:maraithon, Maraithon.FlyLogs, [])
      bypass = Bypass.open()

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.FlyLogs, previous)
      end)

      Application.put_env(:maraithon, Maraithon.FlyLogs,
        api_token: "FlyV1 test-token",
        api_base_url: "http://localhost:#{bypass.port}/api/v1",
        apps: ["maraithon"],
        region: "yyz",
        receive_timeout_ms: 1_000
      )

      Bypass.expect_once(bypass, "GET", "/api/v1/apps/maraithon/logs", fn conn ->
        assert URI.decode_query(conn.query_string) == %{"region" => "yyz"}

        body = %{
          "data" => [
            %{
              "id" => "app-log-1",
              "attributes" => %{
                "timestamp" => "2026-03-09T12:16:00Z",
                "message" => "app machine booted",
                "level" => "info",
                "instance" => "app-machine",
                "region" => "yyz",
                "meta" => %{"event" => %{"provider" => "app"}}
              }
            }
          ],
          "meta" => %{}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      conn = get(conn, "/api/v1/admin/fly/logs?limit=5")

      response = json_response(conn, 200)
      assert response["available"] == true
      assert response["apps"] == ["maraithon"]
      assert Enum.any?(response["logs"], &(&1["message"] == "app machine booted"))
    end
  end

  describe "GET /api/v1/admin/connections" do
    test "returns provider setup guidance and stored grants", %{conn: conn} do
      previous_google = Application.get_env(:maraithon, :google, [])
      previous_github = Application.get_env(:maraithon, :github, [])
      previous_linear = Application.get_env(:maraithon, :linear, [])
      previous_notaui = Application.get_env(:maraithon, :notaui, [])
      previous_notion = Application.get_env(:maraithon, :notion, [])
      previous_slack = Application.get_env(:maraithon, :slack, [])

      on_exit(fn ->
        Application.put_env(:maraithon, :google, previous_google)
        Application.put_env(:maraithon, :github, previous_github)
        Application.put_env(:maraithon, :linear, previous_linear)
        Application.put_env(:maraithon, :notaui, previous_notaui)
        Application.put_env(:maraithon, :notion, previous_notion)
        Application.put_env(:maraithon, :slack, previous_slack)
      end)

      Application.put_env(:maraithon, :google,
        client_id: "google-client",
        client_secret: "google-secret",
        redirect_uri: "https://maraithon.fly.dev/auth/google/callback",
        calendar_webhook_url: "https://maraithon.fly.dev/webhooks/google/calendar",
        pubsub_topic: "projects/acme/topics/gmail"
      )

      Application.put_env(:maraithon, :github,
        client_id: "github-client",
        client_secret: "github-secret",
        redirect_uri: "https://maraithon.fly.dev/auth/github/callback",
        webhook_secret: "github-webhook",
        api_token: ""
      )

      Application.put_env(:maraithon, :linear,
        client_id: "linear-client",
        client_secret: "linear-secret",
        redirect_uri: "https://maraithon.fly.dev/auth/linear/callback",
        webhook_secret: "linear-webhook"
      )

      Application.put_env(:maraithon, :notion,
        client_id: "notion-client",
        client_secret: "notion-secret",
        redirect_uri: "https://maraithon.fly.dev/auth/notion/callback"
      )

      Application.put_env(:maraithon, :notaui,
        client_id: "notaui-client",
        client_secret: "notaui-secret",
        redirect_uri: "https://maraithon.fly.dev/auth/notaui/callback",
        issuer: "https://api.notaui.com",
        auth_url: "https://api.notaui.com/oauth/authorize",
        token_url: "https://api.notaui.com/oauth/token",
        mcp_url: "https://api.notaui.com/mcp"
      )

      Application.put_env(:maraithon, :slack,
        client_id: "slack-client",
        client_secret: "slack-secret",
        redirect_uri: "https://maraithon.fly.dev/auth/slack/callback",
        signing_secret: "slack-signing"
      )

      {:ok, _token} =
        OAuth.store_tokens("kent", "github", %{
          access_token: "github-token",
          scopes: ["repo", "user:email"],
          metadata: %{login: "kent", email: "kent@example.com"}
        })

      conn = get(conn, "/api/v1/admin/connections?user_id=kent")

      response = json_response(conn, 200)
      assert response["user_id"] == "kent"
      assert response["connected_count"] >= 1
      assert length(response["providers"]) == 8
      assert Enum.any?(response["raw_tokens"], &(&1["provider"] == "github"))

      desktop =
        Enum.find(response["providers"], fn provider ->
          provider["provider"] == "desktop"
        end)

      assert desktop["logo"] == "desktop"
      assert desktop["setup_status"] == "configured"
      assert desktop["requires_telegram?"] == false
      assert Enum.any?(desktop["services"], &(&1["label"] == "iMessage"))
      assert Enum.any?(desktop["permissions"], &(&1 =~ "Apple Notes"))

      github =
        Enum.find(response["providers"], fn provider ->
          provider["provider"] == "github"
        end)

      assert github["status"] == "connected"
      assert github["logo"] == "github"
      assert github["setup_status"] == "configured"
      assert Enum.any?(github["callback_urls"], &(&1["label"] == "OAuth callback"))

      assert Enum.any?(github["env_requirements"], fn env ->
               env["name"] == "GITHUB_CLIENT_ID" and env["present?"] == true
             end)

      google =
        Enum.find(response["providers"], fn provider ->
          provider["provider"] == "google"
        end)

      assert Enum.any?(
               google["permissions"],
               &(&1 == "Google Contacts read-only People API access")
             )

      assert Enum.any?(google["callback_urls"], &(&1["label"] == "Gmail Pub/Sub push callback"))

      slack =
        Enum.find(response["providers"], fn provider ->
          provider["provider"] == "slack"
        end)

      assert slack["logo"] == "slack"
      assert Enum.any?(slack["callback_urls"], &(&1["url"] =~ "/webhooks/slack"))
      assert Enum.any?(slack["env_requirements"], &(&1["name"] == "SLACK_SIGNING_SECRET"))

      notaui =
        Enum.find(response["providers"], fn provider ->
          provider["provider"] == "notaui"
        end)

      assert notaui["logo"] == "notaui"
      assert Enum.any?(notaui["callback_urls"], &(&1["url"] =~ "/auth/notaui/callback"))
      assert Enum.any?(notaui["env_requirements"], &(&1["name"] == "NOTAUI_CLIENT_ID"))
    end
  end

  describe "DELETE /api/v1/admin/connections/:provider" do
    test "disconnects a stored provider token", %{conn: conn} do
      {:ok, _token} =
        OAuth.store_tokens("kent", "github", %{
          access_token: "github-token",
          scopes: ["repo"],
          metadata: %{login: "kent"}
        })

      conn = delete(conn, "/api/v1/admin/connections/github?user_id=kent")

      response = json_response(conn, 200)
      assert response["status"] == "disconnected"
      assert response["provider"] == "github"
      assert OAuth.get_token("kent", "github") == nil
    end
  end

  describe "admin todo cleanup" do
    test "lists and dismisses matching todos while syncing linked insights", %{conn: conn} do
      user_id = "kent@runner.now"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, agent} =
        Agents.create_agent(%{
          user_id: user_id,
          behavior: "inbox_calendar_advisor",
          config: %{},
          status: "running"
        })

      {:ok, [insight]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply owed: stale thread",
            "summary" => "This looked urgent but is not relevant anymore.",
            "recommended_action" => "Ignore this stale thread.",
            "priority" => 96,
            "confidence" => 0.9,
            "dedupe_key" => "gmail:stale-thread",
            "tracking_key" => "gmail:thread:stale-thread"
          }
        ])

      [todo] = Todos.list_for_user(user_id, query: "stale thread")

      list_conn =
        get(conn, "/api/v1/admin/todos?user_id=#{URI.encode_www_form(user_id)}&query=stale")

      list_response = json_response(list_conn, 200)

      assert list_response["count"] == 1
      assert [%{"id" => todo_id, "status" => "open"}] = list_response["todos"]
      assert todo_id == todo.id

      dismiss_conn =
        post(conn, "/api/v1/admin/todos/dismiss", %{
          "user_id" => user_id,
          "query" => "stale thread",
          "reason" => "Dismissed as irrelevant."
        })

      dismiss_response = json_response(dismiss_conn, 200)
      assert dismiss_response["matched_count"] == 1
      assert dismiss_response["dismissed_count"] == 1
      assert [%{"id" => ^todo_id, "status" => "dismissed"}] = dismiss_response["dismissed"]

      assert Repo.reload!(todo).status == "dismissed"
      assert Repo.reload!(insight).status == "dismissed"
    end

    test "requires an explicit selector before dismissing todos", %{conn: conn} do
      conn =
        post(conn, "/api/v1/admin/todos/dismiss", %{
          "user_id" => "kent@runner.now"
        })

      response = json_response(conn, 400)
      assert response["error"] == "invalid_params"
      assert response["message"] =~ "provide todo_ids"
    end
  end

  describe "POST /api/v1/admin/insights/refresh" do
    test "queues refresh for running insight-producing agents for the requested user", %{
      conn: conn
    } do
      {:ok, running_agent} =
        Agents.create_agent(%{
          user_id: "kent@runner.now",
          behavior: "founder_followthrough_agent",
          config: %{},
          status: "running"
        })

      {:ok, stopped_agent} =
        Agents.create_agent(%{
          user_id: "kent@runner.now",
          behavior: "slack_followthrough_agent",
          config: %{},
          status: "stopped"
        })

      {:ok, _other_agent} =
        Agents.create_agent(%{
          user_id: "kent@runner.now",
          behavior: "prompt_agent",
          config: %{},
          status: "running"
        })

      conn =
        post(conn, "/api/v1/admin/insights/refresh", %{
          "user_id" => "kent@runner.now",
          "reason" => "refresh_after_new_logic"
        })

      running_agent_id = running_agent.id

      response = json_response(conn, 200)
      assert response["user_id"] == "kent@runner.now"
      assert response["eligible_count"] == 2
      assert response["queued_count"] == 1

      assert [%{"agent_id" => queued_agent_id, "behavior" => "founder_followthrough_agent"}] =
               response["queued"]

      assert queued_agent_id == running_agent.id

      assert Enum.any?(response["skipped"], fn skipped ->
               skipped["agent_id"] == stopped_agent.id and
                 skipped["reason"] == "agent_not_running"
             end)

      assert_receive {:refresh_message, ^running_agent_id, metadata}
      assert metadata["action"] == "refresh_insights"
      assert metadata["reset_open_insights"] == true
      assert metadata["reason"] == "refresh_after_new_logic"
    end
  end
end
