defmodule Maraithon.TelegramAssistant.GoalToolboxTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
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
                 "desired_outcome" => "Maraithon checks work against saved goals."
               },
               runtime_context
             )

    assert {:ok, %{count: 1, goals: [%{id: ^goal_id}]}} =
             Toolbox.execute("list_goals", %{"status" => "active"}, runtime_context)

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
