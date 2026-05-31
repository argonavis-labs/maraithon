defmodule Maraithon.Runtime.DogfoodDigestTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Runtime.DogfoodDigest
  alias Maraithon.Runtime.IncidentLog
  alias Maraithon.TestSupport.CapturingTelegram

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    :ok
  end

  test "composes a trailing 24h runtime stability digest" do
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "ai_chief_of_staff",
        status: "running",
        config: %{}
      })

    {:ok, unrecovered_agent} =
      Agents.create_agent(%{
        behavior: "ai_chief_of_staff",
        status: "running",
        config: %{}
      })

    assert {:ok, _} =
             IncidentLog.record(%{
               kind: :node_boot,
               occurred_at: ~U[2026-05-20 08:00:00Z],
               metadata: %{
                 "baseline" => %{
                   "pending_effects" => 1,
                   "failed_effects" => 0,
                   "pending_scheduled_jobs" => 2,
                   "running_agent_runs" => 1
                 }
               }
             })

    assert {:ok, _} =
             IncidentLog.record(%{
               kind: :agent_crash,
               agent_id: agent.id,
               reason: "killed",
               occurred_at: ~U[2026-05-20 09:00:00Z],
               metadata: %{"behavior" => "ai_chief_of_staff"}
             })

    assert {:ok, _} =
             IncidentLog.record(%{
               kind: :agent_resumed,
               agent_id: agent.id,
               occurred_at: ~U[2026-05-20 09:01:00Z],
               metadata: %{"resume_trigger" => "targeted_reresume"}
             })

    assert {:ok, _} =
             IncidentLog.record(%{
               kind: :agent_crash,
               agent_id: unrecovered_agent.id,
               reason: "crash_loop_threshold",
               occurred_at: ~U[2026-05-20 09:10:00Z],
               metadata: %{"behavior" => "ai_chief_of_staff"}
             })

    assert {:ok, _} =
             IncidentLog.record(%{
               kind: :agent_stopped_unexpectedly,
               agent_id: unrecovered_agent.id,
               reason: "crash_loop_threshold",
               occurred_at: ~U[2026-05-20 09:11:00Z]
             })

    body =
      DogfoodDigest.compose(~U[2026-05-20 10:00:00Z],
        timezone: "America/Toronto"
      )

    assert body =~ "Chief of Staff daily check"
    assert body =~ "Runtime:"

    assert body =~
             "Incidents: 1 restart, 2 agent crashes, 1 agent recovery, 1 agent stopped after retries"

    assert body =~ "Agent crashes:"

    assert body =~
             "Chief of Staff agent stopped unexpectedly; process was killed; recovered by the monitor."

    assert body =~
             "Chief of Staff agent stopped unexpectedly; repeated crashes crossed the recovery limit; not recovered after repeated crashes."

    refute body =~ agent.id
    refute body =~ unrecovered_agent.id
    refute body =~ "agent_crash=2"
    refute body =~ "crash_loop_threshold"
    refute body =~ "DB "
    refute body =~ "0 failed delivery jobs"
    assert body =~ "At last boot:"
    assert body =~ "1 pending delivery job"
    assert body =~ "2 scheduled follow-ups"
    assert body =~ "memory "
    assert body =~ " MB"
  end

  test "delivers the digest to the configured user's Telegram destination" do
    user_id = "dogfood-digest-#{System.unique_integer([:positive])}@example.com"

    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "12345"})

    assert {:ok, :sent} =
             DogfoodDigest.deliver(~U[2026-05-20 10:00:00Z],
               user_id: user_id,
               telegram_module: CapturingTelegram
             )

    [message] = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)
    assert message.chat_id == "12345"
    assert message.text =~ "Chief of Staff daily check"
  end

  test "schedules the next local digest time using the configured offset" do
    assert DogfoodDigest.next_fire_after(~U[2026-05-20 10:00:00Z], 7, 30, -4) ==
             ~U[2026-05-20 11:30:00Z]

    assert DogfoodDigest.next_fire_after(~U[2026-05-20 12:00:00Z], 7, 30, -4) ==
             ~U[2026-05-21 11:30:00Z]
  end
end
