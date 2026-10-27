defmodule Maraithon.TrustMetricsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.ConnectedAccounts
  alias Maraithon.TrustMetrics

  test "builds a baseline from ledger and source freshness data" do
    user_id = "trust-metrics-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "12345"})

    {:ok, _} =
      ActionLedger.record(%{
        user_id: user_id,
        surface: "mcp",
        event_type: "tool.executed",
        status: "completed",
        policy_decision: %{"status" => "allow", "reason_code" => "policy_allowed"}
      })

    {:ok, _} =
      ActionLedger.record(%{
        user_id: user_id,
        surface: "mcp",
        event_type: "tool.needs_confirmation",
        status: "needs_confirmation",
        policy_decision: %{"status" => "needs_confirmation"}
      })

    {:ok, _} =
      ActionLedger.record(%{
        user_id: user_id,
        surface: "mcp",
        event_type: "tool.denied",
        status: "denied",
        policy_decision: %{"status" => "deny"}
      })

    {:ok, _} =
      ActionLedger.record(%{
        user_id: user_id,
        surface: "telegram",
        event_type: "proactive.sent",
        status: "sent"
      })

    {:ok, _} =
      ActionLedger.record(%{
        user_id: user_id,
        surface: "telegram",
        event_type: "proactive.held",
        status: "held"
      })

    baseline = TrustMetrics.baseline(user_id: user_id)
    metrics = baseline.metrics

    assert baseline.definitions["material_side_effects_with_ledger_entry"]

    assert baseline.definitions["confirmation_required_actions"] ==
             "Actions that required confirmation."

    assert baseline.definitions["denied_tool_calls"] == "Actions blocked by safety rules."
    refute Jason.encode!(baseline.definitions) =~ "Tool calls"
    assert metrics.side_effecting_tool_calls_with_policy_decision == 3
    assert metrics.material_side_effects_with_ledger_entry == 1
    assert metrics.confirmation_required_actions == 1
    assert metrics.denied_tool_calls == 1
    assert metrics.proactive_sends == 1
    assert metrics.proactive_holds == 1
    assert metrics.connector_freshness_by_status["fresh"] == 1
  end
end
