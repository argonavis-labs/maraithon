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

  test "ingest_todos normalizes model-suggested memory kind aliases during enrichment" do
    user_id = unique_user_email("open-loops-memory-kind")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    candidates = [
      %{
        "source" => "chief_of_staff_morning_briefing",
        "title" => "Send Sissi the partner answer",
        "summary" => "Sissi asked how Runner's partner program works.",
        "next_action" => "Send Sissi the clean partner-program answer.",
        "dedupe_key" => "morning:sissi-partner-answer",
        "memories" => [
          %{
            "kind" => "professional_contact",
            "title" => "Sissi Wang is a workshop-driven partner lead",
            "content" =>
              "Sissi Wang at ideamatch.ai ran a Runner workshop and asked how the partner program works.",
            "tags" => ["runner", "partnerships", "ideamatch"],
            "dedupe_key" => "memory:contact:sissi_wang:ideamatch_runner_partner_interest"
          }
        ]
      }
    ]

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Created one partner follow-up.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "create",
                 "dedupe_key" => "morning:sissi-partner-answer",
                 "reasoning" => "New partner-program follow-up.",
                 "todo" => Enum.at(candidates, 0)
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             OpenLoops.ingest_todos(user_id, candidates,
               source: "chief_of_staff_morning_briefing",
               llm_complete: llm_complete
             )

    assert [%{title: "Sissi Wang is a workshop-driven partner lead"}] = result.enrichment.memories
    assert result.enrichment.errors == []

    assert [memory] = Memory.list_items(user_id, query: "Sissi Wang", limit: 5)
    assert memory.kind == "relationship"
    assert memory.metadata["original_memory_kind"] == "professional_contact"
  end

  test "ingest_todos enriches from model-written todo metadata" do
    user_id = unique_user_email("open-loops-model")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    candidates = [
      %{
        "source" => "gmail",
        "title" => "Return Emma permission form",
        "summary" => "A school email says Emma's permission form is due Friday.",
        "next_action" => "Send the signed permission form back to school.",
        "dedupe_key" => "gmail:thread:emma-permission"
      }
    ]

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Created one school todo.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "create",
                 "dedupe_key" => "gmail:thread:emma-permission",
                 "reasoning" => "New parent logistics action.",
                 "todo" => %{
                   "source" => "gmail",
                   "kind" => "gmail_triage",
                   "title" => "Return Emma permission form",
                   "summary" => "A school email says Emma's permission form is due Friday.",
                   "next_action" => "Send the signed permission form back to school.",
                   "dedupe_key" => "gmail:thread:emma-permission",
                   "metadata" => %{
                     "crm_people" => [
                       %{
                         "display_name" => "Emma",
                         "relationship" => "child",
                         "relationship_note" => "This todo is about Emma's school logistics."
                       }
                     ],
                     "relationship_memories" => [
                       %{
                         "kind" => "relationship",
                         "title" => "Emma school logistics should be treated as parent actions",
                         "content" =>
                           "School permission forms and classroom updates about Emma should be framed as parent actions.",
                         "tags" => ["emma", "school"],
                         "importance" => 85,
                         "confidence" => 0.9,
                         "dedupe_key" => "open-loops-model:emma-school"
                       }
                     ]
                   }
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

    assert [%{person_name: "Emma"}] = result.enrichment.person_links

    assert [%{title: "Emma school logistics should be treated as parent actions"}] =
             result.enrichment.memories

    assert [%{display_name: "Emma"}] = Crm.list_people(user_id, query: "Emma")
    assert [memory] = Memory.list_items(user_id, query: "Emma school logistics", limit: 5)
    assert memory.source_ref_type == "todo"
  end

  describe "local_observations/2" do
    test "emits imessage_pending_reply observation for non-self message younger than 24h with a question" do
      user_id = unique_user_email("local-obs-imsg")
      {:ok, _} = Accounts.get_or_create_user_by_email(user_id)
      device_id = Ecto.UUID.generate()
      now = ~U[2026-05-10 12:00:00Z]

      {:ok, _} =
        Maraithon.LocalMessages.ingest_batch(user_id, device_id, [
          %{
            "guid" => "msg-q",
            "local_id" => "p:q",
            "service" => "iMessage",
            "is_from_me" => false,
            "sender_handle" => "+14165550199",
            "chat_handles" => ["+14165550199"],
            "chat_display_name" => "Charlie",
            "chat_style" => "im",
            "text" => "Can you confirm the price?",
            "sent_at" => DateTime.to_iso8601(DateTime.add(now, -2 * 3_600, :second))
          },
          %{
            "guid" => "msg-mine",
            "local_id" => "p:mine",
            "service" => "iMessage",
            "is_from_me" => true,
            "sender_handle" => "+14165550000",
            "chat_handles" => ["+14165550000"],
            "chat_style" => "im",
            "text" => "Sounds good.",
            "sent_at" => DateTime.to_iso8601(DateTime.add(now, -3_600, :second))
          },
          %{
            "guid" => "msg-old",
            "local_id" => "p:old",
            "service" => "iMessage",
            "is_from_me" => false,
            "sender_handle" => "+14165550199",
            "chat_handles" => ["+14165550199"],
            "chat_style" => "im",
            "text" => "Are we still on?",
            "sent_at" => DateTime.to_iso8601(DateTime.add(now, -36 * 3_600, :second))
          },
          %{
            "guid" => "msg-fyi",
            "local_id" => "p:fyi",
            "service" => "iMessage",
            "is_from_me" => false,
            "sender_handle" => "+14165550199",
            "chat_handles" => ["+14165550199"],
            "chat_style" => "im",
            "text" => "Thanks.",
            "sent_at" => DateTime.to_iso8601(DateTime.add(now, -1_800, :second))
          }
        ])

      observations = OpenLoops.local_observations(user_id, now: now)
      imsg = Enum.filter(observations, &(&1["type"] == "imessage_pending_reply"))

      assert length(imsg) == 1
      [obs] = imsg
      assert obs["source"] == "imessage"
      assert obs["excerpt"] =~ "confirm the price"
      assert get_in(obs, ["metadata", "open_loop_hint", "title"]) =~ "Reply to Charlie"
    end

    test "emits reminder_due_today observation for open reminders due within 24h" do
      user_id = unique_user_email("local-obs-rem")
      {:ok, _} = Accounts.get_or_create_user_by_email(user_id)
      device_id = Ecto.UUID.generate()
      now = ~U[2026-05-10 12:00:00Z]

      {:ok, _} =
        Maraithon.LocalReminders.ingest_batch(user_id, device_id, [
          %{
            "guid" => "rem-due",
            "title" => "Pay invoice",
            "list_name" => "Finance",
            "priority" => 1,
            "due_at" => DateTime.to_iso8601(DateTime.add(now, 4 * 3_600, :second)),
            "is_completed" => false
          },
          %{
            "guid" => "rem-far",
            "title" => "Schedule offsite",
            "list_name" => "Work",
            "due_at" => DateTime.to_iso8601(DateTime.add(now, 6 * 86_400, :second)),
            "is_completed" => false
          }
        ])

      observations = OpenLoops.local_observations(user_id, now: now)
      due = Enum.filter(observations, &(&1["type"] == "reminder_due_today"))

      assert [obs] = due
      assert obs["source"] == "reminders"
      assert obs["subject"] == "Pay invoice"
      assert get_in(obs, ["metadata", "open_loop_hint", "title"]) == "Pay invoice"
    end

    test "emits voice_memo_unprocessed observation for memos under 48h old" do
      user_id = unique_user_email("local-obs-vm")
      {:ok, _} = Accounts.get_or_create_user_by_email(user_id)
      device_id = Ecto.UUID.generate()
      now = ~U[2026-05-10 12:00:00Z]

      {:ok, _} =
        Maraithon.LocalVoiceMemos.ingest_batch(user_id, device_id, [
          %{
            "guid" => "vm-fresh",
            "title" => "Strategy idea",
            "snippet" => "Thought about product...",
            "duration_seconds" => 60,
            "created_at" => DateTime.to_iso8601(DateTime.add(now, -6 * 3_600, :second))
          },
          %{
            "guid" => "vm-stale",
            "title" => "Older recording",
            "duration_seconds" => 30,
            "created_at" => DateTime.to_iso8601(DateTime.add(now, -72 * 3_600, :second))
          }
        ])

      observations = OpenLoops.local_observations(user_id, now: now)
      memos = Enum.filter(observations, &(&1["type"] == "voice_memo_unprocessed"))

      assert [obs] = memos
      assert obs["source"] == "voice_memos"
      assert obs["subject"] == "Strategy idea"

      assert get_in(obs, ["metadata", "open_loop_hint", "title"]) ==
               "Review yesterday's voice memos"
    end
  end

  defp unique_user_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.com"
  end
end
