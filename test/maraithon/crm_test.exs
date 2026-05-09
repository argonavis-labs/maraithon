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
end
