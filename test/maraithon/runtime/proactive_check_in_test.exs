defmodule Maraithon.Runtime.ProactiveCheckInTest do
  use Maraithon.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.Runtime.ProactiveCheckIn
  alias Maraithon.TelegramAssistant.ProactiveCandidate
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.TestSupport.CapturingAPNS

  setup do
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
    end)

    %{original_assistant: original_assistant, original_runtime: original_runtime}
  end

  test "initial tick delay defaults to the configured interval", %{
    original_runtime: original_runtime
  } do
    runtime_config =
      original_runtime
      |> Keyword.put(:proactive_check_in_interval_ms, 123_456)
      |> Keyword.delete(:proactive_check_in_initial_delay_ms)

    Application.put_env(:maraithon, Maraithon.Runtime, runtime_config)

    pid = start_supervised!(ProactiveCheckIn)
    state = :sys.get_state(pid)

    assert state.interval_ms == 123_456
    assert state.initial_delay_ms == 123_456
  end

  test "initial tick delay can be configured separately", %{
    original_runtime: original_runtime
  } do
    runtime_config =
      original_runtime
      |> Keyword.put(:proactive_check_in_interval_ms, 123_456)
      |> Keyword.put(:proactive_check_in_initial_delay_ms, 5_000)

    Application.put_env(:maraithon, Maraithon.Runtime, runtime_config)

    pid = start_supervised!(ProactiveCheckIn)
    state = :sys.get_state(pid)

    assert state.interval_ms == 123_456
    assert state.initial_delay_ms == 5_000
  end

  test "run_delivery_planner is disabled until the planner flag is enabled", %{
    original_assistant: original_assistant
  } do
    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant, proactive_delivery_planner_enabled: false)
    )

    assert ProactiveCheckIn.run_delivery_planner() == :disabled
  end

  test "run_delivery_planner logs per-user model failures", %{
    original_assistant: original_assistant
  } do
    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_unified_push_enabled: true,
        proactive_delivery_planner_enabled: true
      )
    )

    user_id = "runtime-planner-failure-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    :ok = CapturingAPNS.enable(user_id)

    {:ok, _candidate} =
      ProactiveQueue.enqueue(candidate_attrs(user_id, %{urgency: 0.95}))

    log =
      capture_log([level: :warning], fn ->
        result =
          ProactiveCheckIn.run_delivery_planner(
            user_ids: [user_id],
            context: %{},
            llm_complete: fn _params -> {:error, :provider_unavailable} end,
            model_fallbacks: []
          )

        assert result.failed == 1
      end)

    assert log =~ "Proactive delivery planning failed"
  end

  test "run_once expires stale queue rows even while planning is disabled", %{
    original_assistant: original_assistant
  } do
    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant, proactive_delivery_planner_enabled: false)
    )

    user_id = "runtime-expiry-disabled-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, candidate} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{
                 expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
               })
             )

    cycle = ProactiveCheckIn.run_once()

    assert cycle.planner == :disabled
    assert cycle.expired == 1
    assert Repo.get!(ProactiveCandidate, candidate.id).status == "expired"
  end

  test "run_once delegates only queued candidates to the planner", %{
    original_assistant: original_assistant
  } do
    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_unified_push_enabled: true,
        proactive_delivery_planner_enabled: true
      )
    )

    user_id = "runtime-planner-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    CapturingAPNS.enable(user_id)

    local_hour = Maraithon.TelegramAssistant.PushBroker.local_now_for_user(user_id).hour

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(Application.get_env(:maraithon, :telegram_assistant, []),
        quiet_hours_start_local: rem(local_hour + 2, 24),
        quiet_hours_end_local: rem(local_hour + 3, 24)
      )
    )

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "runtime-planner"}
      })

    {:ok, candidate} = ProactiveQueue.enqueue(candidate_attrs(user_id))

    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "dispositions" => [
               %{
                 "candidate_id" => candidate.id,
                 "disposition" => "hold",
                 "reason" => "Quiet until there is more evidence."
               }
             ],
             "summary" => "Hold the runtime candidate."
           })
       }}
    end

    cycle =
      ProactiveCheckIn.run_once(
        user_ids: [user_id],
        context: %{},
        llm_complete: llm_complete
      )

    assert cycle.expired == 0
    assert cycle.sent == 0
    assert cycle.held == 1
    assert cycle.suppressed == 0
    assert cycle.failed == 0
    assert cycle.disabled == 0

    result = cycle.planner
    assert result.failure_codes == %{}
    assert result.planned == 1
    assert result.held == 1

    held = Repo.get!(ProactiveCandidate, candidate.id)
    assert held.status == "held"
    assert held.disposition == "hold"
    assert held.plan_reason == "model_hold"
  end

  test "expire_stale_candidates delegates stale candidate cleanup" do
    user_id = "runtime-planner-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_time = DateTime.add(now, -60, :second)
    fresh_time = DateTime.add(now, 60, :second)

    {:ok, pending} = ProactiveQueue.enqueue(candidate_attrs(user_id, %{expires_at: stale_time}))

    {:ok, planned} =
      user_id
      |> candidate_attrs(%{expires_at: stale_time})
      |> ProactiveQueue.enqueue()
      |> elem(1)
      |> ProactiveQueue.mark_planned("digest", "Stale planned row.")

    {:ok, fresh} = ProactiveQueue.enqueue(candidate_attrs(user_id, %{expires_at: fresh_time}))

    assert ProactiveCheckIn.expire_stale_candidates(now) == 2
    assert Repo.get!(ProactiveCandidate, pending.id).status == "expired"
    assert Repo.get!(ProactiveCandidate, planned.id).status == "expired"
    assert Repo.get!(ProactiveCandidate, fresh.id).status == "pending"
  end

  defp candidate_attrs(user_id, overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        user_id: user_id,
        source: "insight",
        source_id: "runtime-source-#{unique}",
        dedupe_key: "runtime-planner:#{unique}",
        title: "Runtime planner candidate",
        body: "The runtime planner should decide what to do with this candidate.",
        urgency: 0.7,
        why_now: "The candidate is pending during the runtime cycle.",
        structured_data: %{"source" => "runtime_test"},
        telegram_opts: %{"parse_mode" => "HTML"}
      },
      overrides
    )
  end
end
