defmodule Maraithon.ChiefOfStaff.Skills.ProjectScopeAlignmentTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.Skills.ProjectScopeAlignment
  alias Maraithon.Projects
  alias Maraithon.Todos

  setup do
    user_id = "weekend-chief-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{"name" => "Weekend Chief of Staff"}
      })

    %{user_id: user_id, agent: agent}
  end

  test "persists weekend work-home guesses and records a clarification brief", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, work_project} =
      Projects.create_project(user_id, %{
        "name" => "Maraithon Product",
        "summary" => "Operator product planning and shipping."
      })

    {:ok, home_project} =
      Projects.create_project(user_id, %{
        "name" => "Garage Renovation",
        "summary" => "Shelving, paint, and tool-storage work at home."
      })

    {:ok, _item} =
      Projects.create_project_item(home_project, %{
        "item_type" => "note",
        "title" => "Weekend plan",
        "content" => "Finish the shelving wall and sort the tools."
      })

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "telegram",
          "kind" => "general",
          "title" => "Review the dashboard PR",
          "summary" => "The dashboard PR needs a decision this weekend.",
          "next_action" => "Review the open PR and leave notes.",
          "priority" => 82,
          "dedupe_key" => "weekend-scope:todo:1"
        }
      ])

    state =
      ProjectScopeAlignment.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: ~U[2026-04-04 15:00:00Z],
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      user_memory: %{"working_style" => "Ship operator product quickly."},
      last_message: nil,
      last_message_metadata: %{},
      last_message_id: nil,
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    assert {:effect, {:llm_call, params}, waiting_state} =
             ProjectScopeAlignment.handle_wakeup(state, context)

    assert hd(params["messages"])["content"] =~ work_project.name
    assert hd(params["messages"])["content"] =~ home_project.name
    assert Map.has_key?(waiting_state.pending_projects, work_project.id)
    assert Map.has_key?(waiting_state.pending_todos, todo.id)

    response = %{
      content:
        Jason.encode!(%{
          "summary" => "Sorted the current weekend backlog and need one confirmation.",
          "projects" => [
            %{
              "project_id" => work_project.id,
              "life_domain" => "work",
              "confidence" => 0.94,
              "reasoning" => "This project is about the Maraithon product and software delivery.",
              "ask_user" => false
            },
            %{
              "project_id" => home_project.id,
              "life_domain" => "home",
              "confidence" => 0.61,
              "reasoning" => "The summary and note look like personal household work.",
              "ask_user" => true,
              "question" => "Is Garage Renovation a home project or a work project?"
            }
          ],
          "todos" => [
            %{
              "todo_id" => todo.id,
              "project_id" => work_project.id,
              "project_name" => work_project.name,
              "life_domain" => "work",
              "confidence" => 0.88,
              "reasoning" => "Reviewing the dashboard PR belongs with the product project."
            }
          ]
        })
    }

    assert {:emit, {:briefs_recorded, payload}, next_state} =
             ProjectScopeAlignment.handle_effect_result(
               {:llm_call, response},
               waiting_state,
               context
             )

    assert payload.count == 1
    assert payload.cadences == ["weekend_scope"]
    assert next_state.last_review_key == "2026-04-04"
    assert next_state.pending_projects == %{}
    assert next_state.pending_todos == %{}

    updated_work_project = Projects.get_project_for_user(work_project.id, user_id)
    updated_home_project = Projects.get_project_for_user(home_project.id, user_id)
    updated_todo = Todos.get_for_user(user_id, todo.id)

    assert updated_work_project.metadata["life_domain"] == "work"
    assert updated_home_project.metadata["life_domain"] == "home"
    assert updated_home_project.metadata["life_domain_needs_confirmation"] == true
    assert updated_todo.metadata["suggested_project_id"] == work_project.id
    assert updated_todo.metadata["suggested_life_domain"] == "work"

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.cadence == "weekend_scope"
    assert brief.title =~ "Garage Renovation"
    assert brief.body =~ "Reply in-thread with `work` or `home`"
    assert get_in(brief.metadata, ["linked_project", "id"]) == home_project.id
  end

  test "stays idle on weekdays", %{user_id: user_id, agent: agent} do
    state = ProjectScopeAlignment.init(%{"user_id" => user_id, "timezone_offset_hours" => -4})

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: ~U[2026-04-03 15:00:00Z],
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      user_memory: %{},
      last_message: nil,
      last_message_metadata: %{},
      last_message_id: nil,
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    assert {:idle, _next_state} = ProjectScopeAlignment.handle_wakeup(state, context)
  end
end
