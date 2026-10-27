defmodule Maraithon.ActionLedgerTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.ActionLedger.Action
  alias Maraithon.Agents
  alias Maraithon.Crm
  alias Maraithon.Crm.Person
  alias Maraithon.Memory
  alias Maraithon.Memory.Item, as: MemoryItem
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.PushReceipt
  alias Maraithon.Timezones
  alias Maraithon.Todos
  alias Maraithon.Todos.ActivityEvent

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
                 message: "Action allowed."
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

  describe "activity_summary/2 (SPEC 09 R1)" do
    test "aggregates today's todos, memories, people, pings, and holds, and respects the period" do
      user_id = unique_user_email("activity-summary")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, [_todo]} =
        Todos.upsert_many(user_id, [
          %{
            "source" => "manual",
            "kind" => "general",
            "title" => "Follow up with Dana",
            "dedupe_key" => "activity-summary-todo"
          }
        ])

      {:ok, _memory} =
        Memory.write(user_id, %{
          "content" => "Prefers async updates over calls.",
          "kind" => "preference"
        })

      {:ok, _person} = Crm.create_person(user_id, %{"display_name" => "Dana Lee"})

      dedupe_key = "activity-summary-ping"

      {:ok, _sent_action} =
        ActionLedger.record(%{
          user_id: user_id,
          surface: "telegram",
          event_type: "proactive.sent",
          status: "sent",
          source_evidence: %{"dedupe_key" => dedupe_key},
          model_summary: "Dana asked about pricing and nothing has moved since.",
          result_object_refs: %{"dedupe_key" => dedupe_key}
        })

      {:ok, _receipt} =
        TelegramAssistant.record_push_receipt(%{
          user_id: user_id,
          dedupe_key: dedupe_key,
          origin_type: "insight",
          decision: "sent_now"
        })

      {:ok, _held_action} =
        ActionLedger.record(%{
          user_id: user_id,
          surface: "telegram",
          event_type: "proactive.held",
          status: "held",
          model_summary: "Held a low-urgency nudge during quiet hours.",
          metadata: %{"hold_reason" => "quiet_hours"}
        })

      summary = ActionLedger.activity_summary(user_id, :today)

      assert summary.todos.created.count == 1
      assert [%{title: "Follow up with Dana"}] = summary.todos.created.items

      assert summary.memories.count == 1
      assert summary.memories.by_kind["preference"] == 1

      assert summary.people.created.count == 1
      assert [%{display_name: "Dana Lee"}] = summary.people.created.items

      assert summary.pings.count == 1
      assert [%{why_now: why_now, decision: "sent_now"}] = summary.pings.items
      assert why_now =~ "Dana asked about pricing"

      assert summary.holds.count == 1
      assert [%{reason: "quiet_hours"}] = summary.holds.items

      # Backdate everything well outside today/yesterday for any timezone
      # offset and confirm the period filter actually excludes them, while a
      # wide explicit date range still finds them.
      far_past = DateTime.utc_now() |> DateTime.add(-5 * 24 * 60 * 60, :second)

      Repo.update_all(from(e in ActivityEvent, where: e.user_id == ^user_id),
        set: [occurred_at: far_past]
      )

      Repo.update_all(from(m in MemoryItem, where: m.user_id == ^user_id),
        set: [inserted_at: far_past]
      )

      Repo.update_all(from(p in Person, where: p.user_id == ^user_id),
        set: [inserted_at: far_past]
      )

      Repo.update_all(from(a in Action, where: a.user_id == ^user_id),
        set: [inserted_at: far_past]
      )

      Repo.update_all(from(r in PushReceipt, where: r.user_id == ^user_id),
        set: [inserted_at: far_past]
      )

      empty_summary = ActionLedger.activity_summary(user_id, :today)
      assert empty_summary.todos.created.count == 0
      assert empty_summary.memories.count == 0
      assert empty_summary.people.created.count == 0
      assert empty_summary.pings.count == 0
      assert empty_summary.holds.count == 0

      range_summary =
        ActionLedger.activity_summary(user_id, {Date.add(Date.utc_today(), -6), Date.utc_today()})

      assert range_summary.todos.created.count == 1
      assert range_summary.memories.count == 1
      assert range_summary.people.created.count == 1
      assert range_summary.pings.count == 1
      assert range_summary.holds.count == 1
    end

    test "returns an empty structure for an invalid user" do
      assert ActionLedger.activity_summary(nil, :today).todos.created.count == 0
    end

    test "resolves each day's own DST offset instead of reusing now's offset" do
      user_id = unique_user_email("activity-summary-dst")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _agent} =
        Agents.create_agent(%{
          user_id: user_id,
          behavior: "founder_followthrough_agent",
          config: %{"timezone" => "America/New_York", "timezone_offset_hours" => -5}
        })

      # America/New_York DST in 2026: begins 2026-03-08, ends 2026-11-01.
      # `from_date` sits before the transition (standard time, UTC-5) and
      # `to_date` sits after it (daylight time, UTC-4). A single reused
      # offset (the bug) would misplace one edge of this range by an hour;
      # resolving each boundary against its own local midnight must not.
      from_date = ~D[2026-03-01]
      to_date = ~D[2026-03-15]

      summary = ActionLedger.activity_summary(user_id, {from_date, to_date})

      expected_since =
        DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC") |> DateTime.add(5, :hour)

      expected_until =
        DateTime.new!(Date.add(to_date, 1), ~T[00:00:00], "Etc/UTC") |> DateTime.add(4, :hour)

      assert DateTime.compare(summary.period.since, expected_since) == :eq
      assert DateTime.compare(summary.period.until, expected_until) == :eq
    end
  end

  describe "recent_pings/2 (SPEC 09 R2)" do
    test "resolves the most recent sent_now/merged pushes with why_now, optionally by topic" do
      user_id = unique_user_email("recent-pings")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      dedupe_key = "recent-pings-dedupe"

      {:ok, _action} =
        ActionLedger.record(%{
          user_id: user_id,
          surface: "telegram",
          event_type: "proactive.sent",
          status: "sent",
          source_evidence: %{"dedupe_key" => dedupe_key},
          model_summary: "Renewal deadline for Acme is Friday and nobody has replied.",
          result_object_refs: %{"dedupe_key" => dedupe_key}
        })

      {:ok, _receipt} =
        TelegramAssistant.record_push_receipt(%{
          user_id: user_id,
          dedupe_key: dedupe_key,
          origin_type: "insight",
          decision: "sent_now"
        })

      assert [ping] = ActionLedger.recent_pings(user_id, limit: 5)
      assert ping.why_now =~ "Acme"

      assert [_matched] = ActionLedger.recent_pings(user_id, topic: "acme")
      assert ActionLedger.recent_pings(user_id, topic: "some unrelated topic") == []
    end
  end

  defp unique_user_email(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive])}@example.com"
end
