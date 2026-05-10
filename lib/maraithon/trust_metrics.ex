defmodule Maraithon.TrustMetrics do
  @moduledoc """
  Baseline trust metrics derived from first-party audit records.
  """

  import Ecto.Query

  alias Maraithon.ActionLedger.Action
  alias Maraithon.Repo
  alias Maraithon.SourceFreshness
  alias Maraithon.TelegramAssistant.PushReceipt

  @metric_definitions %{
    "side_effecting_tool_calls_with_policy_decision" =>
      "Material tool ledger entries that include a policy decision.",
    "material_side_effects_with_ledger_entry" =>
      "Completed material side effects recorded in the action ledger.",
    "proactive_sends" => "Proactive assistant pushes sent now.",
    "proactive_holds" => "Proactive assistant decisions held or suppressed.",
    "confirmation_required_actions" => "Tool calls that required confirmation.",
    "denied_tool_calls" => "Tool calls denied by ToolPolicy.",
    "failed_tool_calls" => "Tool ledger entries with failed status.",
    "connector_freshness_by_status" => "Connected source count grouped by freshness status."
  }

  def definitions, do: @metric_definitions

  def baseline(opts \\ []) when is_list(opts) do
    user_id = Keyword.get(opts, :user_id)
    ledger_query = maybe_filter_user(Action, user_id)

    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      scope: if(user_id, do: %{"user_id" => user_id}, else: %{"user_id" => "all"}),
      definitions: @metric_definitions,
      metrics: %{
        side_effecting_tool_calls_with_policy_decision: count_policy_decisions(ledger_query),
        material_side_effects_with_ledger_entry: count_event_type(ledger_query, "tool.executed"),
        proactive_sends: count_event_type(ledger_query, "proactive.sent"),
        proactive_holds: count_event_type(ledger_query, "proactive.held"),
        confirmation_required_actions: count_event_type(ledger_query, "tool.needs_confirmation"),
        denied_tool_calls: count_event_type(ledger_query, "tool.denied"),
        failed_tool_calls: count_status(ledger_query, "failed"),
        proactive_push_receipts: push_receipt_counts(user_id),
        connector_freshness_by_status: connector_freshness_counts(user_id)
      }
    }
  end

  defp count_policy_decisions(query) do
    query
    |> where(
      [action],
      action.event_type in ["tool.executed", "tool.denied", "tool.needs_confirmation"]
    )
    |> where([action], fragment("jsonb_typeof(?) = 'object'", action.policy_decision))
    |> Repo.aggregate(:count)
  end

  defp count_event_type(query, event_type) do
    query
    |> where([action], action.event_type == ^event_type)
    |> Repo.aggregate(:count)
  end

  defp count_status(query, status) do
    query
    |> where([action], action.status == ^status)
    |> Repo.aggregate(:count)
  end

  defp push_receipt_counts(user_id) do
    PushReceipt
    |> maybe_filter_user(user_id)
    |> group_by([receipt], receipt.decision)
    |> select([receipt], {receipt.decision, count(receipt.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp connector_freshness_counts(nil) do
    Maraithon.Accounts.User
    |> select([user], user.id)
    |> Repo.all()
    |> Enum.flat_map(&SourceFreshness.for_user/1)
    |> group_statuses()
  end

  defp connector_freshness_counts(user_id),
    do: user_id |> SourceFreshness.for_user() |> group_statuses()

  defp group_statuses(snapshots) do
    snapshots
    |> Enum.frequencies_by(& &1.status)
    |> Map.new(fn {status, count} -> {to_string(status), count} end)
  end

  defp maybe_filter_user(query, nil), do: query

  defp maybe_filter_user(query, user_id) when is_binary(user_id) do
    where(query, [row], row.user_id == ^user_id)
  end
end
