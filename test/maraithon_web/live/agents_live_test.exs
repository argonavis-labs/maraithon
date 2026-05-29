defmodule MaraithonWeb.AgentsLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Effects.Effect
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.ScheduledJob

  @user_email "agents@example.com"

  setup %{conn: conn} do
    Maraithon.LogBuffer.clear()

    on_exit(fn ->
      Maraithon.LogBuffer.clear()
    end)

    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "highlights the Automations tab on /agents", %{conn: conn} do
    {:ok, view, html} = live(conn, "/agents")

    assert html =~ "Automations"
    assert has_element?(view, "a[href='/agents'][aria-current='page']", "Automations")
  end

  test "renders empty registry and empty workspace states", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/agents")

    assert html =~ "No automations yet."
    assert html =~ "Start with a template"
  end

  test "registry rows describe what automations do and which connectors they inspect", %{
    conn: conn
  } do
    {:ok, _agent} =
      create_agent(%{
        behavior: "inbox_calendar_advisor",
        config: %{"name" => "chief", "subscribe" => ["gmail:inbox"]},
        status: "stopped"
      })

    {:ok, _view, html} = live(conn, "/agents")

    assert html =~ "Automations"
    assert html =~ "Watches inbox and calendar context"
    assert html =~ "Google Gmail"
    assert html =~ "Slack Channels"
    assert html =~ "Telegram"
  end

  test "selecting an agent opens inspect mode", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "inspect-me"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, "/agents")

    view
    |> element("tr[phx-click=select_agent][phx-value-id='#{agent.id}']")
    |> render_click()

    assert_patch(view, "/agents?id=#{agent.id}")

    html = render(view)
    assert html =~ "Overview"
    assert html =~ "inspect-me"
  end

  test "edit opens edit mode for the selected agent", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "edit-me"},
        status: "stopped"
      })

    {:ok, view, _html} = live(conn, "/agents?id=#{agent.id}")

    view
    |> element("a[href='/agents?id=#{agent.id}&panel=edit']", "Settings")
    |> render_click()

    assert_patch(view, "/agents?id=#{agent.id}&panel=edit")

    html = render(view)
    assert html =~ "Instructions"
    assert html =~ "Save changes"
  end

  test "start action updates the visible status", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "starter"},
        status: "stopped"
      })

    {:ok, view, _html} = live(conn, "/agents?id=#{agent.id}")

    view
    |> element(
      "button[phx-click=start_agent][phx-value-id=\"#{agent.id}\"][phx-value-surface=workspace]"
    )
    |> render_click()

    assert Agents.get_agent!(agent.id).status == "running"

    assert has_element?(
             view,
             "button[phx-click=stop_agent][phx-value-id=\"#{agent.id}\"]",
             "Stop"
           )

    assert render(view) =~ "Automation started"

    stop_agent_process(agent.id)
  end

  test "stop action updates the visible status", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "stopper"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, "/agents?id=#{agent.id}")

    view
    |> element(
      "button[phx-click=stop_agent][phx-value-id=\"#{agent.id}\"][phx-value-surface=workspace]"
    )
    |> render_click()

    assert Agents.get_agent!(agent.id).status == "stopped"

    assert has_element?(
             view,
             "button[phx-click=start_agent][phx-value-id=\"#{agent.id}\"]",
             "Start"
           )

    assert render(view) =~ "Automation paused"
  end

  test "delete removes the row and clears selection", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "delete-me"},
        status: "stopped"
      })

    {:ok, view, _html} = live(conn, "/agents?id=#{agent.id}")

    view
    |> element(
      "button[phx-click=delete_agent][phx-value-id=\"#{agent.id}\"][phx-value-surface=\"workspace\"]"
    )
    |> render_click()

    assert_patch(view, "/agents")
    assert Agents.get_agent(agent.id) == nil

    html = render(view)
    refute html =~ agent.id
    assert html =~ "No automations yet."
  end

  test "selected inspection shows logs, events, queue, spend, and config", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{
          "name" => "inspected-agent",
          "prompt" => "Inspect me",
          "budget" => %{"llm_calls" => 100, "tool_calls" => 50}
        },
        status: "stopped"
      })

    {:ok, _event} =
      Maraithon.Events.append(agent.id, "inspection_ready", %{
        message: "DBConnection.ConnectionError token=secret stacktrace"
      })

    {:ok, _effect} =
      %Effect{}
      |> Effect.changeset(%{
        id: Ecto.UUID.generate(),
        agent_id: agent.id,
        idempotency_key: Ecto.UUID.generate(),
        effect_type: "tool_call",
        status: "failed",
        attempts: 2,
        error: "Tool failed: DBConnection.ConnectionError token=secret stacktrace"
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
      message: "agent inspection log",
      metadata: %{agent_id: agent.id}
    })

    Maraithon.LogBuffer.record(%{
      level: :error,
      message: "DBConnection.ConnectionError token=secret stacktrace",
      metadata: %{agent_id: agent.id, token: "secret"}
    })

    _ = :sys.get_state(Maraithon.LogBuffer)

    {:ok, view, _html} = live(conn, "/agents?id=#{agent.id}")
    html = render(view)

    assert html =~ "Work in progress"
    assert html =~ "Action"
    assert html =~ "Upcoming checks"
    assert html =~ "Heartbeat"
    assert html =~ "Recent updates"
    assert html =~ "Inspection ready"
    assert html =~ "Recorded automation activity."
    assert html =~ "Usage"
    assert html =~ "Current settings"
    assert html =~ "agent inspection log"
    assert html =~ "Automation notes"
    assert html =~ "Diagnostic details are hidden from this view."
    assert html =~ "Action failed. Check the connection and try again."
    assert html =~ "Operating model"
    assert html =~ "Run controls"
    assert html =~ "Maraithon Automation Service"
    assert html =~ "Automation"
    refute html =~ "Tool failed"
    refute html =~ "DBConnection"
    refute html =~ "token=secret"
    refute html =~ "stacktrace"
    refute html =~ "Raw log lines"
    refute html =~ "Run Queue"
    refute html =~ "Scheduled Work"
    refute html =~ "Current Setup"
    refute html =~ "Operational Notes"
    refute html =~ "Agent Runtime"
    refute html =~ "Maraithon Agent Service"
    refute html =~ "Runtime contract"
    refute html =~ "OTP Agent Runtime"
  end

  test "chief of staff inspection shows attached skills and edits morning briefing time", %{
    conn: conn
  } do
    {:ok, _google} =
      OAuth.store_tokens(@user_email, "google:founder@example.com", %{
        access_token: "google-token",
        scopes: Google.scopes_for(["gmail", "calendar"]),
        metadata: %{"account_email" => "founder@example.com"}
      })

    {:ok, _slack_bot} =
      OAuth.store_tokens(@user_email, "slack:T12345", %{
        access_token: "xoxb-test-token",
        scopes: ["channels:read", "channels:history"],
        metadata: %{"team_id" => "T12345", "team_name" => "Agora"}
      })

    {:ok, _slack_user} =
      OAuth.store_tokens(@user_email, "slack:T12345:user:U99999", %{
        access_token: "xoxp-test-token",
        scopes: ["search:read", "im:read", "chat:write"],
        metadata: %{
          "team_id" => "T12345",
          "team_name" => "Agora",
          "slack_user_id" => "U99999"
        }
      })

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(@user_email, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042", "username" => "kentfenwick"}
      })

    {:ok, agent} =
      create_agent(%{
        behavior: "ai_chief_of_staff",
        config: %{
          "name" => "Chief of Staff",
          "enabled_skills" => ["followthrough", "morning_briefing", "travel_logistics"],
          "morning_brief_hour_local" => 8,
          "timezone_offset_hours" => -5
        },
        status: "stopped"
      })

    {:ok, _view, html} = live(conn, "/agents?id=#{agent.id}")

    assert html =~ "Overview"
    assert html =~ "Connected apps"

    {:ok, _view, html} = live(conn, "/agents?id=#{agent.id}&panel=apps")
    assert html =~ "founder@example.com"
    assert html =~ "Agora"
    assert html =~ "@kentfenwick"
    refute html =~ "Chat ID"
    refute html =~ "6114124042"

    {:ok, view, html} = live(conn, "/agents?id=#{agent.id}&panel=skills")

    assert html =~ "Attached Skills"
    assert html =~ "Morning briefing"
    assert html =~ "Send each morning at"
    assert has_element?(view, "#morning-brief-time-form")

    view
    |> form("#morning-brief-time-form", %{"schedule" => %{"local_hour" => "9"}})
    |> render_submit()

    updated = Agents.get_agent!(agent.id)
    assert updated.config["morning_brief_hour_local"] == 9
    assert render(view) =~ "9:00 AM"
  end

  test "morning briefing schedule errors use product copy", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "ai_chief_of_staff",
        config: %{
          "name" => "Chief of Staff",
          "enabled_skills" => ["morning_briefing"],
          "morning_brief_hour_local" => 8,
          "timezone_offset_hours" => -5
        },
        status: "stopped"
      })

    {:ok, view, _html} = live(conn, "/agents?id=#{agent.id}&panel=skills")

    html =
      render_submit(view, "update_morning_brief_time", %{
        "schedule" => %{"local_hour" => "99"}
      })

    assert html =~ "Choose a valid morning briefing time."
    refute html =~ "invalid_local_hour"
    refute html =~ ":invalid"
  end

  test "unauthorized ids clear the selection safely", %{conn: conn} do
    {:ok, other_agent} =
      Agents.create_agent(%{
        user_id: "other@example.com",
        behavior: "prompt_agent",
        config: %{"name" => "not-yours"},
        status: "stopped"
      })

    assert {:error,
            {:live_redirect, %{to: "/agents", flash: %{"error" => "Automation not found"}}}} =
             live(conn, "/agents?id=#{other_agent.id}")
  end

  test "shows no matches state when filters exclude all agents", %{conn: conn} do
    {:ok, _agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "runner"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _view, html} = live(conn, "/agents?status=stopped")

    assert html =~ "No automations match the current filters."
    assert html =~ "Reset filters"
  end

  defp create_agent(attrs) do
    attrs = Map.put_new(attrs, :user_id, @user_email)
    Agents.create_agent(attrs)
  end

  defp stop_agent_process(agent_id) do
    case Registry.lookup(Maraithon.Runtime.AgentRegistry, agent_id) do
      [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
      [] -> :ok
    end
  end
end
