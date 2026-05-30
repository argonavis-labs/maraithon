defmodule MaraithonWeb.SelfServeInstallSmokeTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Accounts
  alias Maraithon.AgentMarketplace
  alias Maraithon.Agents
  alias Maraithon.BriefingSchedules
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Projects
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentSupervisor

  setup do
    original_google = Application.get_env(:maraithon, :google, [])
    original_telegram = Application.get_env(:maraithon, :telegram, [])

    Application.put_env(:maraithon, :google,
      client_id: "google-client",
      client_secret: "google-secret",
      redirect_uri: "http://localhost/auth/google/callback"
    )

    Application.put_env(:maraithon, :telegram,
      bot_token: "12345:telegram-token",
      bot_username: "maraithon_test_bot",
      webhook_secret_path: "telegram-secret",
      allow_unsigned: true
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :google, original_google)
      Application.put_env(:maraithon, :telegram, original_telegram)
    end)

    assert {:ok, _packages} = AgentMarketplace.sync_builtin_packages()

    :ok
  end

  test "fresh user connects requirements, creates a project, and installs enabled Chief of Staff",
       %{conn: conn} do
    user_id = "self-serve-enabled-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "998877",
        metadata: %{"chat_id" => "998877", "username" => "operator"}
      })

    {:ok, _google} =
      OAuth.store_tokens(user_id, "google:operator@example.com", %{
        access_token: "google-access",
        refresh_token: "google-refresh",
        scopes: Google.scopes_for(["gmail", "calendar"]),
        metadata: %{"account_email" => "operator@example.com"}
      })

    {:ok, project} = Projects.create_project(user_id, %{"name" => "Operator OS"})
    conn = log_in_test_user(conn, user_id)

    {:ok, view, _html} = live(conn, "/dashboard")
    assert has_element?(view, "#chief-of-staff-install", "Ready to install")
    assert has_element?(view, "#chief-of-staff-install button", "Install Chief of Staff")

    result =
      view
      |> form("#chief-of-staff-install-form",
        project_id: project.id,
        schedule: %{
          morning_brief_hour_local: "9",
          timezone: "America/Los_Angeles"
        }
      )
      |> render_submit()

    assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result

    agent = Agents.get_agent!(redirect_id |> String.split("&") |> List.first())
    assert agent.user_id == user_id
    assert agent.behavior == "manifest_agent"
    assert agent.project_id == project.id
    assert agent.install_status == "enabled"
    assert agent.status == "running"
    assert agent.delivery_policy == %{"telegram" => "enabled"}
    assert agent.config["source_behavior"] == "ai_chief_of_staff"
    assert agent.config["morning_brief_hour_local"] == 9
    assert agent.config["timezone"] == "America/Los_Angeles"
    assert agent.config["timezone_name"] == "America/Los_Angeles"
    assert agent.config["timezone_offset_hours"] == -8

    assert get_in(agent.config, ["skill_configs", "morning_briefing", "morning_brief_hour_local"]) ==
             9

    assert get_in(agent.config, ["skill_configs", "morning_briefing", "timezone"]) ==
             "America/Los_Angeles"

    assert get_in(agent.config, ["skill_configs", "morning_briefing", "timezone_offset_hours"]) ==
             -8

    refute "glossier" in (get_in(agent.config, [
                            "skill_configs",
                            "morning_briefing",
                            "commercial_thread_terms"
                          ]) || [])

    due_agents = BriefingSchedules.list_due_morning_agents(~U[2026-05-08 16:05:00Z])
    due_agent = Enum.find(due_agents, &(&1.agent_id == agent.id))
    assert due_agent
    assert due_agent.timezone_name == "America/Los_Angeles"
    assert due_agent.timezone_offset_hours == -7

    stop_agent_process(agent.id)
  end

  test "installing before connectors are ready records setup_required and schedules no brief",
       %{conn: conn} do
    user_id = "self-serve-setup-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    {:ok, project} = Projects.create_project(user_id, %{"name" => "Inbox Setup"})
    conn = log_in_test_user(conn, user_id)

    {:ok, view, _html} = live(conn, "/dashboard")
    assert has_element?(view, "#chief-of-staff-install", "Setup required")
    assert has_element?(view, "#chief-of-staff-install a", "Connect Telegram")
    assert has_element?(view, "#chief-of-staff-install a", "Connect Gmail")
    assert has_element?(view, "#chief-of-staff-install button", "Install for later")

    result =
      view
      |> form("#chief-of-staff-install-form",
        project_id: project.id,
        schedule: %{
          morning_brief_hour_local: "7",
          timezone: "offset:1"
        }
      )
      |> render_submit()

    assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result

    agent = Agents.get_agent!(redirect_id |> String.split("&") |> List.first())
    assert agent.user_id == user_id
    assert agent.project_id == project.id
    assert agent.install_status == "setup_required"
    assert agent.status == "stopped"
    assert agent.config["morning_brief_hour_local"] == 7
    assert is_nil(agent.config["timezone"])
    assert is_nil(agent.config["timezone_name"])
    assert agent.config["timezone_offset_hours"] == 1

    assert get_in(agent.config, ["skill_configs", "morning_briefing", "morning_brief_hour_local"]) ==
             7

    assert get_in(agent.config, ["skill_configs", "morning_briefing", "timezone_offset_hours"]) ==
             1

    due_agents = BriefingSchedules.list_due_morning_agents(~U[2026-05-08 13:05:00Z])
    refute Enum.any?(due_agents, &(&1.agent_id == agent.id))
  end

  test "setup-required Chief of Staff can be finished after connectors are connected",
       %{conn: conn} do
    user_id = "self-serve-finish-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    {:ok, project} = Projects.create_project(user_id, %{"name" => "Finish Setup"})

    {:ok, setup_agent} =
      Agents.install_chief_of_staff(user_id,
        project_id: project.id,
        delivery_policy: %{"telegram" => "enabled"},
        config: %{"morning_brief_hour_local" => 7, "timezone_offset_hours" => 1}
      )

    assert setup_agent.install_status == "setup_required"
    assert setup_agent.status == "stopped"

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "445566",
        metadata: %{"chat_id" => "445566", "username" => "operator"}
      })

    {:ok, _google} =
      OAuth.store_tokens(user_id, "google:operator@example.com", %{
        access_token: "google-access",
        refresh_token: "google-refresh",
        scopes: Google.scopes_for(["gmail", "calendar"]),
        metadata: %{"account_email" => "operator@example.com"}
      })

    conn = log_in_test_user(conn, user_id)
    {:ok, view, _html} = live(conn, "/dashboard")

    assert has_element?(view, "#chief-of-staff-install", "Ready to enable")
    assert has_element?(view, "#chief-of-staff-install button", "Finish setup")

    result =
      view
      |> form("#chief-of-staff-install-form",
        project_id: project.id,
        schedule: %{
          morning_brief_hour_local: "10",
          timezone: "America/Toronto"
        }
      )
      |> render_submit()

    assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result

    agent = Agents.get_agent!(redirect_id |> String.split("&") |> List.first())
    assert agent.id == setup_agent.id
    assert agent.install_status == "enabled"
    assert agent.status == "running"
    assert agent.config["morning_brief_hour_local"] == 10
    assert agent.config["timezone"] == "America/Toronto"
    assert agent.config["timezone_offset_hours"] == -5

    assert get_in(agent.config, ["skill_configs", "morning_briefing", "morning_brief_hour_local"]) ==
             10

    assert get_in(agent.config, ["skill_configs", "morning_briefing", "timezone"]) ==
             "America/Toronto"

    assert get_in(agent.config, ["skill_configs", "morning_briefing", "timezone_offset_hours"]) ==
             -5

    due_agents = BriefingSchedules.list_due_morning_agents(~U[2026-05-08 14:05:00Z])
    due_agent = Enum.find(due_agents, &(&1.agent_id == agent.id))
    assert due_agent
    assert due_agent.timezone_name == "America/Toronto"
    assert due_agent.timezone_offset_hours == -4

    stop_agent_process(agent.id)
  end

  test "default marketplace bootstrap does not install for a connected non-admin user" do
    previous_primary_admin = System.get_env("PRIMARY_ADMIN_EMAIL")
    primary_admin = "primary-admin-#{System.unique_integer([:positive])}@example.com"
    self_serve_user = "self-serve-guard-#{System.unique_integer([:positive])}@example.com"

    System.put_env("PRIMARY_ADMIN_EMAIL", primary_admin)

    on_exit(fn ->
      case previous_primary_admin do
        nil -> System.delete_env("PRIMARY_ADMIN_EMAIL")
        value -> System.put_env("PRIMARY_ADMIN_EMAIL", value)
      end
    end)

    {:ok, _primary} = Accounts.get_or_create_user_by_email(primary_admin)
    {:ok, _user} = Accounts.get_or_create_user_by_email(self_serve_user)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(self_serve_user, "telegram", %{
        external_account_id: "445566"
      })

    assert {:ok, []} = AgentMarketplace.ensure_default_installations()
    refute Agents.get_package_installation(self_serve_user, "ai_chief_of_staff")
  end

  defp stop_agent_process(agent_id) do
    case Registry.lookup(AgentRegistry, agent_id) do
      [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
      [] -> :ok
    end
  end
end
