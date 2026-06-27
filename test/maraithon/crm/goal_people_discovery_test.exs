defmodule Maraithon.Crm.GoalPeopleDiscoveryTest do
  use Maraithon.DataCase, async: true

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Crm.GoalPeopleDiscovery
  alias Maraithon.Goals
  alias Maraithon.Goals.GoalLink
  alias Maraithon.Repo

  test "links broad low-volume people to active goals and feeds reconnect suggestions" do
    user_id = "goal-people-discovery-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, investor} =
      Crm.create_person(user_id, %{
        "display_name" => "Avery Chen",
        "relationship" => "Angel investor",
        "notes" => "Helpful on seed fundraising and venture intros."
      })

    {:ok, _high_volume_irrelevant} =
      Crm.create_person(user_id, %{
        "display_name" => "Daily Chat",
        "relationship" => "Frequent teammate",
        "interaction_count" => 100,
        "communication_score" => 100
      })

    {:ok, goal} =
      Goals.create_goal(user_id, %{
        "category" => "work",
        "title" => "Close the seed round",
        "desired_outcome" => "Investor follow-through is focused on the seed round.",
        "priority" => 80
      })

    assert {:ok, result} =
             GoalPeopleDiscovery.run(user_id, people_limit: 50, links_per_goal: 5)

    assert result.goals_checked == 1
    assert result.people_scanned == 2
    assert result.links_created_or_updated >= 1

    assert %GoalLink{} =
             Repo.one(
               from link in GoalLink,
                 where:
                   link.user_id == ^user_id and link.goal_id == ^goal.id and
                     link.resource_type == "person" and link.resource_id == ^investor.id and
                     link.relationship == "supports"
             )

    assert [suggestion] = Crm.reconnect_suggestions(user_id, limit: 3)
    assert suggestion.person.id == investor.id
    assert suggestion.category == :goal_aligned
    assert suggestion.reason =~ "Close the seed round"
  end

  test "does not link every person sharing an ambiguous first name" do
    user_id = "goal-people-ambiguous-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, spouse} =
      Crm.create_person(user_id, %{
        "display_name" => "Christina Giannone",
        "relationship" => "Spouse",
        "notes" => "Family logistics and travel planning with the kids.",
        "relationship_strength" => 100
      })

    {:ok, unrelated} =
      Crm.create_person(user_id, %{
        "display_name" => "Christina",
        "relationship" => "Tennis contact",
        "notes" => "Met through a local sports clinic.",
        "relationship_strength" => 100
      })

    {:ok, goal} =
      Goals.create_goal(user_id, %{
        "category" => "life",
        "title" => "Husband of the Year",
        "desired_outcome" => "Plan thoughtful family moments with Christina.",
        "priority" => 80
      })

    assert {:ok, _result} =
             GoalPeopleDiscovery.run(user_id, people_limit: 50, links_per_goal: 5)

    assert %GoalLink{} =
             Repo.one(
               from link in GoalLink,
                 where:
                   link.user_id == ^user_id and link.goal_id == ^goal.id and
                     link.resource_type == "person" and link.resource_id == ^spouse.id
             )

    refute Repo.exists?(
             from link in GoalLink,
               where:
                 link.user_id == ^user_id and link.goal_id == ^goal.id and
                   link.resource_type == "person" and link.resource_id == ^unrelated.id
           )
  end
end
