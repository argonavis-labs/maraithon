defmodule Maraithon.Runtime.BackgroundJobHandlerGoalPeopleDiscoveryTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Goals
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobHandler

  test "executes the goal_people_discovery job" do
    user_id = "goal-people-handler-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _person} =
      Crm.create_person(user_id, %{
        "display_name" => "Jordan Seed",
        "relationship" => "Seed investor"
      })

    {:ok, _goal} =
      Goals.create_goal(user_id, %{
        "category" => "work",
        "title" => "Close seed financing",
        "desired_outcome" => "Investor follow-through is focused.",
        "priority" => 80
      })

    job = %BackgroundJob{
      user_id: user_id,
      job_type: "goal_people_discovery",
      queue: "relationships",
      payload: %{"people_limit" => 50, "goal_limit" => 5, "links_per_goal" => 5}
    }

    assert {:ok, result} = BackgroundJobHandler.execute(job)
    assert result.source == "goal_people_discovery"
    assert result.goals_checked == 1
    assert result.people_scanned == 1
    assert result.links_created_or_updated >= 1
  end
end
