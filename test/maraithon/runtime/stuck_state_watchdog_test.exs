defmodule Maraithon.Runtime.StuckStateWatchdogTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.Insights
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Repo
  alias Maraithon.Runtime.RuntimeIncident
  alias Maraithon.Runtime.StuckStateWatchdog
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.PreparedAction
  alias Maraithon.TelegramAssistant.ProactiveCandidate
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.TestSupport.CapturingEmail

  setup do
    start_supervised!(%{
      id: :capturing_email_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_email_recorder]]}
    })

    # The shared test database can carry committed leftovers in the watched
    # queue tables from prior runs; clear them inside the sandbox (rolled
    # back after each test) so detection assertions are deterministic.
    Repo.delete_all(Maraithon.Briefs.Brief)
    Repo.delete_all(Delivery)
    Repo.delete_all(PreparedAction)
    Repo.delete_all(ProactiveCandidate)
    Repo.delete_all(Maraithon.Effects.Effect)
    Repo.delete_all(Maraithon.Runtime.BackgroundJob)
    Repo.delete_all(Maraithon.Runtime.ScheduledJob)
    Repo.delete_all(RuntimeIncident)

    operator_id = "watchdog-operator-#{System.unique_integer([:positive])}@example.com"
    {:ok, _operator} = Accounts.get_or_create_user_by_email(operator_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: operator_id,
        behavior: "prompt_agent",
        config: %{"name" => "watchdog"}
      })

    %{operator_id: operator_id, agent: agent, opts: [operator_id: operator_id, email_module: CapturingEmail]}
  end

  test "stale detect-only rows alarm exactly once per table per day",
       %{operator_id: operator_id, agent: agent, opts: opts} do
    two_hours_ago = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)

    # Detect-only table #1: a brief stuck pending 2h past scheduled_for
    # (past the 90-minute defensive SLA).
    {:ok, brief} =
      Briefs.record(operator_id, agent.id, %{
        "cadence" => "morning",
        "scheduled_for" => DateTime.to_iso8601(two_hours_ago),
        "dedupe_key" => "watchdog-test-brief",
        "status" => "pending",
        "title" => "Stuck brief",
        "summary" => "Should have gone out hours ago.",
        "body" => "Stuck brief body."
      })

    assert brief.status == "pending"

    # Detect-only table #2: a pending telegram insight delivery older than
    # the 10-minute SLA.
    delivery = stranded_insight_delivery(operator_id, agent.id, minutes_old: 30)
    assert delivery.status == "pending"

    result = StuckStateWatchdog.run_cycle(opts)
    assert result.detected >= 2

    # Second cycle in the same (table, day) window: the
    # OperatorEvents.record_once dedupe must suppress double-recording.
    _ = StuckStateWatchdog.run_cycle(opts)

    for table <- ["briefs", "insight_deliveries"] do
      incidents =
        RuntimeIncident
        |> where([incident], incident.kind == "stuck_state_detected")
        |> where([incident], fragment("?->>'table' = ?", incident.metadata, ^table))
        |> Repo.all()

      assert length(incidents) == 1,
             "expected exactly one stuck_state_detected incident for #{table}, " <>
               "got #{length(incidents)}"

      [incident] = incidents
      assert is_integer(incident.metadata["count"]) and incident.metadata["count"] > 0
      assert is_integer(incident.metadata["oldest_age_seconds"])
      assert incident.metadata["oldest_age_seconds"] > 0
    end

    # The operator alert is one email per table per day, to the operator's
    # email address — never a Telegram push.
    emails = Agent.get(:capturing_email_recorder, &Enum.reverse/1)
    tables_alerted = Enum.map(emails, & &1.content.subject)

    assert Enum.count(tables_alerted, &(&1 =~ "briefs")) == 1
    assert Enum.count(tables_alerted, &(&1 =~ "insight_deliveries")) == 1
    assert Enum.all?(emails, &(&1.to == operator_id))

    # The watchdog is detect-only for these tables: it must not touch the
    # rows themselves.
    assert Repo.get!(Maraithon.Briefs.Brief, brief.id).status == "pending"
    assert Repo.get!(Delivery, delivery.id).status == "pending"
  end

  test "held candidates past the TTL are expired with a self-heal ledger entry",
       %{operator_id: operator_id, opts: opts} do
    {:ok, candidate} =
      ProactiveQueue.enqueue(%{
        user_id: operator_id,
        source: "insight",
        source_id: "watchdog-held-#{System.unique_integer([:positive])}",
        dedupe_key: "watchdog-held-#{System.unique_integer([:positive])}",
        title: "Nudge about Elena",
        body: "A held nudge that nobody ever drained.",
        urgency: 0.2
      })

    {:ok, _held} = ProactiveQueue.mark_held(candidate)

    # Backdate the hold to 8 days ago (past the 7-day held TTL). Age is
    # measured from updated_at, never from expires_at.
    eight_days_ago = DateTime.add(DateTime.utc_now(), -8 * 86_400, :second)

    {1, _} =
      ProactiveCandidate
      |> where([row], row.id == ^candidate.id)
      |> Repo.update_all(set: [updated_at: eight_days_ago])

    result = StuckStateWatchdog.run_cycle(opts)
    assert result.swept >= 1

    assert Repo.get!(ProactiveCandidate, candidate.id).status == "expired"

    # Per-row audit fact.
    [expiry_entry] =
      ActionLedger.list_recent(operator_id, event_type: "held_interruption_expired", limit: 5)

    assert expiry_entry.status == "completed"
    assert expiry_entry.metadata["candidate_id"] == candidate.id

    # Exactly one user-facing self-heal fact, in plain language, for the
    # morning brief's model-gated system_notices to consider.
    [self_heal] =
      ActionLedger.list_recent(operator_id, event_type: "runtime.self_healed", limit: 5)

    assert self_heal.status == "completed"
    assert self_heal.model_summary =~ "Cleared 1 held nudge"
    assert self_heal.metadata["candidate_ids"] == [candidate.id]

    # Re-running the cycle is a no-op: the row is terminal now.
    _ = StuckStateWatchdog.run_cycle(opts)

    assert length(
             ActionLedger.list_recent(operator_id,
               event_type: "runtime.self_healed",
               limit: 10
             )
           ) == 1
  end

  test "awaiting_confirmation prepared actions past expires_at are actively swept",
       %{operator_id: operator_id, opts: opts} do
    prepared_action = expired_prepared_action(operator_id)
    assert prepared_action.status == "awaiting_confirmation"

    result = StuckStateWatchdog.run_cycle(opts)
    assert result.swept >= 1

    swept = Repo.get!(PreparedAction, prepared_action.id)
    assert swept.status == "expired"
    assert swept.error == "confirmation_expired"

    # Normal-UX expiry is silent: no stuck_state incident for a small batch.
    incidents =
      RuntimeIncident
      |> where([incident], incident.kind in ["stuck_state_detected", "stuck_state_swept"])
      |> where(
        [incident],
        fragment("?->>'table' = ?", incident.metadata, "telegram_prepared_actions")
      )
      |> Repo.all()

    assert incidents == []
  end

  test "clean database detects nothing and sends no email", %{opts: opts} do
    result = StuckStateWatchdog.run_cycle(opts)

    assert result.detected == 0
    assert result.swept == 0
    assert Agent.get(:capturing_email_recorder, &Enum.reverse/1) == []
  end

  defp stranded_insight_delivery(user_id, agent_id, minutes_old: minutes_old) do
    {:ok, [insight]} =
      Insights.record_many(user_id, agent_id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Reply to the stuck escalation",
          "summary" => "This delivery is stranded pending.",
          "recommended_action" => "Reply now.",
          "priority" => 95,
          "confidence" => 0.9,
          "dedupe_key" => "watchdog-insight-#{System.unique_integer([:positive])}"
        }
      ])

    {:ok, delivery} =
      %Delivery{}
      |> Delivery.changeset(%{
        insight_id: insight.id,
        user_id: user_id,
        channel: "telegram",
        destination: "12345",
        score: 0.9,
        threshold: 0.78,
        status: "pending"
      })
      |> Repo.insert()

    backdated = DateTime.add(DateTime.utc_now(), -minutes_old * 60, :second)

    {1, _} =
      Delivery
      |> where([row], row.id == ^delivery.id)
      |> Repo.update_all(set: [inserted_at: backdated])

    Repo.get!(Delivery, delivery.id)
  end

  defp expired_prepared_action(user_id) do
    {:ok, run} =
      TelegramAssistant.start_run(%{
        user_id: user_id,
        chat_id: "12345",
        surface: "telegram",
        trigger_type: "follow_up",
        status: "completed",
        model_provider: "deterministic",
        model_name: "watchdog_test",
        prompt_snapshot: %{},
        result_summary: %{},
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now()
      })

    {:ok, prepared_action} =
      TelegramAssistant.create_prepared_action(%{
        user_id: user_id,
        chat_id: "12345",
        surface: "telegram",
        run_id: run.id,
        action_type: "gmail_draft_send",
        target_type: "gmail_draft",
        payload: %{"todo_id" => Ecto.UUID.generate()},
        preview_text: "Send the stuck draft",
        status: "awaiting_confirmation",
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

    prepared_action
  end
end
