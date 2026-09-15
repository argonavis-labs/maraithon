defmodule Maraithon.Delegations.EvalBudgetTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.Delegations.{Budget, Delegation, EvaluationRunner}
  alias Maraithon.LLM.CostMonitor
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobs}

  setup do
    values =
      [
        delegations_enabled: true,
        delegation_eval_only: true,
        delegation_user_allowlist: ["kent@runner.now"],
        delegation_sends_enabled: %{gmail: true}
      ] ++ [{CostMonitor, [enabled: true, projected_daily_usd: 3.0]}]

    for {key, value} <- values do
      previous = Application.fetch_env(:maraithon, key)
      Application.put_env(:maraithon, key, value)

      on_exit(fn ->
        case previous do
          {:ok, original} -> Application.put_env(:maraithon, key, original)
          :error -> Application.delete_env(:maraithon, key)
        end
      end)
    end

    :ok
  end

  test "missing cost evidence rejects the eval before account reads or fixture creation" do
    assert {:error, :account_cost_hold} =
             EvaluationRunner.start("information_reply", "as_assistant")

    refute Repo.exists?(from j in BackgroundJob, where: j.job_type == "delegation_eval")
    refute Repo.exists?(Maraithon.TelegramAssistant.PreparedAction)
  end

  test "an alert blocks spending even when today's usage is below the threshold" do
    monitor("alert_sent", 6.024170666)
    refute Budget.account_budget_ok?(DateTime.utc_now())

    assert {:error, :account_cost_hold} =
             EvaluationRunner.start("information_reply", "as_assistant")

    refute Repo.exists?(from j in BackgroundJob, where: j.job_type == "delegation_eval")

    summary =
      Maraithon.Delegations.summary(%Delegation{
        user_id: "kent@runner.now",
        state: "waiting_capacity",
        provider: "gmail",
        data: %{"hold_reason" => "account_cost_hold"}
      })

    assert summary["status_line"] == "LLM spending is on hold"
  end

  test "a fresh verified observation below the threshold permits the budget preflight" do
    monitor("within_budget", 5.0)
    assert Budget.account_budget_ok?(DateTime.utc_now())
  end

  defp monitor(status, rolling) do
    assert {:ok, _} =
             BackgroundJobs.enqueue("runtime_recurring:llm_cost_monitor", %{
               result: %{
                 "status" => status,
                 "checked_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "daily_cost_usd" => 4.42,
                 "rolling_cost_usd" => rolling,
                 "threshold_usd" => 6,
                 "key_fingerprint" =>
                   :crypto.hash(:sha256, Maraithon.LLM.openrouter_api_key() || "")
                   |> Base.encode16(case: :lower)
               }
             })
  end
end
