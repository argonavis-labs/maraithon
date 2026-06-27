defmodule Maraithon.Todos.IntelligenceTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Memory
  alias Maraithon.Todos

  test "ingest_many applies model create, update, and skip decisions" do
    user_id = unique_user_email("todo-intelligence")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [existing]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Reply to ACME renewal",
          "summary" => "ACME needs a reply about renewal timing.",
          "next_action" => "Reply with a concrete ETA.",
          "priority" => 70,
          "dedupe_key" => "gmail:renewal:acme"
        }
      ])

    candidates = [
      %{
        "source" => "gmail",
        "kind" => "gmail_triage",
        "title" => "ACME renewal reply is still open",
        "summary" => "The same ACME renewal thread still needs a reply.",
        "next_action" => "Send the updated renewal ETA.",
        "dedupe_key" => "candidate:duplicate"
      },
      %{
        "source" => "slack",
        "title" => "Review launch note",
        "summary" => "The GTM channel asked for a launch-note review.",
        "next_action" => "Review the launch note and leave approval or edits.",
        "dedupe_key" => "slack:launch-note-review"
      },
      %{
        "source" => "telegram",
        "title" => "FYI status note",
        "summary" => "A status note that should not create work.",
        "next_action" => "No action needed.",
        "dedupe_key" => "telegram:fyi-status"
      }
    ]

    llm_complete = fn prompt ->
      assert prompt =~ Todos.Intelligence.sentinel()
      assert prompt =~ existing.id
      assert prompt =~ "CANDIDATE_TODOS_JSON"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "One duplicate, one new item, one skip.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "update",
                 "existing_todo_id" => existing.id,
                 "reasoning" => "Same renewal work with fresher wording.",
                 "todo" => %{
                   "source" => "gmail",
                   "kind" => "gmail_triage",
                   "title" => "Reply to ACME renewal today",
                   "summary" => "The ACME renewal thread still needs an ETA.",
                   "next_action" => "Send the updated renewal ETA today.",
                   "dedupe_key" => existing.dedupe_key,
                   "priority" => 86,
                   "metadata" => %{"thread_id" => "thread-acme"}
                 }
               },
               %{
                 "candidate_index" => 1,
                 "action" => "create",
                 "dedupe_key" => "slack:launch-note-review",
                 "reasoning" => "New Slack review request.",
                 "todo" => %{
                   "source" => "slack",
                   "title" => "Review launch note",
                   "summary" => "The GTM channel asked for a launch-note review.",
                   "next_action" => "Review the launch note and leave approval or edits.",
                   "due_at" => "2026-05-10T18:00:00Z",
                   "notes" => "Mentioned in #runner-gtm.",
                   "action_plan" => "Open the launch note, scan claims, then approve or comment.",
                   "dedupe_key" => "slack:launch-note-review",
                   "metadata" => %{"channel_name" => "runner-gtm"}
                 }
               },
               %{
                 "candidate_index" => 2,
                 "action" => "skip",
                 "reasoning" => "FYI only; no durable user work."
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             Todos.ingest_many(user_id, candidates,
               llm_complete: llm_complete,
               source: "test"
             )

    assert result.summary == "One duplicate, one new item, one skip."
    assert length(result.todos) == 2
    assert result.skipped_count == 1

    updated = Todos.get_for_user(user_id, existing.id)
    assert updated.title == "Reply to ACME renewal today"
    assert updated.priority == 86
    assert get_in(updated.metadata, ["todo_intelligence", "action"]) == "update"

    [created] = Todos.list_for_user(user_id, source: "slack", limit: 5)
    assert created.title == "Review launch note"
    assert DateTime.to_date(created.due_at) == ~D[2026-05-10]
    assert created.action_plan =~ "Open the launch note"
    assert get_in(created.metadata, ["todo_intelligence", "source"]) == "test"
  end

  test "ingest_many forces update decisions to reuse the existing dedupe key" do
    user_id = unique_user_email("todo-intelligence-update-dedupe")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [existing]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "imessage",
          "title" => "Confirm Emma pickup and painting with Christina",
          "summary" => "Christina asked if you can get Emma and reminded you about the painting.",
          "next_action" => "Reply to Christina confirming you will pick up Emma.",
          "priority" => 80,
          "source_item_id" => "imessage-source-1",
          "dedupe_key" => "commitment:imessage:imessage-source-1:original"
        }
      ])

    candidates = [
      %{
        "source" => "imessage",
        "title" => "Confirm you have the painting for Emma's pickup",
        "summary" => "The same iMessage thread still needs painting confirmation.",
        "next_action" => "Reply to Christina confirming you have the painting.",
        "source_item_id" => "imessage-source-1",
        "dedupe_key" => "commitment:imessage:imessage-source-1:model-fresh-key",
        "metadata" => %{
          "direct_ask" => true,
          "source_evidence" =>
            "Christina asked if you can get Emma and whether you have the painting.",
          "why_it_matters" => "Christina is waiting on your confirmation before pickup."
        }
      }
    ]

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Updated the existing family logistics item.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "update",
                 "existing_todo_id" => existing.id,
                 "dedupe_key" => "commitment:imessage:imessage-source-1:decision-fresh-key",
                 "reasoning" => "Same underlying pickup and painting loop.",
                 "todo" => %{
                   "source" => "imessage",
                   "title" => "Confirm you have the painting for Emma's pickup",
                   "summary" => "Christina reminded you about the painting.",
                   "next_action" => "Reply to Christina confirming you have the painting.",
                   "source_item_id" => "imessage-source-1",
                   "dedupe_key" => "commitment:imessage:imessage-source-1:todo-fresh-key"
                 }
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             Todos.ingest_many(user_id, candidates,
               llm_complete: llm_complete,
               source: "test"
             )

    assert [%{id: existing_id, dedupe_key: existing_dedupe_key}] = result.todos
    assert existing_id == existing.id
    assert existing_dedupe_key == existing.dedupe_key

    assert [persisted] = Todos.list_recent_for_user(user_id, limit: 10)
    assert persisted.id == existing.id
    assert persisted.title == "Confirm you have the painting for Emma's pickup"
    assert persisted.dedupe_key == existing.dedupe_key
    refute persisted.dedupe_key =~ "fresh-key"
  end

  test "ingest_many rejects weak local family chatter even when model tries to promote it" do
    user_id = unique_user_email("todo-intelligence-local-chatter")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    candidates = [
      %{
        "source" => "imessage",
        "title" => "Follow up on Emma's painting",
        "summary" => "A family iMessage says, \"Also don't forget your painting.\"",
        "next_action" => "Reply to Christina confirming whether you have the painting.",
        "source_item_id" => "imessage-painting-1",
        "dedupe_key" => "commitment:imessage:painting:weak",
        "metadata" => %{
          "origin_skill_id" => "commitment_tracker",
          "quote" => "Also don't forget your painting",
          "source_ref" => "imessage imessage-painting-1",
          "source_tags" => ["family", "imessage"],
          "life_domain" => "family",
          "relationship_context" => "Family group chat context.",
          "why_it_matters" =>
            "Potential family logistics, but the source does not ask Kent to act.",
          "completion_check" => %{
            "status" => "open",
            "reasoning" => "The source phrase is still present.",
            "latest_source_checked_at" => "2026-06-18T17:00:00Z",
            "later_evidence" => []
          }
        }
      }
    ]

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Created one local family follow-up.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "create",
                 "dedupe_key" => "commitment:imessage:painting:weak",
                 "reasoning" => "The model misread a vague reminder as a direct ask.",
                 "todo" => %{
                   "source" => "imessage",
                   "title" => "Follow up on Emma's painting",
                   "summary" => "Christina reminded you about Emma's painting.",
                   "next_action" =>
                     "Reply to Christina confirming whether you have the painting.",
                   "source_item_id" => "imessage-painting-1",
                   "dedupe_key" => "commitment:imessage:painting:weak",
                   "metadata" => %{
                     "direct_ask" => true,
                     "quote" => "Also don't forget your painting",
                     "source_evidence" => "Also don't forget your painting",
                     "why_it_matters" => "Potential family logistics."
                   }
                 }
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             Todos.ingest_many(user_id, candidates,
               llm_complete: llm_complete,
               source: "test"
             )

    assert result.todos == []
    assert result.skipped_count == 1
    assert [%{action: "skip", candidate_index: 0, reasoning: reasoning}] = result.skipped
    assert reasoning =~ "local-message source evidence"
    assert [] = Todos.list_for_user(user_id, limit: 10)
  end

  test "ingest_many preserves source context metadata before quality scoring" do
    user_id = unique_user_email("todo-intelligence-source-context")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    candidates = [
      %{
        "source" => "gmail",
        "title" => "Reply to Dana about board packet",
        "summary" => "Dana asked for the board packet before the partner meeting.",
        "next_action" => "Reply to Dana with the board packet timing.",
        "dedupe_key" => "gmail:dana-board-packet",
        "metadata" => %{
          "source_evidence" => "Dana asked for the board packet before the partner meeting.",
          "source_refs" => ["gmail:thread-dana-board"],
          "why_it_matters" => "The partner meeting is waiting on this packet.",
          "direct_ask" => true,
          "confidence" => 0.92
        }
      }
    ]

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Created one source-backed follow-up.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "create",
                 "dedupe_key" => "gmail:dana-board-packet",
                 "reasoning" => "Dana made a direct request.",
                 "todo" => %{
                   "source" => "gmail",
                   "title" => "Reply to Dana about board packet",
                   "summary" => "Dana needs the board packet before the partner meeting.",
                   "next_action" => "Reply to Dana with the board packet timing.",
                   "dedupe_key" => "gmail:dana-board-packet"
                 }
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             Todos.ingest_many(user_id, candidates,
               llm_complete: llm_complete,
               source: "test"
             )

    assert [%{title: "Reply to Dana about board packet"} = created] = result.todos
    assert created.metadata["source_evidence"] =~ "Dana asked"
    assert created.metadata["source_refs"] == ["gmail:thread-dana-board"]
    assert created.metadata["why_it_matters"] =~ "partner meeting"
    assert created.metadata["direct_ask"] == true
    assert get_in(created.metadata, ["surface_quality", "surfaceable"]) == true
  end

  test "prompt frames generated copy as work items while preserving internal todo contracts" do
    user_id = unique_user_email("todo-intelligence-copy")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    candidates = [
      %{
        "source" => "gmail",
        "title" => "Jordan follow-up",
        "summary" => "Jordan asked for the latest launch timing.",
        "next_action" => "Reply to Jordan with the launch timing.",
        "dedupe_key" => "gmail:jordan-launch"
      }
    ]

    llm_complete = fn prompt ->
      assert prompt =~ "Maraithon's built-in work-item intelligence layer"
      assert prompt =~ "`candidate_todos`,"
      assert prompt =~ "existing_todo_id"
      assert prompt =~ "the `todo` response object are internal JSON contract names"
      assert prompt =~ "Include People enrichment whenever source evidence identifies people"
      assert prompt =~ "put `crm_people` in todo.metadata"
      assert prompt =~ "Work item title, summary, next_action, notes, and action_plan"
      assert prompt =~ "Use product language for user-facing fields"
      assert prompt =~ "do not write `todo` or `CRM`"
      assert prompt =~ "Family relationship policy is an admission rule"
      assert prompt =~ "distinguish actual work from"
      assert prompt =~ "informational or educational content"
      assert prompt =~ "podcasts, videos, market commentary, and learning material"
      assert prompt =~ "direct ask, operator promise, deadline/deliverable"
      assert prompt =~ "kid/screen-time"
      assert prompt =~ "notifications"
      assert prompt =~ "don't forget your painting"

      refute prompt =~ "Maraithon's built-in todo intelligence layer"
      refute prompt =~ "Include CRM enrichment whenever source evidence identifies people"
      refute prompt =~ "Every person-linked todo needs enough context"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Skipped one non-actionable candidate.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "skip",
                 "reasoning" => "No durable work is needed."
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             Todos.ingest_many(user_id, candidates,
               llm_complete: llm_complete,
               source: "test"
             )

    assert result.todos == []
    assert result.skipped_count == 1
  end

  test "ingest_many does not fall back when the model response is invalid" do
    user_id = unique_user_email("todo-intelligence-invalid")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    llm_complete = fn _prompt -> {:ok, %{content: "not json"}} end

    assert {:error, :todo_intelligence_invalid_json} =
             Todos.ingest_many(
               user_id,
               [
                 %{
                   "source" => "slack",
                   "title" => "Review launch note",
                   "summary" => "The GTM channel asked for a launch-note review.",
                   "next_action" => "Review the launch note.",
                   "dedupe_key" => "slack:invalid-response"
                 }
               ],
               llm_complete: llm_complete
             )

    assert [] = Todos.list_for_user(user_id, limit: 10)
  end

  test "ingest_many exposes negative todo relevance memories to model decisions" do
    user_id = unique_user_email("todo-intelligence-memory")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, memory} =
             Memory.write(user_id, %{
               "kind" => "relevance_feedback",
               "title" => "See less: routine newsletters",
               "content" =>
                 "Routine newsletters without a direct ask should be skipped instead of creating todos.",
               "summary" => "Skip routine newsletters when there is no direct ask.",
               "source" => "todo_see_less",
               "source_ref_type" => "todo",
               "source_ref_id" => Ecto.UUID.generate(),
               "author_type" => "user",
               "tags" => ["todo_relevance", "see_less"],
               "polarity" => "negative",
               "importance" => 85,
               "confidence" => 0.9,
               "dedupe_key" => "todo-intelligence-memory:newsletter"
             })

    candidates = [
      %{
        "source" => "gmail",
        "title" => "Vendor newsletter",
        "summary" => "A routine vendor update with no direct ask.",
        "next_action" => "No action needed.",
        "dedupe_key" => "gmail:vendor-newsletter"
      }
    ]

    llm_complete = fn prompt ->
      assert prompt =~ Todos.Intelligence.sentinel()
      assert prompt =~ "TODO_RELEVANCE_MEMORIES_JSON"
      assert prompt =~ memory.id
      assert prompt =~ "routine newsletters"
      assert prompt =~ "Do not rely on exact keywords"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Skipped one candidate using negative todo relevance memory.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "skip",
                 "reasoning" =>
                   "Matches negative todo relevance memory #{memory.id}: routine newsletter with no direct ask."
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             Todos.ingest_many(user_id, candidates,
               llm_complete: llm_complete,
               source: "test"
             )

    assert result.todos == []
    assert result.skipped_count == 1
    assert hd(result.skipped).reasoning =~ memory.id
  end

  test "ingest_many blocks generic family check-ins when policy is logistics-only" do
    user_id = unique_user_email("todo-intelligence-family-block")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    candidates = [
      %{
        "source" => "proactive",
        "title" => "Check in with Jack Fenwick",
        "summary" => "No recent contact with Jack Fenwick.",
        "next_action" => "Reach out to Jack.",
        "dedupe_key" => "family:jack-check-in",
        "metadata" => %{
          "relationship_domain" => "family",
          "family_member" => true,
          "family_role" => "child",
          "todo_policy" => "family_logistics_only",
          "sensitivity" => "child_family"
        }
      }
    ]

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Created one family check-in.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "create",
                 "dedupe_key" => "family:jack-check-in",
                 "reasoning" => "Model thought a check-in was useful.",
                 "todo" => hd(candidates)
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             Todos.ingest_many(user_id, candidates,
               llm_complete: llm_complete,
               source: "test"
             )

    assert result.todos == []
    assert result.skipped_count == 1
    assert [%{action: "skip", candidate_index: 0, reasoning: reasoning}] = result.skipped
    assert reasoning =~ "family logistics-only policy"
    assert [] = Todos.list_for_user(user_id, limit: 10)
  end

  test "ingest_many allows source-backed family logistics with logistics-only policy" do
    user_id = unique_user_email("todo-intelligence-family-logistics")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    candidates = [
      %{
        "source" => "gmail",
        "kind" => "gmail_triage",
        "title" => "Return Emma permission form",
        "summary" => "A school email says Emma's permission form is due Friday.",
        "next_action" => "Send the signed permission form back to school.",
        "dedupe_key" => "gmail:thread:emma-permission",
        "metadata" => %{
          "relationship_domain" => "family",
          "family_member" => true,
          "family_role" => "child",
          "todo_policy" => "family_logistics_only",
          "sensitivity" => "child_family"
        }
      }
    ]

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Created one parent logistics work item.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "create",
                 "dedupe_key" => "gmail:thread:emma-permission",
                 "reasoning" => "Permission form is source-backed family logistics.",
                 "todo" => hd(candidates)
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             Todos.ingest_many(user_id, candidates,
               llm_complete: llm_complete,
               source: "test"
             )

    assert [%{title: "Return Emma permission form"}] = result.todos
    assert result.skipped_count == 0
    assert [%{title: "Return Emma permission form"}] = Todos.list_for_user(user_id, limit: 10)
  end

  test "ingest_many allows explicitly opted-in family relationship rhythms" do
    user_id = unique_user_email("todo-intelligence-family-opt-in")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    candidates = [
      %{
        "source" => "telegram",
        "title" => "Plan Sunday one-on-one time with Jack Fenwick",
        "summary" => "You asked to be reminded to plan one-on-one time with Jack on Sunday.",
        "next_action" => "Choose a Sunday plan and block time for it.",
        "dedupe_key" => "family:jack-sunday-rhythm",
        "metadata" => %{
          "relationship_domain" => "family",
          "family_member" => true,
          "family_role" => "child",
          "todo_policy" => "opt_in_rhythm",
          "user_requested" => true,
          "sensitivity" => "child_family"
        }
      }
    ]

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Created one opted-in family rhythm.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "create",
                 "dedupe_key" => "family:jack-sunday-rhythm",
                 "reasoning" => "The user explicitly opted into this rhythm.",
                 "todo" => hd(candidates)
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             Todos.ingest_many(user_id, candidates,
               llm_complete: llm_complete,
               source: "test"
             )

    assert [%{title: "Plan Sunday one-on-one time with Jack Fenwick"}] = result.todos
    assert result.skipped_count == 0

    assert [%{title: "Plan Sunday one-on-one time with Jack Fenwick"}] =
             Todos.list_for_user(user_id, limit: 10)
  end

  test "ingest_many preserves commitment tracker snooze timing through model rewrite" do
    user_id = unique_user_email("todo-intelligence-snoozed-commitment")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    snoozed_until_dt = ~U[2099-06-19 20:00:00Z]
    snoozed_until = DateTime.to_iso8601(snoozed_until_dt)

    candidates = [
      %{
        "source" => "slack",
        "title" => "Message Sheila tomorrow",
        "summary" => "You said you would message Sheila tomorrow.",
        "next_action" => "Message Sheila tomorrow, then mark this done.",
        "due_at" => snoozed_until,
        "status" => "snoozed",
        "snoozed_until" => snoozed_until,
        "source_item_id" => "C-gtm:4085500260.000100",
        "source_occurred_at" => "2099-06-18T21:11:00Z",
        "dedupe_key" => "commitment:slack:C-gtm:4085500260.000100:message-sheila",
        "metadata" => %{
          "origin_skill_id" => "commitment_tracker",
          "completion_check" => %{
            "status" => "open",
            "reasoning" => "No later Slack evidence shows the message was sent."
          },
          "explicit_user_commitment" => true,
          "commitment_direction" => "i_owe",
          "quote" => "I am going to message Sheila tomorrow",
          "source_ref" => "slack C-gtm:4085500260.000100",
          "why_it_matters" => "GTM coordination."
        }
      }
    ]

    llm_complete = fn prompt ->
      assert prompt =~ "Do not use exact-string matching"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Created one Slack commitment.",
             "decisions" => [
               %{
                 "candidate_index" => 0,
                 "action" => "create",
                 "dedupe_key" => "commitment:slack:C-gtm:4085500260.000100:message-sheila",
                 "reasoning" => "Source-backed commitment to message Sheila tomorrow.",
                 "todo" => %{
                   "source" => "slack",
                   "title" => "Message Sheila tomorrow",
                   "summary" => "You said you would message Sheila tomorrow.",
                   "next_action" => "Message Sheila tomorrow, then mark this done.",
                   "status" => "open",
                   "dedupe_key" => "commitment:slack:C-gtm:4085500260.000100:message-sheila",
                   "metadata" => %{
                     "completion_check" => %{"status" => "open"}
                   }
                 }
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             Todos.ingest_many(user_id, candidates,
               llm_complete: llm_complete,
               source: "test"
             )

    assert [%{title: "Message Sheila tomorrow"} = todo] = result.todos
    assert todo.status == "snoozed"
    assert DateTime.compare(todo.snoozed_until, snoozed_until_dt) == :eq
    assert DateTime.compare(todo.due_at, snoozed_until_dt) == :eq
    assert todo.metadata["explicit_user_commitment"] == true
    assert todo.metadata["commitment_direction"] == "i_owe"
    assert todo.metadata["quote"] == "I am going to message Sheila tomorrow"
    assert get_in(todo.metadata, ["completion_check", "status"]) == "open"
  end

  defp unique_user_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.com"
  end
end
