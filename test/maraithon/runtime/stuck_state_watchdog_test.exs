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
  alias Maraithon.Runtime.BackgroundJob
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

    # The briefs check treats quiet-hours-gated rows as "waiting", not
    # "stuck" — pin quiet hours away from now so detection assertions don't
    # depend on what hour the suite runs at. The quiet-hours test overrides.
    assistant_config = Application.get_env(:maraithon, :telegram_assistant, [])
    local_hour = Maraithon.TelegramAssistant.PushBroker.local_now_for_user(operator_id).hour

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(assistant_config,
        telegram_unified_push_enabled: true,
        quiet_hours_start_local: rem(local_hour + 2, 24),
        quiet_hours_end_local: rem(local_hour + 3, 24)
      )
    )

    on_exit(fn -> Application.put_env(:maraithon, :telegram_assistant, assistant_config) end)

    %{
      operator_id: operator_id,
      agent: agent,
      opts: [operator_id: operator_id, email_module: CapturingEmail]
    }
  end

  test "briefs gated by quiet hours wait for morning instead of alarming", %{
    operator_id: operator_id,
    agent: agent,
    opts: opts
  } do
    # Quiet hours cover "now" for the operator: an old pending brief is
    # deliberately deferred by the planner, not stuck.
    local_hour = Maraithon.TelegramAssistant.PushBroker.local_now_for_user(operator_id).hour

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(Application.get_env(:maraithon, :telegram_assistant, []),
        quiet_hours_start_local: local_hour,
        quiet_hours_end_local: rem(local_hour + 1, 24)
      )
    )

    two_hours_ago = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)

    {:ok, brief} =
      Briefs.record(operator_id, agent.id, %{
        "cadence" => "morning",
        "scheduled_for" => DateTime.to_iso8601(two_hours_ago),
        "dedupe_key" => "watchdog-quiet-hours-brief",
        "status" => "pending",
        "title" => "Overnight brief",
        "summary" => "Waiting for quiet hours to end.",
        "body" => "Overnight brief body."
      })

    assert brief.status == "pending"

    _ = StuckStateWatchdog.run_cycle(opts)

    briefs_incidents =
      RuntimeIncident
      |> where([incident], incident.kind == "stuck_state_detected")
      |> where([incident], fragment("?->>'table' = ?", incident.metadata, "briefs"))
      |> Repo.all()

    assert briefs_incidents == []
  end

  test "an explicit proactive admission pause suppresses only unattempted delivery alarms", %{
    operator_id: operator_id,
    agent: agent,
    opts: opts
  } do
    set_unified_push_setting(false)
    assert TelegramAssistant.unified_push_explicitly_disabled?()
    two_hours_ago = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)

    pending_brief = stale_brief(operator_id, agent.id, two_hours_ago, "paused-brief")

    failed_brief =
      operator_id
      |> stale_brief(agent.id, two_hours_ago, "retryable-failed-brief")
      |> Ecto.Changeset.change(%{
        status: "failed",
        error_message: "temporary delivery failure"
      })
      |> Repo.update!()

    delivery = stranded_insight_delivery(operator_id, agent.id, minutes_old: 30)
    candidate = stale_pending_candidate(operator_id, hours_old: 5)
    background_job = stale_background_job(hours_old: 2)

    result = StuckStateWatchdog.run_cycle(opts)

    assert result == %{detected: 3, swept: 0, alerted: 3}
    assert detected_tables() == ["background_jobs", "briefs", "proactive_candidates"]

    brief_incident =
      Repo.one!(
        from incident in RuntimeIncident,
          where: incident.kind == "stuck_state_detected",
          where: fragment("?->>'table' = ?", incident.metadata, "briefs")
      )

    # Only the retryable failed brief contributes; the equally old pending
    # brief retained by the admission pause does not inflate the alarm.
    assert brief_incident.metadata["count"] == 1

    subjects =
      :capturing_email_recorder
      |> Agent.get(&Enum.reverse/1)
      |> Enum.map(& &1.content.subject)

    assert Enum.any?(subjects, &(&1 =~ "background_jobs"))
    assert Enum.any?(subjects, &(&1 =~ "briefs"))
    assert Enum.any?(subjects, &(&1 =~ "proactive_candidates"))
    refute Enum.any?(subjects, &(&1 =~ "insight_deliveries"))

    # Detection is read-only. Only rows whose lack of delivery is explained
    # by the admission pause are suppressed; attempted failures and cleanup
    # or lifecycle signals remain visible.
    assert Repo.get!(Maraithon.Briefs.Brief, pending_brief.id).status == "pending"
    assert Repo.get!(Maraithon.Briefs.Brief, failed_brief.id).status == "failed"
    assert Repo.get!(Delivery, delivery.id).status == "pending"
    assert Repo.get!(ProactiveCandidate, candidate.id).status == "pending"
    assert Repo.get!(BackgroundJob, background_job.id).status == "pending"
  end

  test "delivery SLA alarms remain active when proactive admission is true", %{
    operator_id: operator_id,
    agent: agent,
    opts: opts
  } do
    set_unified_push_setting(true)
    refute TelegramAssistant.unified_push_explicitly_disabled?()
    two_hours_ago = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
    brief = stale_brief(operator_id, agent.id, two_hours_ago, "enabled-brief")

    result = StuckStateWatchdog.run_cycle(opts)

    assert result == %{detected: 1, swept: 0, alerted: 1}
    assert detected_tables() == ["briefs"]
    assert Repo.get!(Maraithon.Briefs.Brief, brief.id).status == "pending"
  end

  test "delivery SLA alarms remain active when proactive admission is nil", %{
    operator_id: operator_id,
    agent: agent,
    opts: opts
  } do
    set_unified_push_setting(nil)
    refute TelegramAssistant.unified_push_explicitly_disabled?()
    two_hours_ago = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
    brief = stale_brief(operator_id, agent.id, two_hours_ago, "defaulted-brief")

    result = StuckStateWatchdog.run_cycle(opts)

    assert result == %{detected: 1, swept: 0, alerted: 1}
    assert detected_tables() == ["briefs"]
    assert Repo.get!(Maraithon.Briefs.Brief, brief.id).status == "pending"
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

  test "a mass expiry of OLD prepared actions records a backlog incident without alarming",
       %{operator_id: operator_id, opts: opts} do
    # 21 rows (> threshold 20), all minted well outside the 48h recent
    # window: this is a historical-backlog cleanup, not confirmations
    # breaking — the watchdog must log it, not page the operator.
    prepared_actions = for _ <- 1..21, do: expired_prepared_action(operator_id)
    backdated = DateTime.add(DateTime.utc_now(), -30 * 24 * 60 * 60, :second)

    Repo.update_all(
      from(prepared_action in PreparedAction,
        where: prepared_action.id in ^Enum.map(prepared_actions, & &1.id)
      ),
      set: [inserted_at: backdated]
    )

    result = StuckStateWatchdog.run_cycle(opts)
    assert result.swept >= 21
    assert result.alerted == 0

    reasons =
      RuntimeIncident
      |> where([incident], incident.kind == "stuck_state_swept")
      |> where(
        [incident],
        fragment("?->>'table' = ?", incident.metadata, "telegram_prepared_actions")
      )
      |> select([incident], incident.reason)
      |> Repo.all()

    assert "prepared-action backlog cleanup" in reasons
  end

  test "clean database detects nothing and sends no email", %{opts: opts} do
    result = StuckStateWatchdog.run_cycle(opts)

    assert result.detected == 0
    assert result.swept == 0
    assert Agent.get(:capturing_email_recorder, &Enum.reverse/1) == []
  end

  defp set_unified_push_setting(value) do
    config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.put(config, :telegram_unified_push_enabled, value)
    )
  end

  defp stale_brief(user_id, agent_id, scheduled_for, suffix) do
    {:ok, brief} =
      Briefs.record(user_id, agent_id, %{
        "cadence" => "morning",
        "scheduled_for" => DateTime.to_iso8601(scheduled_for),
        "dedupe_key" => "watchdog-#{suffix}-#{System.unique_integer([:positive])}",
        "status" => "pending",
        "title" => "Stale delivery brief",
        "summary" => "The delivery SLA determines whether this should alarm.",
        "body" => "The watchdog must never mutate this pending brief."
      })

    brief
  end

  defp stale_pending_candidate(user_id, hours_old: hours_old) do
    {:ok, candidate} =
      ProactiveQueue.enqueue(%{
        user_id: user_id,
        source: "brief",
        source_id: "paused-candidate-#{System.unique_integer([:positive])}",
        dedupe_key: "paused-candidate-#{System.unique_integer([:positive])}",
        title: "Paused proactive delivery",
        body: "This row is intentionally retained while admission is paused.",
        urgency: 0.7
      })

    backdated = DateTime.add(DateTime.utc_now(), -hours_old * 3600, :second)

    {1, _} =
      ProactiveCandidate
      |> where([row], row.id == ^candidate.id)
      |> Repo.update_all(set: [inserted_at: backdated, updated_at: backdated])

    Repo.get!(ProactiveCandidate, candidate.id)
  end

  defp stale_background_job(hours_old: hours_old) do
    backdated = DateTime.add(DateTime.utc_now(), -hours_old * 3600, :second)

    job =
      %BackgroundJob{}
      |> BackgroundJob.changeset(%{
        queue: "watchdog",
        job_type: "watchdog_lifecycle_probe",
        scheduled_at: backdated,
        status: "pending"
      })
      |> Repo.insert!()

    {1, _} =
      BackgroundJob
      |> where([row], row.id == ^job.id)
      |> Repo.update_all(set: [inserted_at: backdated, updated_at: backdated])

    Repo.get!(BackgroundJob, job.id)
  end

  defp detected_tables do
    RuntimeIncident
    |> where([incident], incident.kind == "stuck_state_detected")
    |> order_by([incident], asc: incident.occurred_at)
    |> select([incident], fragment("?->>'table'", incident.metadata))
    |> Repo.all()
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
