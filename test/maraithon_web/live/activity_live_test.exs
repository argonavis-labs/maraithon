defmodule MaraithonWeb.ActivityLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Todos

  @user_email "activity-live@example.com"

  setup %{conn: conn} do
    {:ok, user} = Accounts.get_or_create_user_by_email(@user_email)
    {:ok, conn: log_in_test_user(conn, @user_email), user: user}
  end

  test "shows user-owned OTP runs, safe steps, and authoritative todo creation", %{conn: conn} do
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        user_id: @user_email,
        status: "running"
      })

    {:ok, run} =
      Agents.start_agent_run(agent, %{
        trigger_type: "schedule",
        budget_snapshot: %{"llm_calls" => 1, "tool_calls" => 1}
      })

    {:ok, step} =
      Agents.record_agent_run_step(run.id, agent.id, %{
        step_type: "tool_call",
        tool_name: "upsert_todos"
      })

    {:ok, _step} = Agents.update_agent_run_step(step.id, %{status: "completed"})
    {:ok, _run} = Agents.complete_agent_run(run.id)

    {:ok, [_todo]} =
      Todos.upsert_many(
        @user_email,
        [
          %{
            "source" => "gmail",
            "kind" => "general",
            "title" => "Send the Acme proposal",
            "dedupe_key" => "activity-live-created-todo"
          }
        ],
        actor_type: :agent
      )

    {:ok, _view, html} = live(conn, "/activity")

    assert html =~ "Latest activity"
    assert html =~ "Custom assistant"
    assert html =~ "Completed"
    assert html =~ "Created or updated todos"
    assert html =~ "Todo created"
    assert html =~ "Send the Acme proposal"
    assert html =~ "Run details"
    assert html =~ ~s(aria-current="page")
  end

  test "keeps other users out and renders safe failure copy", %{conn: conn} do
    other_email = "other-activity-live@example.com"
    {:ok, _other_user} = Accounts.get_or_create_user_by_email(other_email)

    {:ok, other_agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        user_id: other_email,
        status: "running"
      })

    {:ok, other_run} = Agents.start_agent_run(other_agent, %{trigger_type: "message"})
    {:ok, _other_run} = Agents.complete_agent_run(other_run.id)

    {:ok, [_other_todo]} =
      Todos.upsert_many(other_email, [
        %{
          "source" => "manual",
          "kind" => "general",
          "title" => "Other user's private todo",
          "dedupe_key" => "other-activity-live-todo"
        }
      ])

    {:ok, own_agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        user_id: @user_email,
        status: "running"
      })

    {:ok, own_run} = Agents.start_agent_run(own_agent, %{trigger_type: "message"})

    {:ok, _own_run} =
      Agents.fail_agent_run(own_run.id, %{
        error: "secret token stacktrace provider body"
      })

    {:ok, _view, html} = live(conn, "/activity")

    assert html =~ "That run did not complete"
    refute html =~ "secret token stacktrace"
    refute html =~ "Other user&#39;s private todo"
    refute html =~ "Other user's private todo"
  end
end
