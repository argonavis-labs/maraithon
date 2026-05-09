defmodule Maraithon.OpenLoopsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Memory
  alias Maraithon.OpenLoops

  test "ingest_todos enriches persisted todos with explicit people and memories" do
    user_id = unique_user_email("open-loops")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    candidates = [
      %{
        "source" => "slack",
        "title" => "Reply to Sam about launch",
        "summary" => "Sam asked for the launch plan in Slack.",
        "next_action" => "Send Sam the launch-plan answer.",
        "dedupe_key" => "slack:sam-launch",
        "people" => [
          %{
            "first_name" => "Sam",
            "last_name" => "Rivers",
            "email" => "sam.openloops@example.com",
            "preferred_communication_method" => "slack",
            "relationship" => "Customer sponsor",
            "communication_frequency" => "weekly",
            "relationship_note" => "Sam is the person waiting on this todo."
          }
        ],
        "memories" => [
          %{
            "kind" => "relationship",
            "title" => "Sam prefers launch updates in Slack",
            "content" => "Sam Rivers prefers launch-plan updates in Slack.",
            "tags" => ["sam", "relationship"],
            "importance" => 80,
            "dedupe_key" => "open-loops:sam-slack"
          }
        ]
      }
    ]

    llm_complete = fn prompt ->
      assert prompt =~ "TODO_INTELLIGENCE_JSON_V1"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Created one Slack todo.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "create",
                 "dedupe_key" => "slack:sam-launch",
                 "reasoning" => "New explicit launch follow-up.",
                 "todo" => %{
                   "source" => "slack",
                   "title" => "Reply to Sam about launch",
                   "summary" => "Sam asked for the launch plan in Slack.",
                   "next_action" => "Send Sam the launch-plan answer.",
                   "due_at" => "2026-05-09T17:00:00Z",
                   "dedupe_key" => "slack:sam-launch",
                   "metadata" => %{"slack_thread_ts" => "1710000000.000000"}
                 }
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             OpenLoops.ingest_todos(user_id, candidates,
               source: "test_open_loops",
               llm_complete: llm_complete
             )

    assert result.summary == "Created one Slack todo."
    assert result.skipped_count == 0
    assert [%{person_name: "Sam Rivers"}] = result.enrichment.person_links
    assert [%{title: "Sam prefers launch updates in Slack"}] = result.enrichment.memories
    assert result.enrichment.errors == []

    assert [%{display_name: "Sam Rivers"} = person] = Crm.list_people(user_id, query: "Sam")

    assert {:ok, relationship} = Crm.relationship_context(user_id, %{person_id: person.id})
    assert relationship.open_todo_count == 1
    assert [todo] = relationship.todos
    assert todo.title == "Reply to Sam about launch"

    assert [memory] = Memory.list_items(user_id, query: "Sam prefers launch", limit: 5)
    assert memory.source_ref_type == "todo"
    assert memory.source_ref_id == todo.id

    snapshot =
      OpenLoops.snapshot(user_id,
        query: "Sam launch",
        now: ~U[2026-05-09 12:00:00Z],
        limit: 10
      )

    assert snapshot.source == "maraithon_open_loops"
    assert snapshot.totals.open_todos == 1
    assert snapshot.totals.due_today == 1
    assert snapshot.totals.people_with_open_todos == 1
    assert [%{title: "Reply to Sam about launch"}] = snapshot.buckets.today
    assert [%{person: %{display_name: "Sam Rivers"}, open_todo_count: 1}] = snapshot.people
    assert snapshot.memory.count >= 1
  end

  defp unique_user_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.com"
  end
end
