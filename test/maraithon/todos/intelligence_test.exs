defmodule Maraithon.Todos.IntelligenceTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
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

  defp unique_user_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.com"
  end
end
