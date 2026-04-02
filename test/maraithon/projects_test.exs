defmodule Maraithon.ProjectsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Insights
  alias Maraithon.Projects
  alias Maraithon.Projects.Project

  setup do
    user_id = "projects-user@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  test "creates a project with generated slug", %{user_id: user_id} do
    assert {:ok, project} =
             Projects.create_project(user_id, %{
               "name" => "Maraithon Product",
               "summary" => "Core product work"
             })

    assert project.slug == "maraithon-product"
    assert project.status == "active"
    assert project.priority == "normal"
  end

  test "enforces per-user slug uniqueness", %{user_id: user_id} do
    assert {:ok, _project} = Projects.create_project(user_id, %{"name" => "Inbox Ops"})

    assert {:error, changeset} =
             Projects.create_project(user_id, %{"name" => "Inbox Ops", "slug" => "inbox-ops"})

    assert %{slug: ["has already been taken"]} = errors_on(changeset)
  end

  test "lists only the requested user's projects" do
    {:ok, _user} = Accounts.get_or_create_user_by_email("other-projects-user@example.com")
    assert {:ok, keep} = Projects.create_project("projects-user@example.com", %{"name" => "Keep"})

    assert {:ok, _other} =
             Projects.create_project("other-projects-user@example.com", %{"name" => "Other"})

    assert [%Project{id: id}] = Projects.list_projects(user_id: "projects-user@example.com")
    assert id == keep.id
  end

  test "finds a project by slug for one user", %{user_id: user_id} do
    assert {:ok, project} = Projects.create_project(user_id, %{"name" => "Agora Ops"})

    assert %Project{id: fetched_id} =
             Projects.get_project_by_slug_for_user("agora-ops", user_id)

    assert fetched_id == project.id
  end

  test "finds a project by name for one user", %{user_id: user_id} do
    assert {:ok, project} = Projects.create_project(user_id, %{"name" => "Operator Inbox"})

    assert %Project{id: fetched_id} =
             Projects.get_project_by_name_for_user("operator inbox", user_id)

    assert fetched_id == project.id
  end

  test "creates and lists project items", %{user_id: user_id} do
    assert {:ok, project} = Projects.create_project(user_id, %{"name" => "Founder Desk"})

    assert {:ok, item} =
             Projects.create_project_item(project, %{
               "item_type" => "todo",
               "title" => "Ship dashboard",
               "content" => "Finish the first project workspace slice."
             })

    assert [listed] = Projects.list_project_items(user_id: user_id, project_id: project.id)
    assert listed.id == item.id
    assert listed.item_type == "todo"
    assert listed.title == "Ship dashboard"
  end

  test "lists project recommendations from project-scoped planner agents", %{user_id: user_id} do
    assert {:ok, project} = Projects.create_project(user_id, %{"name" => "Maraithon Product"})

    assert {:ok, planner_agent} =
             Agents.create_agent(%{
               user_id: user_id,
               project_id: project.id,
               behavior: "github_product_planner",
               config: %{
                 "name" => "Maraithon PM",
                 "repo_full_name" => "kent/bliss/maraithon"
               }
             })

    assert {:ok, unrelated_agent} =
             Agents.create_agent(%{
               user_id: user_id,
               behavior: "github_product_planner",
               config: %{"name" => "Other PM", "repo_full_name" => "kent/bliss/other"}
             })

    {:ok, _stored} =
      Insights.record_many(user_id, planner_agent.id, [
        %{
          "source" => "github",
          "category" => "product_opportunity",
          "title" => "Project workboard",
          "summary" => "Put projects and operator memory on the dashboard.",
          "recommended_action" => "Ship the first project workspace slice.",
          "priority" => 94,
          "confidence" => 0.9,
          "dedupe_key" => "projects-test:workboard:1",
          "metadata" => %{
            "why_now" => "Users need an app-facing project workspace.",
            "repo_full_name" => "kent/bliss/maraithon",
            "planner_type" => "github_product_planner"
          }
        }
      ])

    {:ok, _stored} =
      Insights.record_many(user_id, unrelated_agent.id, [
        %{
          "source" => "github",
          "category" => "product_opportunity",
          "title" => "Unrelated work",
          "summary" => "This should not appear in the project-scoped query.",
          "recommended_action" => "Ignore this item for the project.",
          "priority" => 99,
          "confidence" => 0.91,
          "dedupe_key" => "projects-test:workboard:2"
        }
      ])

    assert [recommendation] = Projects.list_project_recommendations(project.id, user_id)
    assert recommendation.title == "Project workboard"
    assert recommendation.agent_id == planner_agent.id
    assert recommendation.repo_full_name == "kent/bliss/maraithon"
  end

  test "persists recommendation decisions and exposes them on project recommendations", %{
    user_id: user_id
  } do
    %{project: project, recommendation: recommendation} =
      project_recommendation_fixture(user_id, "Decision Loop")

    assert {:ok, decision} =
             Projects.decide_project_recommendation(
               project.id,
               user_id,
               recommendation.id,
               %{"decision" => "accepted", "decision_note" => "Ship this next."}
             )

    assert decision.decision == "accepted"
    assert decision.accepted_plan["title"] == recommendation.title

    [listed] = Projects.list_project_recommendations(project.id, user_id)
    assert listed.decision.decision == "accepted"
    assert listed.decision.decision_note == "Ship this next."
  end

  test "starts a delivery run once repo access exists", %{user_id: user_id} do
    original_projects_env = Application.get_env(:maraithon, Maraithon.Projects, [])
    test_pid = self()

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Projects, original_projects_env)
    end)

    Application.put_env(:maraithon, Maraithon.Projects,
      delivery_launcher: fn _project, _recommendation, _decision, _agent, run ->
        send(test_pid, {:launcher_run, run.id})

        {:ok,
         %{
           status: "pending_plan",
           result_summary: "Queued with the Repo Planner.",
           metadata: %{"launcher" => "stub"}
         }}
      end
    )

    %{project: project, recommendation: recommendation} =
      project_recommendation_fixture(user_id, "Delivery Loop")

    assert {:ok, _planner_agent} =
             Agents.create_agent(%{
               user_id: user_id,
               project_id: project.id,
               behavior: "repo_planner",
               config: %{"name" => "Project Builder", "codebase_path" => File.cwd!()}
             })

    assert {:ok, _grant} =
             Projects.grant_project_repo_access(project.id, user_id, %{
               "repo_full_name" => recommendation.metadata["repo_full_name"],
               "scope" => "read_only"
             })

    assert {:ok, run} =
             Projects.start_implementation_run(project.id, user_id, %{
               "recommendation_id" => recommendation.id
             })

    assert_receive {:launcher_run, launcher_run_id}
    assert launcher_run_id == run.id
    assert run.status == "pending_plan"
    assert run.result_summary == "Queued with the Repo Planner."

    [latest_run] = Projects.list_implementation_runs(project_id: project.id, user_id: user_id)
    assert latest_run.id == run.id
    assert latest_run.metadata["launcher"] == "stub"
  end

  test "updates implementation runs with branch and PR details", %{user_id: user_id} do
    original_projects_env = Application.get_env(:maraithon, Maraithon.Projects, [])

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Projects, original_projects_env)
    end)

    Application.put_env(:maraithon, Maraithon.Projects,
      delivery_launcher: fn _project, _recommendation, _decision, _agent, _run ->
        {:ok,
         %{
           status: "pending_plan",
           result_summary: "Queued with the Repo Planner.",
           metadata: %{"launcher" => "stub"}
         }}
      end
    )

    %{project: project, recommendation: recommendation} =
      project_recommendation_fixture(user_id, "Review Loop")

    assert {:ok, _planner_agent} =
             Agents.create_agent(%{
               user_id: user_id,
               project_id: project.id,
               behavior: "repo_planner",
               config: %{"name" => "Project Builder", "codebase_path" => File.cwd!()}
             })

    assert {:ok, _grant} =
             Projects.grant_project_repo_access(project.id, user_id, %{
               "repo_full_name" => recommendation.metadata["repo_full_name"],
               "scope" => "read_only"
             })

    assert {:ok, run} =
             Projects.start_implementation_run(project.id, user_id, %{
               "recommendation_id" => recommendation.id
             })

    assert {:ok, updated_run} =
             Projects.update_implementation_run(run.id, user_id, %{
               "status" => "awaiting_review",
               "branch_name" => "feature/review-loop",
               "pull_request_url" => "https://github.com/kent/bliss/maraithon/pull/42",
               "result_summary" => "Implementation plan is ready for review.",
               "metadata" => %{"plan_file_path" => "PLANS/plan_review_loop.md"}
             })

    assert updated_run.status == "awaiting_review"
    assert updated_run.branch_name == "feature/review-loop"
    assert updated_run.pull_request_url =~ "/pull/42"
    assert updated_run.metadata["plan_file_path"] == "PLANS/plan_review_loop.md"

    [listed_run] = Projects.list_implementation_runs(project_id: project.id, user_id: user_id)
    assert listed_run.id == updated_run.id
    assert listed_run.branch_name == "feature/review-loop"
  end

  test "marks implementation runs as awaiting repo access when grant is missing", %{
    user_id: user_id
  } do
    %{project: project, recommendation: recommendation} =
      project_recommendation_fixture(user_id, "Repo Gate")

    assert {:ok, _planner_agent} =
             Agents.create_agent(%{
               user_id: user_id,
               project_id: project.id,
               behavior: "repo_planner",
               config: %{"name" => "Project Builder", "codebase_path" => File.cwd!()}
             })

    assert {:ok, run} =
             Projects.start_implementation_run(project.id, user_id, %{
               "recommendation_id" => recommendation.id
             })

    assert run.status == "awaiting_repo_access"
    assert run.result_summary =~ "Grant read-only GitHub access"
  end

  defp project_recommendation_fixture(user_id, project_name) do
    {:ok, project} = Projects.create_project(user_id, %{"name" => project_name})

    {:ok, planner_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        project_id: project.id,
        behavior: "github_product_planner",
        config: %{
          "name" => "#{project_name} PM",
          "repo_full_name" => "kent/bliss/maraithon"
        }
      })

    {:ok, [recommendation]} =
      Insights.record_many(user_id, planner_agent.id, [
        %{
          "source" => "github",
          "category" => "product_opportunity",
          "title" => "#{project_name} Workspace",
          "summary" => "Ship the next project delivery slice.",
          "recommended_action" => "Turn this into a tracked delivery workflow.",
          "priority" => 95,
          "confidence" => 0.91,
          "dedupe_key" => "projects-test:#{project_name}:#{System.unique_integer([:positive])}",
          "metadata" => %{
            "why_now" => "The project delivery loop should be durable.",
            "repo_full_name" => "kent/bliss/maraithon",
            "planner_type" => "github_product_planner",
            "evidence" => ["The project already has PM output but no tracked handoff."]
          }
        }
      ])

    %{project: project, recommendation: recommendation}
  end
end
