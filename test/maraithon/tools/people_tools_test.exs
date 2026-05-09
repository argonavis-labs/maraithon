defmodule Maraithon.Tools.PeopleToolsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Todos
  alias Maraithon.Tools

  test "CRM tools CRUD people and expose relationship context" do
    user_id = "people-tools-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, upserted} =
             Tools.execute("upsert_person", %{
               "user_id" => user_id,
               "person" => %{
                 "first_name" => "Sam",
                 "last_name" => "Rivers",
                 "contact_details" => %{
                   "emails" => ["sam@example.com"],
                   "slack_ids" => ["U999"]
                 },
                 "preferred_communication_method" => "slack",
                 "relationship" => "Customer sponsor",
                 "communication_frequency" => "biweekly"
               }
             })

    person = upserted.person
    assert upserted.source == "maraithon_crm"
    assert person.display_name == "Sam Rivers"

    assert {:ok, listed} =
             Tools.execute("list_people", %{
               "user_id" => user_id,
               "query" => "sam"
             })

    assert listed.count == 1

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "slack",
          "title" => "Send Sam onboarding notes",
          "summary" => "Sam needs the onboarding notes after the customer call.",
          "next_action" => "Send Sam the notes in Slack.",
          "dedupe_key" => "people-tools:sam-onboarding"
        }
      ])

    assert {:ok, linked} =
             Tools.execute("link_person_data", %{
               "user_id" => user_id,
               "person_id" => person.id,
               "todo_id" => todo.id,
               "resource_source" => "slack",
               "title" => todo.title,
               "include_context" => true
             })

    assert linked.operation == "attach"
    assert linked.relationship_context.open_todo_count == 1

    assert {:ok, context_result} =
             Tools.execute("get_relationship_context", %{
               "user_id" => user_id,
               "query" => "Sam"
             })

    context = context_result.relationship_context
    assert context.person.id == person.id
    assert context.todo_count == 1
    assert [%{id: todo_id}] = context.todos
    assert todo_id == todo.id

    assert {:ok, deleted} =
             Tools.execute("delete_person", %{
               "user_id" => user_id,
               "person_id" => person.id
             })

    assert deleted.deleted == true

    assert {:ok, empty} =
             Tools.execute("list_people", %{
               "user_id" => user_id,
               "query" => "Sam"
             })

    assert empty.count == 0
  end

  test "review_connected_context returns source-grounded CRM evidence in one call" do
    user_id = "people-review-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _upserted} =
      Tools.execute("upsert_person", %{
        "user_id" => user_id,
        "person" => %{
          "display_name" => "Charlie Jones",
          "email" => "charlie@example.com",
          "relationship" => "Runner collaborator",
          "communication_frequency" => "recurring",
          "relationship_strength" => 64,
          "affinity_score" => 58,
          "interaction_count_delta" => 3,
          "last_interaction_at" => "2026-05-09T19:00:00Z"
        }
      })

    assert {:ok, review} =
             Tools.execute("review_connected_context", %{
               "user_id" => user_id,
               "query" => "Charlie",
               "sources" => ["crm"],
               "max_results" => 5
             })

    assert review.source == "connected_context"
    assert review.query == "Charlie"
    assert review.reviewed_sources == ["crm"]
    assert review.results["crm"].count == 1
    assert [person] = review.results["crm"].people
    assert person.display_name == "Charlie Jones"
    assert person.relationship_strength == 64
    assert person.affinity_score == 58
    assert person.interaction_count == 3
  end
end
