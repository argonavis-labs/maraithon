defmodule Maraithon.ActionLedgerTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.ActionLedger
  alias Maraithon.ActionLedger.Action
  alias Maraithon.Repo

  test "records, lists, and explains safe action summaries" do
    user_id = "ledger-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, action} =
             ActionLedger.record(%{
               user_id: user_id,
               surface: "telegram",
               event_type: "tool.executed",
               status: "completed",
               policy_decision: %{
                 status: "allow",
                 reason_code: "policy_allowed",
                 message: "Tool call allowed."
               },
               result_object_refs: %{"todo_id" => "todo_123"},
               metadata: %{tool_name: "upsert_todos", argument_keys: ["todos", "user_id"]}
             })

    assert [%{id: id}] = ActionLedger.list_recent(user_id, limit: 5)
    assert id == action.id

    assert {:ok, explanation} = ActionLedger.explain(user_id, action.id)
    assert explanation.status == "completed"
    assert explanation.reason_code == "policy_allowed"
    assert explanation.result_object_refs == %{"todo_id" => "todo_123"}
  end

  test "rejects invalid event types" do
    assert {:error, changeset} =
             ActionLedger.record(%{
               user_id: "ledger-invalid@example.com",
               surface: "telegram",
               event_type: "invalid.raw_dump",
               status: "completed"
             })

    assert %{event_type: [_message]} = errors_on(changeset)
  end

  test "redacts sensitive values before storage and explanation" do
    user_id = "ledger-redaction-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, action} =
             ActionLedger.record(%{
               user_id: user_id,
               surface: "telegram",
               event_type: "tool.executed",
               status: "completed",
               source_evidence: %{
                 "authorization" => "Bearer sk-abc12345678901234567890",
                 "thread_id" => "thread-123"
               },
               metadata: %{"access_token" => "xoxb-1234567890-secret", "tool_name" => "time"},
               model_summary: "Used Bearer sk-abc12345678901234567890"
             })

    persisted = Repo.get!(Action, action.id)
    assert persisted.source_evidence["authorization"] == "<redacted>"
    assert persisted.metadata["access_token"] == "<redacted>"
    assert persisted.model_summary =~ "<redacted-auth>"

    assert {:ok, explanation} = ActionLedger.explain(user_id, action.id)
    assert explanation.source_evidence["thread_id"] == "thread-123"
    assert explanation.source_evidence["authorization"] == "<redacted>"
  end

  test "purges entries older than the retention window" do
    user_id = "ledger-retention-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, old_action} =
             ActionLedger.record(%{
               user_id: user_id,
               surface: "telegram",
               event_type: "tool.executed",
               status: "completed"
             })

    assert {:ok, fresh_action} =
             ActionLedger.record(%{
               user_id: user_id,
               surface: "telegram",
               event_type: "tool.executed",
               status: "completed"
             })

    old = DateTime.utc_now() |> DateTime.add(-3 * 24 * 60 * 60, :second)

    {1, _rows} =
      Action
      |> Ecto.Query.where([entry], entry.id == ^old_action.id)
      |> Repo.update_all(set: [inserted_at: old, updated_at: old])

    assert {:ok, deleted_count} = ActionLedger.purge_expired(retention_days: 1)
    assert deleted_count >= 1
    refute Repo.get(Action, old_action.id)
    assert Repo.get(Action, fresh_action.id)
  end
end
