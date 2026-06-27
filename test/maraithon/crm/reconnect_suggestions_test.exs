defmodule Maraithon.Crm.ReconnectSuggestionsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Goals
  alias Maraithon.Todos

  defp user_id do
    id = "reconnect-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(id)
    id
  end

  defp person_with(user_id, attrs) do
    {:ok, person} = Crm.create_person(user_id, attrs)
    person
  end

  defp set_signals(person, signals) do
    metadata = Map.put(person.metadata || %{}, "communication_signals", signals)
    {:ok, updated} = Crm.update_person(person, %{"metadata" => metadata})
    updated
  end

  test "links open work to a person and leads with it as the reconnect reason" do
    uid = user_id()

    person =
      person_with(uid, %{
        "first_name" => "Jane",
        "display_name" => "Jane Thuet",
        "relationship" => "client",
        "communication_frequency" => "weekly"
      })

    {:ok, [todo]} =
      Todos.upsert_many(uid, [
        %{
          "source" => "gmail",
          "kind" => "general",
          "title" => "Reply to Jane about the Team plan",
          "summary" => "Jane is waiting on pricing.",
          "next_action" => "Send the Team plan pricing.",
          "dedupe_key" => "reconnect-open-work"
        }
      ])

    {:ok, _link} =
      Crm.attach_resource(uid, person.id, %{
        "resource_type" => "todo",
        "resource_id" => todo.id,
        "role" => "owed_to",
        "title" => todo.title
      })

    assert [suggestion] = Crm.reconnect_suggestions(uid)
    assert suggestion.person.id == person.id
    assert suggestion.category == :open_work
    assert suggestion.headline == "Open work"
    assert suggestion.reason =~ "Jane"
    assert suggestion.reason =~ "Team plan"
    assert [%{title: "Reply to Jane about the Team plan"}] = suggestion.open_work
    assert suggestion.suggested_action =~ "Team plan"
  end

  test "flags an overdue cadence even without linked work" do
    uid = user_id()

    person =
      person_with(uid, %{
        "first_name" => "Sam",
        "display_name" => "Sam Rivera",
        "relationship" => "friend"
      })
      |> set_signals(%{
        "overdue" => true,
        "days_since_last" => 24,
        "cadence_days" => 7,
        "score" => 55
      })

    # communication_score is system-owned (not in the changeset); seed it
    # directly so the candidate pool includes this person.
    Repo.update_all(
      from(p in Maraithon.Crm.Person, where: p.id == ^person.id),
      set: [communication_score: 55]
    )

    assert [suggestion] = Crm.reconnect_suggestions(uid)
    assert suggestion.category == :overdue
    assert suggestion.days_since_last == 24
    assert suggestion.cadence_days == 7
    assert suggestion.reason =~ "24 days"
  end

  test "drops noise contacts with no score, strength, work, or overdue signal" do
    uid = user_id()

    _noise =
      person_with(uid, %{
        "first_name" => "Newsletter",
        "display_name" => "Daily Digest"
      })

    assert Crm.reconnect_suggestions(uid) == []
  end

  test "surfaces people linked to active goals without requiring high communication volume" do
    uid = user_id()

    person =
      person_with(uid, %{
        "first_name" => "Avery",
        "display_name" => "Avery Chen",
        "relationship" => "Investor"
      })

    {:ok, goal} =
      Goals.create_goal(uid, %{
        "category" => "work",
        "title" => "Close the seed round",
        "desired_outcome" => "Investor follow-through is focused on the seed round.",
        "priority" => 80
      })

    assert {:ok, _link} =
             Goals.link_resource(uid, goal.id, %{
               "resource_type" => "person",
               "resource_id" => person.id,
               "relationship" => "supports",
               "source" => "agent",
               "confidence" => 0.92
             })

    assert [suggestion] = Crm.reconnect_suggestions(uid)
    assert suggestion.person.id == person.id
    assert suggestion.category == :goal_aligned
    assert suggestion.headline == "Goal aligned"
    assert suggestion.reason =~ "Close the seed round"
    assert [%{title: "Close the seed round"}] = suggestion.goals
    assert suggestion.suggested_action =~ "Close the seed round"
  end

  test "keeps low-volume goal opportunities visible when open work fills the limit" do
    uid = user_id()

    goal_person =
      person_with(uid, %{
        "display_name" => "Avery Chen",
        "relationship" => "Angel investor"
      })

    {:ok, goal} =
      Goals.create_goal(uid, %{
        "category" => "work",
        "title" => "Close the seed round",
        "desired_outcome" => "Investor follow-through is focused on the seed round.",
        "priority" => 80
      })

    assert {:ok, _link} =
             Goals.link_resource(uid, goal.id, %{
               "resource_type" => "person",
               "resource_id" => goal_person.id,
               "relationship" => "supports",
               "source" => "agent",
               "confidence" => 0.9
             })

    for index <- 1..4 do
      work_person =
        person_with(uid, %{
          "first_name" => "Work #{index}",
          "display_name" => "Work Person #{index}"
        })

      Repo.update_all(
        from(p in Maraithon.Crm.Person, where: p.id == ^work_person.id),
        set: [communication_score: 95, relationship_strength: 95]
      )

      {:ok, [todo]} =
        Todos.upsert_many(uid, [
          %{
            "source" => "gmail",
            "kind" => "general",
            "title" => "Ship contract #{index}",
            "summary" => "Owed.",
            "next_action" => "Send it.",
            "dedupe_key" => "reconnect-balanced-work-#{index}"
          }
        ])

      {:ok, _} =
        Crm.attach_resource(uid, work_person.id, %{
          "resource_type" => "todo",
          "resource_id" => todo.id,
          "role" => "owed_to",
          "title" => todo.title
        })
    end

    suggestions = Crm.reconnect_suggestions(uid, limit: 3)

    assert Enum.any?(suggestions, &(&1.person.id == goal_person.id))
    assert Enum.any?(suggestions, &(&1.category == :goal_aligned))
  end

  test "goal opportunities explain the goal even when the person also has open work" do
    uid = user_id()

    person =
      person_with(uid, %{
        "first_name" => "Avery",
        "display_name" => "Avery Chen"
      })

    {:ok, [todo]} =
      Todos.upsert_many(uid, [
        %{
          "source" => "gmail",
          "kind" => "general",
          "title" => "Send Avery the contract",
          "summary" => "Avery is waiting.",
          "next_action" => "Send it.",
          "dedupe_key" => "reconnect-goal-opportunity-open-work"
        }
      ])

    {:ok, _} =
      Crm.attach_resource(uid, person.id, %{
        "resource_type" => "todo",
        "resource_id" => todo.id,
        "role" => "owed_to",
        "title" => todo.title
      })

    {:ok, goal} =
      Goals.create_goal(uid, %{
        "category" => "work",
        "title" => "Close the seed round",
        "desired_outcome" => "Investor follow-through is focused on the seed round.",
        "priority" => 80
      })

    {:ok, _link} =
      Goals.link_resource(uid, goal.id, %{
        "resource_type" => "person",
        "resource_id" => person.id,
        "relationship" => "supports",
        "source" => "agent",
        "confidence" => 0.9
      })

    assert [suggestion] = Crm.goal_people_opportunities(uid, limit: 3)
    assert suggestion.person.id == person.id
    assert suggestion.category == :goal_aligned
    assert suggestion.reason =~ "Close the seed round"
    assert [%{title: "Send Avery the contract"}] = suggestion.open_work
  end

  test "goal opportunities collapse duplicate people with the same display name" do
    uid = user_id()

    {:ok, goal} =
      Goals.create_goal(uid, %{
        "category" => "life",
        "title" => "Husband of the Year",
        "desired_outcome" => "Plan thoughtful family moments.",
        "priority" => 80
      })

    first = person_with(uid, %{"display_name" => "Christina Giannone"})
    second = person_with(uid, %{"display_name" => "Christina Giannone"})

    for person <- [first, second] do
      {:ok, _link} =
        Goals.link_resource(uid, goal.id, %{
          "resource_type" => "person",
          "resource_id" => person.id,
          "relationship" => "supports",
          "source" => "agent",
          "confidence" => 0.9
        })
    end

    assert [suggestion] = Crm.goal_people_opportunities(uid, limit: 5)
    assert suggestion.person.display_name == "Christina Giannone"
  end

  test "ranks open work above a bare overdue cadence" do
    uid = user_id()

    work_person =
      person_with(uid, %{"first_name" => "Work", "display_name" => "Work Person"})

    Repo.update_all(
      from(p in Maraithon.Crm.Person, where: p.id == ^work_person.id),
      set: [communication_score: 30, relationship_strength: 30]
    )

    {:ok, [todo]} =
      Todos.upsert_many(uid, [
        %{
          "source" => "gmail",
          "kind" => "general",
          "title" => "Ship the contract",
          "summary" => "Owed.",
          "next_action" => "Send it.",
          "dedupe_key" => "reconnect-rank-work"
        }
      ])

    {:ok, _} =
      Crm.attach_resource(uid, work_person.id, %{
        "resource_type" => "todo",
        "resource_id" => todo.id,
        "role" => "owed_to",
        "title" => todo.title
      })

    overdue_person =
      person_with(uid, %{"first_name" => "Overdue", "display_name" => "Overdue Person"})
      |> set_signals(%{"overdue" => true, "days_since_last" => 40, "cadence_days" => 7})

    Repo.update_all(
      from(p in Maraithon.Crm.Person, where: p.id == ^overdue_person.id),
      set: [communication_score: 80]
    )

    suggestions = Crm.reconnect_suggestions(uid)
    assert [first, second] = suggestions
    assert first.person.id == work_person.id
    assert first.category == :open_work
    assert second.person.id == overdue_person.id
  end
end
