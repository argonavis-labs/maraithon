defmodule MaraithonWeb.AgentBuilderLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Projects
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentSupervisor

  @user_email "builder@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  describe "rendering" do
    test "highlights the Automations tab and links back to the workspace", %{conn: conn} do
      {:ok, view, html} = live(conn, "/agents/new")

      assert has_element?(view, "a[href='/agents'][aria-current='page']", "Automations")
      assert html =~ "Automations"
    end

    test "shows clear inputs, outputs, and readiness guidance", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ "New automation"
      assert html =~ "What goes in"
      assert html =~ "What comes out"
      assert html =~ "Operating model"
      assert html =~ "Maraithon Automation Service"
      assert html =~ "Permission readiness"
      assert html =~ "Chief of Staff"
      assert html =~ "Launch details"
      assert html =~ "Focused launch"
      assert html =~ "email:you@example.com"
      refute html =~ "Focused setup"
      refute html =~ "Advanced JSON overrides"
      refute html =~ "scan limits"
      refute html =~ "Memory limit"
      refute html =~ "Input subscriptions"
      refute html =~ "Maraithon Agent Service"
      refute html =~ "OTP Agent Runtime"
      refute html =~ "operator@example.com"
      refute html =~ "http_get"
    end

    test "renders cadences as product copy instead of raw milliseconds", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new?behavior=github_product_planner")

      assert html =~ "Check cadence"
      assert html =~ "1 week"
      refute html =~ "604800000 ms"
      refute html =~ "Wakeup cadence"
    end

    test "uses outcome-facing health monitor copy without an endpoint", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new?behavior=watchdog_summarizer")

      assert html =~ "Health Monitor"
      assert html =~ "Monitoring updates only. Add a URL if you also want endpoint checks."
      assert html =~ "Monitoring updates only"
      refute html =~ "No URL configured."
      refute html =~ "Optional URL</dt><dd>None"
    end

    test "coverage level copy avoids spend and budget framing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new?behavior=ai_chief_of_staff")

      assert html =~ "quieter assistant"
      assert html =~ "one proactive assistant"
      refute html =~ "assistant-wide spend"
      refute html =~ "assistant-wide budget"

      {:ok, _view, html} = live(conn, "/agents/new?behavior=github_product_planner")

      assert html =~ "lightweight planning"
      assert html =~ "larger planning window"
      refute html =~ "daily spend"
      refute html =~ "planning budget"

      {:ok, _view, html} = live(conn, "/agents/new?behavior=slack_followthrough_agent")

      assert html =~ "fewer Slack alerts"
      assert html =~ "faster checks"
      refute html =~ "lowest recurring cost"
      refute html =~ "more budget"
    end

    test "updates the operating model preview for modular chief of staff agents", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      _html =
        view
        |> element("button[phx-click=choose_behavior][phx-value-behavior=\"ai_chief_of_staff\"]")
        |> render_click()

      html = render(view)

      assert html =~ "Operating model"
      assert html =~ "Chief of Staff"
      assert html =~ "Follow-through"
      assert html =~ "Commitment Tracker"
      assert html =~ "Travel Logistics"
      assert html =~ "Morning Briefing"
      refute html =~ "OTP Agent Runtime"
    end

    test "shows a project attachment field when projects exist", %{conn: conn} do
      {:ok, _project} = Projects.create_project(@user_email, %{"name" => "Operator OS"})

      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ "Attach to project"
      assert html =~ "Operator OS"
    end

    test "shows blockers when inbox advisor permissions are missing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new?behavior=inbox_calendar_advisor")

      assert html =~ "Chief of Staff"
      assert html =~ "executives who want fewer missed follow-ups"
      assert html =~ "Gmail"
      assert html =~ "Google Calendar"
      assert html =~ "Slack Channels"
      assert html =~ "Slack Personal DMs"
      assert html =~ "Blocked"
      assert html =~ "Resolve the highlighted blockers before launch."
      refute html =~ "Google Gmail"
      refute html =~ "operators who want"
    end

    test "shows blockers when AI Chief of Staff permissions are missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      _html =
        view
        |> element("button[phx-click=choose_behavior][phx-value-behavior=\"ai_chief_of_staff\"]")
        |> render_click()

      html = render(view)

      assert html =~ "Chief of Staff"
      assert html =~ "executives who want one proactive assistant"
      assert html =~ "Gmail"
      assert html =~ "Google Calendar"
      assert html =~ "Slack Channels"
      assert html =~ "Slack Personal DMs"
      assert html =~ "Telegram"
      assert html =~ "Blocked"
      refute html =~ "Google Gmail"
      refute html =~ "operators who want"
    end

    test "shows blockers when github product planner permissions are missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      _html =
        view
        |> element(
          "button[phx-click=choose_behavior][phx-value-behavior=\"github_product_planner\"]"
        )
        |> render_click()

      html = render(view)

      assert html =~ "Project Manager"
      assert html =~ "GitHub"
      assert html =~ "Telegram"
      assert html =~ "Blocked"

      assert html =~
               "Add a repository in `owner/repo` format so the planner can review current product work."

      refute html =~ "No repository selected yet."
    end

    test "shows blockers when slack followthrough permissions are missing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new?behavior=slack_followthrough_agent")

      assert html =~ "Slack Follow-through"
      assert html =~ "Slack Channels"
      assert html =~ "Slack Personal DMs"
      assert html =~ "Blocked"
    end

    test "uses connected Slack workspace names instead of raw team ids in launch copy", %{
      conn: conn
    } do
      slack_config = Application.get_env(:maraithon, :slack, [])

      Application.put_env(
        :maraithon,
        :slack,
        Keyword.merge(slack_config,
          client_id: "slack-client",
          client_secret: "slack-secret",
          redirect_uri: "http://localhost/auth/slack/callback"
        )
      )

      on_exit(fn ->
        Application.put_env(:maraithon, :slack, slack_config)
      end)

      {:ok, _slack_bot} =
        OAuth.store_tokens(@user_email, "slack:T12345", %{
          access_token: "xoxb-builder-token",
          scopes: ["channels:read", "im:read"],
          metadata: %{"team_id" => "T12345", "team_name" => "Agora"}
        })

      {:ok, view, _html} = live(conn, "/agents/new")

      _html =
        view
        |> element("button[phx-click=choose_behavior][phx-value-behavior=\"ai_chief_of_staff\"]")
        |> render_click()

      html = render(view)

      assert html =~ "Slack workspace"
      assert html =~ "All connected workspaces"
      assert html =~ "Agora"
      refute has_element?(view, "label[for=launch_team_id]", "Slack team ID")

      html =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "ai_chief_of_staff",
            team_id: "T12345",
            cost_profile: "balanced",
            timezone: "offset:-5"
          }
        )
        |> render_change()

      assert html =~ "Scoped to Agora for follow-through."
      assert html =~ "Slack workspace"
      refute html =~ "Scoped to Slack team T12345"
      refute html =~ "All connected teams"
    end

    test "shows blockers when personal assistant permissions are missing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new?behavior=personal_assistant_agent")

      assert html =~ "Personal Assistant"
      assert html =~ "Gmail"
      assert html =~ "Google Calendar"
      assert html =~ "Telegram"
      assert html =~ "Blocked"
      refute html =~ "Google Gmail"
    end

    test "uses simple mode by default and reveals advanced controls on demand", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new?behavior=inbox_calendar_advisor")

      html = render(view)

      assert html =~ "Focused launch"
      assert html =~ "Coverage level"
      assert html =~ "Balanced"
      refute html =~ "Focused setup"
      refute has_element?(view, "label[for=launch_email_scan_limit]")
      refute has_element?(view, "#launch_morning_brief_hour_local")
      refute html =~ "Advanced JSON overrides"
      refute html =~ "scan limits"

      _html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      html = render(view)

      assert html =~ "Chief-of-Staff Briefing"
      assert html =~ "Email review limit"
      assert html =~ "Max items per check"
      assert html =~ "Notification selectivity"
      assert html =~ "Standard - balanced follow-through"
      assert html =~ "Review limit"
      assert html =~ "Action limit"
      assert html =~ "Support setup JSON"
      refute html =~ "Advanced JSON overrides"
      refute html =~ "Reasoning allowance"
      refute html =~ "Action allowance"
      refute html =~ "reasoning steps"
      refute html =~ "Memory limit"
      refute html =~ "Input subscriptions"
      refute html =~ "Max insights per cycle"
      refute html =~ "Minimum confidence"
      refute html =~ "Confidence gate"
      refute html =~ "higher confidence"
      refute html =~ "lower confidence"
      refute html =~ "clearest open loops"
      refute html =~ "Interruption bar"
      refute html =~ "Current bar"
      refute html =~ "confidence threshold"
      refute html =~ "scored for urgency and confidence"
      refute html =~ "high-confidence"
    end

    test "keeps setup copy product-facing instead of scoring-focused", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new?behavior=slack_followthrough_agent")

      html = render(view)

      assert html =~ "Action-ready unresolved commitment summaries"
      assert html =~ "clear and still actionable"
      assert html =~ "Slack commitments that need same-day attention"
      refute html =~ "Actionable unresolved commitment insights scored for urgency and confidence"
      refute html =~ "scored for whether they are worth interrupting you"
      refute html =~ "confidence threshold"
      refute html =~ "high-confidence"
      refute html =~ "open loops"
      refute html =~ "highest-signal"
      refute html =~ "operating layer"
      refute html =~ "Raise `min_confidence`"
      refute html =~ "Interruption bar"
      refute html =~ "Current bar"
    end

    test "uses outcome-facing capacity language for custom automations", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new?behavior=prompt_agent")

      _html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      html = render(view)

      assert html =~ "Allowed actions"

      assert html =~
               "This automation responds only to direct messages until you add sources to watch."

      assert html =~ "Review limit"
      assert html =~ "Action limit"
      assert html =~ "room for 200 review passes and 300 allowed actions"
      refute html =~ "Permitted actions"
      refute html =~ "No watched signals yet."
      refute html =~ "Reasoning allowance"
      refute html =~ "Action allowance"
      refute html =~ "reasoning steps"
      refute html =~ "permitted actions"
      refute html =~ "action allowlist"
    end
  end

  describe "creation" do
    test "creates a prompt agent from simple mode using cost defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      result =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "prompt_agent",
            builder_mode: "simple",
            cost_profile: "lean",
            name: "lean-builder-agent",
            prompt: "Watch repo issues and summarize changes.",
            subscriptions: "github:acme/repo",
            tools: "read_file,search_files"
          }
        )
        |> render_submit()

      [agent] = Agents.list_agents(user_id: @user_email)

      assert agent.behavior == "prompt_agent"
      assert agent.config["name"] == "lean-builder-agent"
      assert agent.config["memory_limit"] == 20
      assert agent.config["budget"]["llm_calls"] == 80
      assert agent.config["budget"]["tool_calls"] == 120

      assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end

    test "creates a prompt agent and redirects to the agents workspace", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      _html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      result =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "prompt_agent",
            name: "builder-agent",
            prompt: "Watch repo issues and summarize changes.",
            subscriptions: "github:acme/repo",
            tools: "read_file,search_files",
            memory_limit: "25",
            budget_llm_calls: "120",
            budget_tool_calls: "240",
            config_json: ""
          }
        )
        |> render_submit()

      [agent] = Agents.list_agents(user_id: @user_email)

      assert agent.behavior == "prompt_agent"
      assert agent.config["name"] == "builder-agent"
      assert agent.config["prompt"] == "Watch repo issues and summarize changes."
      assert agent.config["subscribe"] == ["github:acme/repo"]
      assert agent.config["tools"] == ["read_file", "search_files"]
      assert agent.config["memory_limit"] == 25
      assert agent.config["budget"]["llm_calls"] == 120
      assert agent.config["budget"]["tool_calls"] == 240

      assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end

    test "creates a github product planner and redirects to the agents workspace", %{conn: conn} do
      github_config = Application.get_env(:maraithon, :github, [])
      telegram_config = Application.get_env(:maraithon, :telegram, [])

      Application.put_env(
        :maraithon,
        :github,
        Keyword.merge(github_config,
          client_id: "github-client",
          client_secret: "github-secret",
          redirect_uri: "http://localhost/auth/github/callback"
        )
      )

      Application.put_env(
        :maraithon,
        :telegram,
        Keyword.merge(telegram_config,
          bot_token: "telegram-bot-token",
          webhook_secret_path: "telegram-secret"
        )
      )

      on_exit(fn ->
        Application.put_env(:maraithon, :github, github_config)
        Application.put_env(:maraithon, :telegram, telegram_config)
      end)

      {:ok, _token} =
        OAuth.store_tokens(@user_email, "github", %{
          access_token: "builder-github-token",
          scopes: ["repo"],
          metadata: %{login: "kent"}
        })

      {:ok, _account} =
        ConnectedAccounts.upsert_manual(@user_email, "telegram", %{
          external_account_id: "6114124042",
          metadata: %{"chat_id" => "6114124042", "username" => "kentfenwick"}
        })

      {:ok, view, _html} = live(conn, "/agents/new?behavior=github_product_planner")

      _html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      result =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "github_product_planner",
            name: "pm-planner",
            repo_full_name: "acme/widgets",
            base_branch: "main",
            feature_limit: "3",
            wakeup_interval_ms: "86400000",
            budget_llm_calls: "40",
            budget_tool_calls: "10",
            config_json: ""
          }
        )
        |> render_submit()

      [agent] = Agents.list_agents(user_id: @user_email)

      assert agent.behavior == "github_product_planner"
      assert agent.config["name"] == "pm-planner"
      assert agent.config["user_id"] == @user_email
      assert agent.config["repo_full_name"] == "acme/widgets"
      assert agent.config["base_branch"] == "main"
      assert agent.config["feature_limit"] == 3
      assert agent.config["wakeup_interval_ms"] == 86_400_000
      assert agent.config["budget"]["llm_calls"] == 40
      assert agent.config["budget"]["tool_calls"] == 10

      assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end

    test "creates an agent attached to a project", %{conn: conn} do
      {:ok, project} = Projects.create_project(@user_email, %{"name" => "Maraithon Product"})

      {:ok, view, _html} = live(conn, "/agents/new?project_id=#{project.id}")

      _html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      result =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "prompt_agent",
            project_id: project.id,
            name: "project-agent",
            prompt: "Watch project work and summarize changes.",
            subscriptions: "github:acme/repo",
            tools: "read_file,search_files",
            memory_limit: "25",
            budget_llm_calls: "120",
            budget_tool_calls: "240",
            config_json: ""
          }
        )
        |> render_submit()

      [agent] = Agents.list_agents(user_id: @user_email)

      assert agent.project_id == project.id
      assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end

    test "creates a personal assistant agent when Google and Telegram are connected", %{
      conn: conn
    } do
      google_config = Application.get_env(:maraithon, :google, [])
      telegram_config = Application.get_env(:maraithon, :telegram, [])

      Application.put_env(
        :maraithon,
        :google,
        Keyword.merge(google_config,
          client_id: "google-client",
          client_secret: "google-secret",
          redirect_uri: "http://localhost/auth/google/callback"
        )
      )

      Application.put_env(
        :maraithon,
        :telegram,
        Keyword.merge(telegram_config,
          bot_token: "telegram-bot-token",
          webhook_secret_path: "telegram-secret"
        )
      )

      on_exit(fn ->
        Application.put_env(:maraithon, :google, google_config)
        Application.put_env(:maraithon, :telegram, telegram_config)
      end)

      {:ok, _token} =
        OAuth.store_tokens(@user_email, "google", %{
          access_token: "builder-google-token",
          scopes: Google.scopes_for(["gmail", "calendar"]),
          metadata: %{email: @user_email}
        })

      {:ok, _account} =
        ConnectedAccounts.upsert_manual(@user_email, "telegram", %{
          external_account_id: "6114124042",
          metadata: %{"chat_id" => "6114124042", "username" => "kentfenwick"}
        })

      {:ok, view, _html} = live(conn, "/agents/new?behavior=personal_assistant_agent")

      _html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      result =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "personal_assistant_agent",
            name: "travel-assistant",
            email_scan_limit: "25",
            event_scan_limit: "25",
            lookback_hours: "720",
            min_confidence: "0.8",
            timezone_offset_hours: "-5",
            wakeup_interval_ms: "1800000",
            budget_llm_calls: "40",
            budget_tool_calls: "10",
            config_json: ""
          }
        )
        |> render_submit()

      agents = Agents.list_agents(user_id: @user_email)
      agent = Enum.find(agents, &(&1.behavior == "personal_assistant_agent"))

      assert agent
      assert agent.config["name"] == "travel-assistant"
      assert agent.config["user_id"] == @user_email
      assert agent.config["email_scan_limit"] == 25
      assert agent.config["event_scan_limit"] == 25
      assert agent.config["lookback_hours"] == 720
      assert agent.config["min_confidence"] == 0.8
      assert agent.config["timezone_offset_hours"] == -5
      assert agent.config["wakeup_interval_ms"] == 1_800_000
      assert agent.config["subscribe"] == ["email:#{@user_email}", "calendar:#{@user_email}"]

      assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end

    test "creates an AI Chief of Staff agent when Google, Slack, and Telegram are connected", %{
      conn: conn
    } do
      google_config = Application.get_env(:maraithon, :google, [])
      slack_config = Application.get_env(:maraithon, :slack, [])
      telegram_config = Application.get_env(:maraithon, :telegram, [])

      Application.put_env(
        :maraithon,
        :google,
        Keyword.merge(google_config,
          client_id: "google-client",
          client_secret: "google-secret",
          redirect_uri: "http://localhost/auth/google/callback"
        )
      )

      Application.put_env(
        :maraithon,
        :slack,
        Keyword.merge(slack_config,
          client_id: "slack-client",
          client_secret: "slack-secret",
          redirect_uri: "http://localhost/auth/slack/callback"
        )
      )

      Application.put_env(
        :maraithon,
        :telegram,
        Keyword.merge(telegram_config,
          bot_token: "telegram-bot-token",
          webhook_secret_path: "telegram-secret"
        )
      )

      on_exit(fn ->
        Application.put_env(:maraithon, :google, google_config)
        Application.put_env(:maraithon, :slack, slack_config)
        Application.put_env(:maraithon, :telegram, telegram_config)
      end)

      {:ok, _google_token} =
        OAuth.store_tokens(@user_email, "google", %{
          access_token: "builder-google-token",
          scopes: Google.scopes_for(["gmail", "calendar"]),
          metadata: %{email: @user_email}
        })

      {:ok, _slack_bot} =
        OAuth.store_tokens(@user_email, "slack:T12345", %{
          access_token: "xoxb-test-token",
          scopes: ["channels:read", "im:read"],
          metadata: %{"team_id" => "T12345", "team_name" => "Agora"}
        })

      {:ok, _slack_user} =
        OAuth.store_tokens(@user_email, "slack:T12345:user:U99999", %{
          access_token: "xoxp-test-token",
          scopes: ["search:read", "im:read"],
          metadata: %{
            "team_id" => "T12345",
            "team_name" => "Agora",
            "slack_user_id" => "U99999"
          }
        })

      {:ok, _telegram_account} =
        ConnectedAccounts.upsert_manual(@user_email, "telegram", %{
          external_account_id: "6114124042",
          metadata: %{"chat_id" => "6114124042", "username" => "kentfenwick"}
        })

      {:ok, view, _html} = live(conn, "/agents/new?behavior=ai_chief_of_staff")

      _html =
        view
        |> element("button[phx-click=set_builder_mode][phx-value-mode=\"advanced\"]")
        |> render_click()

      result =
        view
        |> form("#agent-builder-form",
          launch: %{
            behavior: "ai_chief_of_staff",
            name: "chief-of-staff",
            team_id: "T12345",
            timezone: "America/Los_Angeles",
            morning_brief_hour_local: "8",
            end_of_day_brief_hour_local: "18",
            weekly_review_day_local: "5",
            weekly_review_hour_local: "16",
            brief_max_items: "12",
            budget_llm_calls: "200",
            budget_tool_calls: "400",
            config_json: ""
          }
        )
        |> render_submit()

      agents = Agents.list_agents(user_id: @user_email)
      agent = Enum.find(agents, &(&1.behavior == "ai_chief_of_staff"))

      assert agent
      assert agent.config["name"] == "chief-of-staff"
      assert agent.config["user_id"] == @user_email

      assert agent.config["enabled_skills"] == [
               "followthrough",
               "travel_logistics",
               "morning_briefing",
               "commitment_tracker",
               "calendar_check_in",
               "project_scope_alignment",
               "holiday_radar"
             ]

      assert agent.config["source_policy"] == "all_connected"
      assert agent.config["include_future_sources"] == true
      assert agent.config["team_id"] == "T12345"
      assert agent.config["timezone"] == "America/Los_Angeles"
      assert agent.config["timezone_name"] == "America/Los_Angeles"
      assert agent.config["timezone_offset_hours"] == -8
      assert agent.config["wakeup_interval_ms"] == 600_000
      assert agent.config["brief_max_items"] == 12

      assert agent.config["subscribe"] == [
               "email:#{@user_email}",
               "calendar:#{@user_email}",
               "slack:T12345"
             ]

      assert get_in(agent.config, ["source_scope", "google_accounts"]) == [
               %{
                 "account_email" => @user_email,
                 "provider" => "google",
                 "services" => ["calendar", "gmail"]
               }
             ]

      assert get_in(agent.config, ["source_scope", "slack_workspaces"]) == [
               %{
                 "services" => ["channels", "dms"],
                 "team_id" => "T12345",
                 "team_name" => "Agora"
               }
             ]

      assert get_in(agent.config, ["skill_configs", "morning_briefing", "assistant_behavior"]) ==
               "ai_chief_of_staff"

      assert get_in(agent.config, ["skill_configs", "morning_briefing", "timezone"]) ==
               "America/Los_Angeles"

      assert get_in(agent.config, ["skill_configs", "morning_briefing", "timezone_name"]) ==
               "America/Los_Angeles"

      assert get_in(agent.config, ["skill_configs", "morning_briefing", "timezone_offset_hours"]) ==
               -8

      assert get_in(agent.config, [
               "skill_configs",
               "morning_briefing",
               "slack_channel_scan_limit"
             ]) ==
               80

      assert get_in(agent.config, [
               "skill_configs",
               "morning_briefing",
               "slack_message_scan_limit"
             ]) ==
               50

      assert get_in(agent.config, ["skill_configs", "briefing", "brief_max_items"]) == 12

      assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} = result
      assert redirect_id == agent.id

      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _value}] -> assert :ok = AgentSupervisor.stop_agent(pid)
        [] -> :ok
      end
    end
  end
end
