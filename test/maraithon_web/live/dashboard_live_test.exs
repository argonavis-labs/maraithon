defmodule MaraithonWeb.DashboardLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Agents
  alias Maraithon.Events.Event
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.LogBuffer
  alias Maraithon.OAuth
  alias Maraithon.OperatorMemory.Summary, as: OperatorMemorySummary
  alias Maraithon.PreferenceMemory.Rule, as: PreferenceRule
  alias Maraithon.Projects
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Todos
  alias Maraithon.UserMemory.Profile, as: UserMemoryProfile

  @user_email "dashboard@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "renders control center sections without the old agent management panels", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard")
    html = render(view)

    assert has_element?(view, "h1", "Control Center")
    assert has_element?(view, "h2", "Overview")
    assert has_element?(view, "h2", "Today's work")
    assert has_element?(view, "h2", "Today")
    assert has_element?(view, "h2", "Workspace")
    assert has_element?(view, "h2", "Start Chief of Staff")
    assert html =~ "New project"
    assert html =~ "Memory"
    assert has_element?(view, "h2", "Projects")
    assert has_element?(view, "h2", "Automation activity")
    assert has_element?(view, "h2", "Health")
    assert Regex.scan(~r/<dt[^>]*>\s*Uptime\s*<\/dt>/, html) |> length() == 1
    assert html =~ "Operational activity"
    assert html =~ "Needs attention"
    assert html =~ "System logs"
    assert html =~ "Platform logs"
    assert html =~ "Platform logs are not configured for this environment."
    refute html =~ "Failures &amp; stale work"
    refute html =~ "Raw logs"
    refute html =~ "Fly.io platform logs"
    refute html =~ "FLY_API_TOKEN"
    assert has_element?(view, "a[href='/agents/new']", "New automation")
    refute has_element?(view, "h1", "Todos")
    refute html =~ "New agent"
    refute html =~ "Install agent"
    refute html =~ "Agent activity"
    refute html =~ "Agent Registry"
    refute html =~ "Agent Details"
  end

  test "renders memory context without internal confidence scoring", %{conn: conn} do
    Repo.insert!(%UserMemoryProfile{
      user_id: @user_email,
      summary: "Use concise founder-style status updates.",
      profile: %{"communication_style" => "Direct and decision-oriented."},
      confidence: 0.93
    })

    Repo.insert!(%PreferenceRule{
      user_id: @user_email,
      status: "active",
      source: "web",
      kind: "style_preference",
      label: "Direct updates",
      instruction: "Keep updates direct and decision oriented.",
      confidence: 0.91
    })

    Repo.insert!(%OperatorMemorySummary{
      user_id: @user_email,
      summary_type: "action_style",
      content: "Prefers direct asks with clear owners.",
      confidence: 0.88
    })

    {:ok, _view, html} = live(conn, "/dashboard")

    assert html =~ "Use concise founder-style status updates."
    assert html =~ "Keep updates direct and decision oriented."
    assert html =~ "Prefers direct asks with clear owners."
    refute html =~ "confidence 93"
    refute html =~ "93.0%"
    refute html =~ "91.0%"
    refute html =~ "88.0%"
  end

  test "onboarding preview renders as product copy without confidence scoring", %{conn: conn} do
    original_module = Application.get_env(:maraithon, :onboarding_proof_module)
    original_response = Application.get_env(:maraithon, :onboarding_proof_stub_response)

    on_exit(fn ->
      restore_env(:onboarding_proof_module, original_module)
      restore_env(:onboarding_proof_stub_response, original_response)
    end)

    Application.put_env(
      :maraithon,
      :onboarding_proof_module,
      Maraithon.TestSupport.OnboardingProofStub
    )

    Application.put_env(:maraithon, :onboarding_proof_stub_response, {
      :ok,
      %{
        items: [
          %{
            title: "Deck follow-up for Sarah",
            summary: "The Sarah thread still needs a promised deck.",
            rationale: "Sarah asked for the deck and the recent sample does not show delivery.",
            recommended_action: "Check the thread and send the deck if it is still missing.",
            source: "gmail",
            account_label: "preview@example.com",
            suggested_behavior: "founder_followthrough_agent",
            confidence: 0.99
          }
        ],
        sources: ["Gmail · preview@example.com"],
        generated_at: DateTime.utc_now()
      }
    })

    {:ok, _token} =
      OAuth.store_tokens(@user_email, "google:preview@example.com", %{
        access_token: "preview-token",
        scopes: [],
        metadata: %{"account_email" => "preview@example.com"}
      })

    {:ok, view, _html} = live(conn, "/dashboard")
    html = render_async(view)

    assert html =~ "3 things Maraithon would have caught this week"
    assert html =~ "Deck follow-up for Sarah"
    assert html =~ "Sarah asked for the deck"
    refute_html_contains(html, "confidence 99")
    refute_html_contains(html, "99.0%")
  end

  test "creates a project and project memory from the dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard")

    _html =
      view
      |> form("#project-form",
        project: %{
          name: "Operator OS",
          summary: "Founder system work",
          description: "Everything related to the operator layer.",
          priority: "high"
        }
      )
      |> render_submit()

    project = Projects.get_project_by_slug_for_user("operator-os", @user_email)
    assert project.name == "Operator OS"

    html =
      view
      |> form("#project-item-form",
        project_item: %{
          project_id: project.id,
          item_type: "todo",
          title: "Ship dashboard",
          content: "Launch the first project workspace slice."
        }
      )
      |> render_submit()

    assert html =~ "Operator OS"
    assert html =~ "Ship dashboard"
    assert html =~ "Launch the first project workspace slice."
  end

  test "renders project manager recommendations on the dashboard", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(@user_email, %{
        "name" => "Maraithon Product",
        "summary" => "Product roadmap and operator UX"
      })

    assert {:ok, _item} =
             Projects.create_project_item(project, %{
               "item_type" => "grant",
               "title" => "GitHub scope",
               "content" => "Planner can inspect kent/bliss/maraithon."
             })

    {:ok, agent} =
      create_agent(%{
        behavior: "github_product_planner",
        project_id: project.id,
        config: %{"name" => "Maraithon PM", "repo_full_name" => "kent/bliss/maraithon"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _insights} =
      Insights.record_many(@user_email, agent.id, [
        %{
          "source" => "github",
          "category" => "product_opportunity",
          "title" => "Project workspace",
          "summary" => "Ship an app-facing project workspace with project-local state.",
          "recommended_action" => "Launch projects on the dashboard first.",
          "priority" => 96,
          "confidence" => 0.91,
          "dedupe_key" => "dashboard:project-recommendation:1",
          "metadata" => %{"why_now" => "Users need project context in the app today."}
        }
      ])

    {:ok, _view, html} = live(conn, "/dashboard")

    assert html =~ "Maraithon Product"
    assert html =~ "GitHub scope"
    assert html =~ "Project workspace"
    assert html =~ "Launch projects on the dashboard first."
    assert html =~ "Attach Project Manager"
  end

  test "lets the user accept a recommendation, grant repo access, and start delivery", %{
    conn: conn
  } do
    original_projects = Application.get_env(:maraithon, Maraithon.Projects, [])

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Projects, original_projects)
    end)

    Application.put_env(:maraithon, Maraithon.Projects,
      delivery_launcher: fn _project, _recommendation, _decision, _agent, _run ->
        {:ok,
         %{
           status: "pending_plan",
           result_summary: "Queued with the project repo planner.",
           metadata: %{"launcher" => "stub"}
         }}
      end
    )

    {:ok, project} =
      Projects.create_project(@user_email, %{
        "name" => "Operator Delivery",
        "summary" => "Project delivery workflow"
      })

    {:ok, _repo_planner} =
      create_agent(%{
        behavior: "repo_planner",
        project_id: project.id,
        config: %{"name" => "Project Builder", "codebase_path" => File.cwd!()}
      })

    {:ok, agent} =
      create_agent(%{
        behavior: "github_product_planner",
        project_id: project.id,
        config: %{"name" => "PM", "repo_full_name" => "kent/bliss/maraithon"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, [recommendation]} =
      Insights.record_many(@user_email, agent.id, [
        %{
          "source" => "github",
          "category" => "product_opportunity",
          "title" => "Delivery loop",
          "summary" => "Track accepted recommendations and repo grants.",
          "recommended_action" => "Ship the first delivery workflow slice.",
          "priority" => 94,
          "confidence" => 0.9,
          "dedupe_key" => "dashboard:delivery-loop:1",
          "metadata" => %{"repo_full_name" => "kent/bliss/maraithon"}
        }
      ])

    {:ok, view, _html} = live(conn, "/dashboard")

    view
    |> element(
      "button[phx-click='decide_project_recommendation'][phx-value-project_id='#{project.id}'][phx-value-recommendation_id='#{recommendation.id}'][phx-value-decision='accepted']"
    )
    |> render_click()

    assert render(view) =~ "Accepted"

    view
    |> element(
      "button[phx-click='grant_project_repo_access'][phx-value-project_id='#{project.id}'][phx-value-repo_full_name='kent/bliss/maraithon'][phx-value-scope='read_only']"
    )
    |> render_click()

    assert render(view) =~ "Read only"

    view
    |> element(
      "button[phx-click='start_project_implementation_run'][phx-value-project_id='#{project.id}'][phx-value-recommendation_id='#{recommendation.id}']"
    )
    |> render_click()

    html = render(view)
    assert html =~ "Planning"
    assert html =~ "Queued with the project repo planner."

    [run] = Projects.list_implementation_runs(project_id: project.id, user_id: @user_email)

    assert {:ok, _updated_run} =
             Projects.update_implementation_run(run.id, @user_email, %{
               "status" => "awaiting_review",
               "branch_name" => "feature/operator-delivery",
               "pull_request_url" => "https://github.com/kent/bliss/maraithon/pull/51",
               "result_summary" => "PR is ready for review.",
               "metadata" => %{"plan_file_path" => "PLANS/operator_delivery.md"}
             })

    {:ok, _reloaded_view, reloaded_html} = live(conn, "/dashboard")
    assert reloaded_html =~ "feature/operator-delivery"
    assert reloaded_html =~ "Open PR"
    assert reloaded_html =~ "Delivery plan recorded"
    refute reloaded_html =~ "PLANS/operator_delivery.md"
  end

  test "renders enriched insight context and ideas", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "inbox_calendar_advisor",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _insights} =
      Insights.record_many(@user_email, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Reply to the customer escalation",
          "summary" => "A renewal thread needs a same-day response from the account team.",
          "recommended_action" =>
            "Reply now, confirm the owner, and send a timeline for the next update.",
          "priority" => 93,
          "confidence" => 0.9,
          "dedupe_key" => "dashboard:enriched:1",
          "metadata" => %{
            "account" => @user_email,
            "why_now" => "The customer asked for an update before today's review call.",
            "follow_up_ideas" => [
              "Pull the latest status from support before replying.",
              "Write down the two risks you need covered on the call."
            ]
          }
        }
      ])

    {:ok, _view, html} = live(conn, "/dashboard")

    assert html =~ "Why now"
    assert html =~ "from Gmail · account dashboard@example.com"
    assert html =~ "The customer asked for an update before today&#39;s review call."
    assert html =~ "Pull the latest status from support before replying."
    assert html =~ "Write down the two risks you need covered on the call."
  end

  test "dashboard delivery evidence hides raw provider failure details", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "inbox_calendar_advisor",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, [insight]} =
      Insights.record_many(@user_email, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Failed delivery follow-up",
          "summary" => "A promised update still needs attention.",
          "recommended_action" => "Send the update from the dashboard.",
          "priority" => 93,
          "confidence" => 0.9,
          "dedupe_key" => "dashboard:delivery-error-copy"
        }
      ])

    raw_error =
      "DBConnection.ConnectionError token=secret chat_id=123456789 sarah@example.com stacktrace"

    assert {:ok, _delivery} =
             %Delivery{}
             |> Delivery.changeset(%{
               insight_id: insight.id,
               user_id: @user_email,
               channel: "telegram",
               destination: "123456789",
               score: 0.93,
               threshold: 0.78,
               status: "failed",
               error_message: raw_error
             })
             |> Repo.insert()

    {:ok, view, _html} = live(conn, "/dashboard")

    html =
      view
      |> element("button[phx-click='toggle_insight_detail'][phx-value-id='#{insight.id}']")
      |> render_click()

    assert html =~ "Delivery failed. Check the connected channel and try again."
    assert html =~ "Why this still needs attention"
    assert html =~ "Built from saved evidence"
    assert html =~ "Missing context"
    assert html =~ "No saved evidence was captured for this item."
    refute_html_contains(html, "DBConnection")
    refute_html_contains(html, "persisted")
    refute_html_contains(html, "token=secret")
    refute_html_contains(html, "123456789")
    refute_html_contains(html, "sarah@example.com")
    refute_html_contains(html, "stacktrace")
  end

  test "dashboard oauth flash hides technical query messages", %{conn: conn} do
    raw_message =
      "DBConnection.ConnectionError token=secret oauth_tokens chat_id=123456789 stacktrace"

    {:ok, _view, html} =
      live(
        conn,
        "/dashboard?oauth_status=error&oauth_message=#{URI.encode_www_form(raw_message)}"
      )

    assert html =~ "App connection failed. Try again."
    refute_html_contains(html, "DBConnection")
    refute_html_contains(html, "token=secret")
    refute_html_contains(html, "oauth_tokens")
    refute_html_contains(html, "123456789")
    refute_html_contains(html, "stacktrace")
  end

  test "dashboard failure list hides raw runtime failure details", %{conn: conn} do
    raw_error =
      "DBConnection.ConnectionError token=secret chat_id=123456789 sarah@example.com stacktrace"

    now = DateTime.utc_now()

    Repo.insert!(%BackgroundJob{
      user_id: @user_email,
      queue: "default",
      job_type: "source_ingest",
      status: "failed",
      scheduled_at: now,
      failed_at: now,
      attempts: 2,
      last_error: raw_error
    })

    {:ok, _view, html} = live(conn, "/dashboard")

    assert html =~ "Background job failed. Retry when ready."
    refute_html_contains(html, "DBConnection")
    refute_html_contains(html, "token=secret")
    refute_html_contains(html, "123456789")
    refute_html_contains(html, "sarah@example.com")
    refute_html_contains(html, "stacktrace")
  end

  test "dashboard operational activity hides raw payload and log diagnostics", %{conn: conn} do
    LogBuffer.clear()

    on_exit(fn ->
      LogBuffer.clear()
    end)

    {:ok, agent} =
      create_agent(%{
        behavior: "inbox_calendar_advisor",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

    raw_detail =
      "DBConnection.ConnectionError token=secret chat_id=123456789 sarah@example.com stacktrace"

    Repo.insert!(%Event{
      agent_id: agent.id,
      sequence_num: 1,
      event_type: "tool_failed",
      payload: %{
        "message" => raw_detail,
        "oauth_tokens" => "secret-token"
      }
    })

    LogBuffer.record(%{
      level: :error,
      message: raw_detail,
      metadata: %{
        token: "secret",
        query: "select * from oauth_tokens",
        module: "DBConnection"
      }
    })

    _ = :sys.get_state(LogBuffer)

    {:ok, view, _html} = live(conn, "/dashboard")
    html = render(view)

    assert html =~ "Recorded a failed action."
    assert html =~ "Diagnostic details are hidden from this view."
    refute_html_contains(html, "DBConnection")
    refute_html_contains(html, "token=secret")
    refute_html_contains(html, "secret-token")
    refute_html_contains(html, "oauth_tokens")
    refute_html_contains(html, "123456789")
    refute_html_contains(html, "sarah@example.com")
    refute_html_contains(html, "stacktrace")
    refute_html_contains(html, "select * from oauth_tokens")
  end

  test "separates act-now and monitor insight cards", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "inbox_calendar_advisor",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _insights} =
      Insights.record_many(@user_email, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Reply to the customer escalation",
          "summary" => "A same-day customer update is still owed.",
          "recommended_action" => "Reply now with owner and ETA.",
          "priority" => 94,
          "confidence" => 0.92,
          "dedupe_key" => "dashboard:act-now:1"
        },
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Monitoring investor thread",
          "summary" => "The investor thread is moving and does not need action from you now.",
          "recommended_action" => "Watch for a blocker or a direct ask back to you.",
          "priority" => 84,
          "confidence" => 0.86,
          "attention_mode" => "monitor",
          "dedupe_key" => "dashboard:monitor:1",
          "tracking_key" => "dashboard:monitor:1"
        }
      ])

    {:ok, _view, html} = live(conn, "/dashboard")

    assert html =~ "Needs Action"
    assert html =~ "Threads that currently need a direct decision or reply."
    assert html =~ "Watching"
    assert html =~ "Reply to the customer escalation"
    assert html =~ "Monitoring investor thread"
    assert html =~ "high priority"
    assert html =~ "watching"
    assert html =~ "Action:"
    assert html =~ "Watch:"
    assert html =~ "from Gmail"
    refute html =~ "account unknown"
    refute html =~ "confidence 92"
    refute html =~ "confidence 86"
    refute html =~ "founder debt"
    refute html =~ "P94"
    refute html =~ "P84"
  end

  test "shows dashboard metrics when agents exist", %{conn: conn} do
    {:ok, _running} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _degraded} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{},
        status: "degraded",
        started_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, "/dashboard")
    html = render(view)

    assert html =~ "Automations"
    assert html =~ "active"
    assert html =~ "need attention"
    assert html =~ "Assistant work"
    refute html =~ "LLM calls"
    assert html =~ "Spend"
    assert html =~ "Queued actions"
    assert html =~ "Prompt automation"
    refute html =~ "Pending effects"
    refute html =~ "Prompt agent"
    refute html =~ "degraded"
  end

  test "shows reviewable work and links to the dedicated Work page", %{conn: conn} do
    assert {:ok, [_todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Reply to billing thread",
                 "summary" => "Stripe needs a confirmation about the invoice owner.",
                 "next_action" => "Reply with owner, ETA, and billing contact.",
                 "priority" => 88,
                 "dedupe_key" => "dashboard:todo:billing"
               }
             ])

    {:ok, view, _html} = live(conn, "/dashboard")

    html = render(view)
    assert html =~ "Reply to billing thread"
    assert html =~ "1 open work item is ready to review."
    refute html =~ "open cards"
    assert has_element?(view, "a[href='/todos']", "Open Work")

    todo = List.first(Todos.list_open_for_user(@user_email))

    _html =
      view
      |> element(
        "#todo-review button[phx-click='review_complete_todo'][phx-value-id='#{todo.id}']"
      )
      |> render_click()

    refute has_element?(view, "#todo-review-card-#{todo.id}")
    assert Todos.list_open_for_user(@user_email) == []
  end

  test "renders a one-by-one todo card review queue with action context", %{conn: conn} do
    assert {:ok, _todos} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Reply to Michael Berlingo on Starteryou UGC Campaigns",
                 "summary" =>
                   "Michael is waiting for confirmation on campaign materials and ownership.",
                 "next_action" =>
                   "Reply with the exact asset status, owner, and delivery timing.",
                 "priority" => 92,
                 "dedupe_key" => "dashboard:todo:starteryou",
                 "metadata" => %{
                   "person" => "Michael Berlingo",
                   "company" => "Starteryou",
                   "relationship" => "UGC campaign contact",
                   "why_now" => "Deadline is today and no later follow-through was found.",
                   "source_excerpt" =>
                     "Can you confirm whether the UGC campaign materials are ready?"
                 }
               },
               %{
                 "source" => "calendar",
                 "title" => "Prepare Monday board notes",
                 "summary" => "Collect the three updates needed before the Monday board prep.",
                 "next_action" => "Write the top three updates and owner for each.",
                 "priority" => 80,
                 "dedupe_key" => "dashboard:todo:board-notes",
                 "metadata" => %{
                   "project" => "Board prep",
                   "why_it_matters" => "This feeds Monday's meeting prep."
                 }
               }
             ])

    [first, second] = Todos.list_for_user(@user_email, limit: 2, statuses: ["open"])

    {:ok, view, _html} = live(conn, "/dashboard")
    html = render(view)

    assert has_element?(view, "#todo-review")
    assert has_element?(view, "h2", "Today's work")
    assert html =~ "One at a time"
    assert html =~ "Decide the next move for each commitment."
    refute html =~ "Today's cards"
    refute html =~ "Review queue"
    assert html =~ "1 of 2"
    assert html =~ "Michael Berlingo"
    assert html =~ "Starteryou"
    assert html =~ "UGC campaign contact"
    assert html =~ "Suggested next step"
    assert html =~ "Why it matters"
    assert html =~ "Maraithon can draft the reply for approval."
    assert html =~ "Can you confirm whether the UGC campaign materials are ready?"
    assert html =~ "Keep active"
    refute html =~ "Why important"
    refute html =~ ">Important<"

    view
    |> element("#todo-review button[phx-click='review_next_todo']")
    |> render_click()

    assert render(view) =~ "Prepare Monday board notes"

    view
    |> element("#todo-review button[phx-click='review_previous_todo']")
    |> render_click()

    view
    |> element(
      "#todo-review button[phx-click='review_complete_todo'][phx-value-id='#{first.id}']"
    )
    |> render_click()

    refute has_element?(view, "#todo-review-card-#{first.id}")
    assert Todos.get_for_user(@user_email, first.id).status == "done"

    view
    |> element(
      "#todo-review button[phx-click='review_dismiss_todo'][phx-value-id='#{second.id}']"
    )
    |> render_click()

    html = render(view)
    assert html =~ "No open work items."
    refute html =~ "No open cards."
    assert Todos.get_for_user(@user_email, second.id).status == "dismissed"
  end

  test "dashboard review avoids generated-work fallback copy", %{conn: conn} do
    assert {:ok, [_todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "title" => "Review generated operating note",
                 "summary" => "Maraithon created this work item from its own operating context.",
                 "next_action" =>
                   "Review the note, decide whether it belongs in open work, then keep or dismiss it.",
                 "priority" => 72,
                 "dedupe_key" => "dashboard:todo:generated-source"
               }
             ])

    {:ok, _view, html} = live(conn, "/dashboard")

    assert html =~ "Review generated operating note"
    assert html =~ "This is still open and needs a clear next decision."
    refute html =~ "This is an open Maraithon item."
    refute html =~ "account unknown"
    refute html =~ "&gt;system&lt;"
    refute html =~ "N/A"
  end

  test "dashboard todo review hides internal todo metadata fallbacks", %{conn: conn} do
    assert {:ok, [_todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Reply to investor financing update",
                 "summary" => "The investor asked whether the financing update is ready.",
                 "next_action" => "Reply with the current status and next review window.",
                 "priority" => 91,
                 "dedupe_key" => "dashboard:todo:internal-metadata",
                 "metadata" => %{
                   "person" => "Avery Investor",
                   "source_quote" => "Can you confirm whether the financing update is ready?",
                   "why_now" => "99% confidence from the model score says this should interrupt.",
                   "why_it_matters" => "Internal reasoning says this is important.",
                   "urgency_reason" => "Model score threshold passed.",
                   "rationale" => "LLM_REASONING_SHOULD_NOT_RENDER",
                   "source_evidence" => "thread-private-123 token secret",
                   "source_excerpt" =>
                     "The model is 91% confident because of thread-private-123.",
                   "confidence" => 0.99
                 }
               }
             ])

    {:ok, _view, html} = live(conn, "/dashboard")

    assert html =~ "Avery Investor"
    assert html =~ "Can you confirm whether the financing update is ready?"
    refute html =~ "99%"
    refute html =~ "91%"
    refute html =~ "confidence"
    refute html =~ "model score"
    refute html =~ "Model score"
    refute html =~ "Internal reasoning"
    refute html =~ "LLM_REASONING_SHOULD_NOT_RENDER"
    refute html =~ "thread-private-123"
    refute html =~ "token secret"
  end

  test "dashboard todo action errors hide internal reasons", %{conn: conn} do
    assert {:ok, [complete_todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Complete stale dashboard todo",
                 "summary" => "This card will be stale before completion.",
                 "next_action" => "Mark it done.",
                 "priority" => 91,
                 "dedupe_key" => "dashboard:stale-complete"
               }
             ])

    {:ok, view, _html} = live(conn, "/dashboard")

    Maraithon.Repo.delete!(complete_todo)

    html =
      view
      |> element(
        "#todo-review button[phx-click='review_complete_todo'][phx-value-id='#{complete_todo.id}']"
      )
      |> render_click()

    refute has_element?(view, "#todo-review-card-#{complete_todo.id}")
    assert html =~ "No open work items."
    refute html =~ ":not_found"
    refute html =~ "not_found"

    assert {:ok, [important_todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Keep-active dashboard work item",
                 "summary" => "This card will be removed before it can be kept active.",
                 "next_action" => "Keep it active.",
                 "priority" => 90,
                 "dedupe_key" => "dashboard:stale-important"
               }
             ])

    {:ok, important_view, _html} = live(conn, "/dashboard")
    Maraithon.Repo.delete!(important_todo)

    html =
      important_view
      |> element(
        "#todo-review button[phx-click='review_mark_important'][phx-value-id='#{important_todo.id}']"
      )
      |> render_click()

    refute has_element?(important_view, "#todo-review-card-#{important_todo.id}")
    assert html =~ "No open work items."
    refute html =~ ":not_found"
    refute html =~ "not_found"
  end

  test "redirects legacy selected-agent dashboard URLs to the agents workspace", %{conn: conn} do
    {:ok, agent} =
      create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "legacy-link"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    assert {:error, {:live_redirect, %{to: "/agents?id=" <> redirect_id}}} =
             live(conn, "/dashboard?id=#{agent.id}")

    assert redirect_id == agent.id
  end

  defp create_agent(attrs) do
    attrs = Map.put_new(attrs, :user_id, @user_email)
    Agents.create_agent(attrs)
  end

  defp refute_html_contains(html, needle) do
    if html =~ needle do
      flunk(
        "expected rendered dashboard HTML not to include #{inspect(needle)}:\n" <>
          html_snippet(html, needle)
      )
    end
  end

  defp html_snippet(html, needle) do
    case :binary.match(html, needle) do
      {index, _length} ->
        start = max(index - 300, 0)
        String.slice(html, start, 700)

      :nomatch ->
        ""
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:maraithon, key)
  defp restore_env(key, value), do: Application.put_env(:maraithon, key, value)
end
