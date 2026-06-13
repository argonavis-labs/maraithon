defmodule Maraithon.GoalsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Goals
  alias Maraithon.Todos

  setup do
    email = "goals-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    %{user: user}
  end

  test "creates goals with category defaults and exposes bounded context", %{user: user} do
    now = ~U[2026-06-13 12:00:00Z]

    assert {:ok, work_goal} =
             Goals.create_goal(
               user.id,
               %{
                 "category" => "work",
                 "title" => "Ship Goals tab",
                 "desired_outcome" => "Maraithon has a durable goals surface."
               },
               now: now
             )

    assert work_goal.status == "active"
    assert work_goal.sensitivity == "standard"
    assert work_goal.proactive_visibility == "summary"
    assert DateTime.compare(work_goal.next_review_at, DateTime.add(now, 7, :day)) == :eq

    assert {:ok, private_goal} =
             Goals.create_goal(
               user.id,
               %{
                 "category" => "life",
                 "title" => "Keep a private life goal",
                 "desired_outcome" => "This should not appear in broad context.",
                 "sensitivity" => "private"
               },
               now: now
             )

    snapshot = Goals.context_snapshot(user.id, now: now)

    assert get_in(snapshot, ["counts", "active"]) == 2
    assert Enum.any?(snapshot["active_goals"], &(&1["id"] == work_goal.id))
    refute Enum.any?(snapshot["active_goals"], &(&1["id"] == private_goal.id))
  end

  test "records progress, links open work, and includes it in open-loop goals", %{user: user} do
    assert {:ok, goal} =
             Goals.create_goal(user.id, %{
               "category" => "work",
               "title" => "Improve launch follow-through",
               "desired_outcome" => "Every launch thread has a clear next move."
             })

    assert {:ok, progress} =
             Goals.record_progress(user.id, goal.id, %{
               "summary" => "Launch follow-up is blocked on a reply.",
               "progress_state" => "blocked"
             })

    assert progress.progress_state == "blocked"

    assert {:ok, [todo]} =
             Todos.upsert_many(user.id, [
               %{
                 "source" => "goals",
                 "title" => "Reply on launch follow-through",
                 "summary" => "A goal-linked next move should stay visible.",
                 "next_action" => "Send the launch follow-up reply.",
                 "status" => "open"
               }
             ])

    assert {:ok, link} =
             Goals.link_resource(user.id, goal.id, %{
               "resource_type" => "todo",
               "resource_id" => todo.id,
               "relationship" => "next_move"
             })

    assert link.resource_id == todo.id

    open_loop_goals = Goals.open_loop_snapshot(user.id)

    assert Enum.any?(open_loop_goals.at_risk_goals, &(&1["id"] == goal.id))
    assert [%{goal: %{id: goal_id}, todo: %{id: todo_id}}] = open_loop_goals.linked_open_work
    assert goal_id == goal.id
    assert todo_id == todo.id
  end

  test "reviewing a missing selected goal fails closed", %{user: user} do
    assert {:error, :not_found} =
             Goals.review_goal_alignment(user.id,
               goal_id: Ecto.UUID.generate(),
               trigger: "manual"
             )
  end
end
