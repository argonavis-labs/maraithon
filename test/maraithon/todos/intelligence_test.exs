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

  defp unique_user_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.com"
  end
end
