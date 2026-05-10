defmodule Maraithon.CrmTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Todos

  test "upserts people by contact details and normalizes relationship fields" do
    user_id = "crm-person-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, person} =
             Crm.upsert_person(user_id, %{
               "firstName" => "Charlie",
               "lastName" => "Smith",
               "email" => "charlie@example.com",
               "slack_id" => "U123",
               "preferred_communication_method" => "slack",
               "relationship" => "Runner teammate",
               "communication_frequency" => "weekly"
             })

    assert person.display_name == "Charlie Smith"
    assert person.contact_details["emails"] == ["charlie@example.com"]
    assert person.contact_details["slack_ids"] == ["U123"]

    assert {:ok, updated} =
             Crm.upsert_person(user_id, %{
               "email" => "charlie@example.com",
               "relationship" => "Runner GTM teammate",
               "notes" => "Prefers short Slack pings before calls."
             })

    assert updated.id == person.id
    assert updated.display_name == "Charlie Smith"
    assert updated.relationship == "Runner GTM teammate"
    assert updated.notes =~ "Slack pings"
    assert updated.contact_details["emails"] == ["charlie@example.com"]
    assert updated.contact_details["slack_ids"] == ["U123"]

    assert [listed] = Crm.list_people(user_id, query: "charlie")
    assert listed.id == person.id
  end

  test "grows relationship metrics from repeated model-backed observations" do
    user_id = "crm-metrics-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, person} =
             Crm.upsert_person(user_id, %{
               "display_name" => "Charlie Jones",
               "email" => "charlie@example.com",
               "relationship_strength" => 40,
               "affinity_score" => 35,
               "interaction_count_delta" => 2,
               "last_interaction_at" => "2026-05-08T14:00:00Z"
             })

    assert person.interaction_count == 2
    assert person.relationship_strength == 40
    assert person.affinity_score == 35

    assert {:ok, updated} =
             Crm.upsert_person(user_id, %{
               "email" => "charlie@example.com",
               "relationship_strength_delta" => 8,
               "affinity_delta" => 5,
               "interaction_count_delta" => 1,
               "last_interaction_at" => "2026-05-09T14:00:00Z"
             })

    assert updated.id == person.id
    assert updated.interaction_count == 3
    assert updated.relationship_strength == 48
    assert updated.affinity_score == 40
    assert DateTime.compare(updated.last_interaction_at, ~U[2026-05-09 14:00:00Z]) == :eq
  end

  test "links a person to todos and returns relationship context" do
    user_id = "crm-link-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, person} =
      Crm.upsert_person(user_id, %{
        "first_name" => "Justin",
        "last_name" => "Dean",
        "email" => "justin@example.com",
        "relationship" => "Investor",
        "preferred_communication_method" => "email",
        "communication_frequency" => "monthly"
      })

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "general",
          "title" => "Reply to Justin",
          "summary" => "Justin is waiting for a financing update.",
          "next_action" => "Send the promised update.",
          "dedupe_key" => "crm-link:justin-reply"
        }
      ])

    assert {:ok, link} =
             Crm.attach_resource(user_id, person.id, %{
               "resource_type" => "todo",
               "resource_id" => todo.id,
               "resource_source" => "gmail",
               "title" => todo.title,
               "relationship_note" => "This is follow-up work owed to Justin."
             })

    assert link.person_id == person.id

    assert {:ok, context} = Crm.relationship_context(user_id, %{"query" => "Justin"})
    assert context.person.id == person.id
    assert context.open_todo_count == 1
    assert [%{id: todo_id}] = context.todos
    assert todo_id == todo.id

    [batched_context] = Crm.relationship_contexts(user_id, [person], link_limit: 5)
    assert batched_context.person.id == person.id
    assert batched_context.open_todo_count == 1
    assert [%{id: ^todo_id}] = batched_context.todos
  end

  describe "resolve_contact/3" do
    setup do
      user_id = "crm-resolve-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      %{user_id: user_id}
    end

    test "returns the existing person when an email matches", %{user_id: user_id} do
      {:ok, original} =
        Crm.upsert_person(user_id, %{
          "display_name" => "Charlie Smith",
          "email" => "charlie@example.com"
        })

      assert {:ok, found} = Crm.resolve_contact(user_id, %{email: "charlie@example.com"})
      assert found.id == original.id
    end

    test "creates a stub person from an email when none matches", %{user_id: user_id} do
      assert {:ok, person} = Crm.resolve_contact(user_id, %{email: "Dana.Lee@example.com"})

      assert person.user_id == user_id
      assert person.display_name == "Dana Lee"
      assert person.contact_details["emails"] == ["Dana.Lee@example.com"]
      assert person.interaction_count == 0
    end

    test "honours an explicit display_name override", %{user_id: user_id} do
      assert {:ok, person} =
               Crm.resolve_contact(user_id, %{email: "x@y.com"}, display_name: "Custom Name")

      assert person.display_name == "Custom Name"
    end

    test "creates a stub from a slack id", %{user_id: user_id} do
      assert {:ok, person} = Crm.resolve_contact(user_id, %{slack_id: "U7XQ"})
      assert person.contact_details["slack_ids"] == ["U7XQ"]
      assert person.display_name == "U7XQ"
    end

    test "rejects an empty identifier", %{user_id: user_id} do
      assert {:error, :unresolvable_contact} = Crm.resolve_contact(user_id, %{email: ""})
      assert {:error, :unresolvable_contact} = Crm.resolve_contact(user_id, %{})
    end
  end

  describe "bump_interaction/3" do
    setup do
      user_id = "crm-bump-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, person} =
        Crm.upsert_person(user_id, %{
          "display_name" => "Charlie",
          "email" => "charlie@example.com"
        })

      %{user_id: user_id, person: person}
    end

    test "increments interaction_count and sets last_interaction_at on first bump",
         %{person: person} do
      occurred_at = DateTime.add(DateTime.utc_now(), -10, :minute)
      assert {:ok, :bumped} = Crm.bump_interaction(person.id, occurred_at, "gmail")

      reloaded = Maraithon.Repo.get!(Maraithon.Crm.Person, person.id)
      assert reloaded.interaction_count == 1
      assert DateTime.compare(reloaded.last_interaction_at, occurred_at) == :eq
    end

    test "second bump increments and only advances last_interaction_at forward",
         %{person: person} do
      first = DateTime.add(DateTime.utc_now(), -2, :hour)
      older = DateTime.add(first, -1, :day)

      assert {:ok, :bumped} = Crm.bump_interaction(person.id, first, "gmail")
      assert {:ok, :bumped} = Crm.bump_interaction(person.id, older, "gmail")

      reloaded = Maraithon.Repo.get!(Maraithon.Crm.Person, person.id)
      assert reloaded.interaction_count == 2
      assert DateTime.compare(reloaded.last_interaction_at, first) == :eq
    end

    test "later occurred_at advances last_interaction_at", %{person: person} do
      first = DateTime.add(DateTime.utc_now(), -2, :hour)
      later = DateTime.add(first, 30, :minute)

      assert {:ok, :bumped} = Crm.bump_interaction(person.id, first, "gmail")
      assert {:ok, :bumped} = Crm.bump_interaction(person.id, later, "slack")

      reloaded = Maraithon.Repo.get!(Maraithon.Crm.Person, person.id)
      assert reloaded.interaction_count == 2
      assert DateTime.compare(reloaded.last_interaction_at, later) == :eq
    end

    test "returns :person_not_found for an unknown id" do
      assert {:error, :person_not_found} =
               Crm.bump_interaction(Ecto.UUID.generate(), DateTime.utc_now(), "gmail")
    end
  end
end
