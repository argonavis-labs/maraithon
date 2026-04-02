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
end
