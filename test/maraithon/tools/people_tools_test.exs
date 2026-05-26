defmodule Maraithon.Tools.PeopleToolsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
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
               "max_results" => 5,
               "timeout_ms" => 1_000
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

    assert [observation] = review.source_observations
    assert observation.source == "crm"
    assert observation.resource_type == "person"
    assert observation.title == "Charlie Jones"
    assert observation.summary == "Runner collaborator"
    assert observation.metadata.relationship_strength == 64
  end

  test "review_connected_context includes local iMessage and Apple Notes evidence" do
    user_id = "people-review-local-#{System.unique_integer([:positive])}@example.com"
    device_id = Ecto.UUID.generate()
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, %{accepted: 1}} =
      LocalMessages.ingest_batch(user_id, device_id, [
        %{
          "local_id" => "msg:emma-soccer",
          "guid" => "msg-emma-soccer",
          "service" => "iMessage",
          "is_from_me" => false,
          "sender_handle" => "+14165550199",
          "chat_handles" => ["+14165550199"],
          "chat_display_name" => "Emma Soccer",
          "chat_style" => "im",
          "text" => "Emma soccer practice moved to Sunday morning.",
          "sent_at" => "2026-05-24T13:14:22Z",
          "has_attachments" => false,
          "attachments" => []
        }
      ])

    {:ok, %{accepted: 1}} =
      LocalNotes.ingest_batch(user_id, device_id, [
        %{
          "local_id" => "note:emma-soccer",
          "guid" => "note-emma-soccer",
          "title" => "Emma soccer logistics",
          "snippet" => "Bring cleats and confirm pickup.",
          "folder" => "Family",
          "is_pinned" => false,
          "created_at" => "2026-05-23T08:00:00Z",
          "modified_at" => "2026-05-24T12:00:00Z"
        }
      ])

    assert {:ok, review} =
             Tools.execute("review_connected_context", %{
               "user_id" => user_id,
               "query" => "Emma soccer",
               "sources" => ["imessage", "apple_notes"],
               "max_results" => 5,
               "timeout_ms" => 1_000
             })

    assert Enum.sort(review.reviewed_sources) == ["messages", "notes"]
    assert review.results["messages"].count == 1
    assert review.results["notes"].count == 1

    assert Enum.any?(review.source_observations, fn observation ->
             observation.source == "imessage" and
               observation.resource_type == "message" and
               observation.title == "Emma Soccer" and
               observation.summary =~ "Sunday morning"
           end)

    assert Enum.any?(review.source_observations, fn observation ->
             observation.source == "apple_notes" and
               observation.resource_type == "note" and
               observation.title == "Emma soccer logistics"
           end)
  end

  test "review_connected_context reports connector errors against the source" do
    user_id = "people-review-error-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, review} =
             Tools.execute("review_connected_context", %{
               "user_id" => user_id,
               "query" => "Charlie",
               "sources" => ["gmail"],
               "max_results" => 5,
               "timeout_ms" => 1_000
             })

    assert review.reviewed_sources == ["gmail"]
    assert review.source_freshness == []
    assert review.results["gmail"].source == "gmail"
    assert [%{source: "gmail", reason: reason}] = review.errors
    assert reason in ["no_token", "google_account_not_connected"] or reason =~ "no_token"
  end

  test "merge_people tool collapses duplicate CRM people" do
    user_id = "people-merge-tool-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, first} =
      Tools.execute("upsert_person", %{
        "user_id" => user_id,
        "person" => %{
          "display_name" => "Charlie Smith",
          "email" => "charlie@example.com"
        }
      })

    {:ok, second} =
      Tools.execute("upsert_person", %{
        "user_id" => user_id,
        "person" => %{
          "display_name" => "Charles Smith",
          "slack_id" => "UCHARLIE"
        }
      })

    assert {:ok, result} =
             Tools.execute("merge_people", %{
               "user_id" => user_id,
               "surviving_person_id" => first.person.id,
               "merged_person_id" => second.person.id,
               "evidence" => "Same person across email and Slack.",
               "model_rationale" => "Same collaborator."
             })

    assert result.source == "maraithon_crm"
    assert result.merge.surviving_person.id == first.person.id
    assert result.merge.merged_person.status == "merged"

    assert {:ok, listed} =
             Tools.execute("list_people", %{
               "user_id" => user_id,
               "query" => "Charlie"
             })

    assert listed.count == 1
    assert [person] = listed.people
    assert person.id == first.person.id
  end
end
