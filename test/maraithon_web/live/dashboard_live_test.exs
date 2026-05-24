defmodule MaraithonWeb.DashboardLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Agents
  alias Maraithon.Insights
  alias Maraithon.Projects
  alias Maraithon.Todos

  @user_email "dashboard@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "renders control center sections without the old agent management panels", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard")
    html = render(view)

    assert has_element?(view, "h2", "Overview")
    assert has_element?(view, "h2", "Today's cards")
    assert has_element?(view, "h2", "Today")
    assert has_element?(view, "h2", "Workspace")
    assert html =~ "New project"
    assert html =~ "Memory"
    assert has_element?(view, "h2", "Projects")
    assert has_element?(view, "h2", "Health")
    assert html =~ "Operational activity"
    assert html =~ "Failures &amp; stale work"
    assert html =~ "Raw logs"
    assert html =~ "Fly.io platform logs"
    assert has_element?(view, "a[href='/agents/new']", "New agent")
    refute html =~ "Agent Registry"
    refute html =~ "Agent Details"
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
    assert reloaded_html =~ "PLANS/operator_delivery.md"
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
    assert html =~ "Watching"
    assert html =~ "Reply to the customer escalation"
    assert html =~ "Monitoring investor thread"
    assert html =~ "Action:"
    assert html =~ "Watch:"
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

    assert html =~ "Agents"
    assert html =~ "running"
    assert html =~ "degraded"
    assert html =~ "LLM calls"
    assert html =~ "Spend"
    assert html =~ "Prompt agent"
  end

  test "shows todos and lets the user complete them from the dashboard", %{conn: conn} do
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

    assert render(view) =~ "Reply to billing thread"

    todo = List.first(Todos.list_open_for_user(@user_email))

    _html =
      view
      |> element("button[phx-click='complete_todo'][phx-value-id='#{todo.id}']")
      |> render_click()

    refute has_element?(view, "#todo-#{todo.id}")
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
    assert html =~ "1 of 2"
    assert html =~ "Michael Berlingo"
    assert html =~ "Starteryou"
    assert html =~ "UGC campaign contact"
    assert html =~ "Suggested next step"
    assert html =~ "Maraithon can draft the reply for approval."
    assert html =~ "Can you confirm whether the UGC campaign materials are ready?"

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

    assert render(view) =~ "No open cards."
    assert Todos.get_for_user(@user_email, second.id).status == "dismissed"
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
end
