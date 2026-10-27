defmodule Maraithon.TelegramAssistant.GoalToolboxTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Goals
  alias Maraithon.TelegramAssistant.Toolbox

  setup do
    email = "goal-toolbox-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    %{runtime_context: %{user_id: user.id, surface: "telegram"}}
  end

  test "goal tools create, list, progress, and review goals for the runtime user", %{
    runtime_context: runtime_context
  } do
    assert {:ok, %{goal: %{id: goal_id, title: "Ship goal-aware reviews"}}} =
             Toolbox.execute(
               "create_goal",
               %{
                 "title" => "Ship goal-aware reviews",
                 "category" => "work",
                 "desired_outcome" => "Maraithon checks work against saved goals.",
                 "last_reviewed_at" => "2001-02-03T04:05:06Z",
                 "next_review_at" => "2099-01-01T00:00:00Z",
                 "metadata" => %{"unsafe" => true}
               },
               runtime_context
             )

    persisted_goal = Goals.get_goal(runtime_context.user_id, goal_id, preload: false)
    assert persisted_goal.last_reviewed_at == nil
    assert persisted_goal.metadata == %{}

    assert {:ok, %{count: 1, goals: [%{id: ^goal_id}]}} =
             Toolbox.execute("list_goals", %{"status" => "active"}, runtime_context)

    assert {:ok, %{goal: %{title: "Ship goal-aware reviews safely"}}} =
             Toolbox.execute(
               "update_goal",
               %{
                 "goal_id" => goal_id,
                 "title" => "Ship goal-aware reviews safely",
                 "last_reviewed_at" => "2001-02-03T04:05:06Z",
                 "next_review_at" => "2099-01-01T00:00:00Z",
                 "metadata" => %{"unsafe" => true}
               },
               runtime_context
             )

    persisted_goal = Goals.get_goal(runtime_context.user_id, goal_id, preload: false)
    assert persisted_goal.last_reviewed_at == nil
    assert persisted_goal.metadata == %{}

    assert {:ok, %{progress_update: %{progress_state: "on_track"}}} =
             Toolbox.execute(
               "record_goal_progress",
               %{
                 "goal_id" => goal_id,
                 "summary" => "Goal tools are wired.",
                 "progress_state" => "on_track"
               },
               runtime_context
             )

    assert {:ok, %{review_run: %{status: "completed"}}} =
             Toolbox.execute(
               "review_goal_alignment",
               %{"goal_id" => goal_id},
               runtime_context
             )
  end
end
