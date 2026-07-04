defmodule Maraithon.Runtime.StuckStateWatchdog do
  @moduledoc """
  Max-age SLAs for every durable queue-like table (SPEC 02).

  The 2026-07-03 incident (26 briefs stuck `pending` for six days with zero
  alarm) was one instance of a recurring pattern: a queue table accumulates
  non-terminal rows and nothing watches the age of the oldest live row.
  This process makes "silence means nothing needs you" an enforced
  invariant: one declarative registry of tables, each with a live-status
  filter, an age reference, and an alarm threshold.

  Detect-only tables (their sweeps already have owners — never touched
  here, only alarmed on; inventing a second reclaim would race the owner):

    * `scheduled_jobs` — `Scheduler.reclaim_stale_dispatched_jobs/1`
      dead-letters; any recent dead-letter is alarm-worthy (an agent's
      wakeup silently died). The table has no `updated_at`, so "recent" is
      approximated by `fire_at` within the last 24h (a dead-letter lands
      within minutes of `fire_at`).
    * `background_jobs` / `effects` — oldest *due* `pending` row older than
      30 minutes (comfortably past the 5-minute claim timeouts) means the
      runner itself is not ticking. Rows deliberately deferred to the
      future (`scheduled_at`/`retry_after`) are not "due" and are excluded.
    * `briefs` — owned by `Briefs.expire_stale_pending/1` +
      `BriefingCron.alert_late_briefings/2`; defensive 90-minutes-late
      alarm that should be unreachable unless the notifier itself died.
      `scheduled_for` is UTC and compared against UTC only.
    * `insight_deliveries` — after SPEC 02 R6, a `pending` telegram
      delivery should clear within one `InsightNotifier` tick; 10 minutes.
    * `proactive_candidates` (pending/planned) — normal expiry is owned by
      `ProactiveQueue.expire_stale/1`; alarm only at 2x the candidate TTL
      (a sign `ProactiveCheckIn` died, not that candidates expire normally).

  Sweep + detect tables (no existing owner — swept here):

    * `proactive_candidates` (held) — `ProactiveQueue.expire_stale_held/2`
      (7-day TTL from `updated_at`); each expiry writes an `ActionLedger`
      row and the batch is narrated per user as `runtime.self_healed`.
    * `telegram_prepared_actions` — expiry was lazy-at-read only;
      `TelegramAssistant.expire_stale_prepared_actions/1` actively flips
      rows past `expires_at`. A user never tapping Confirm is normal UX,
      so this sweep is silent (no incident, no self-heal narration) unless
      more than `@prepared_action_mass_expiry_threshold` (20) rows expire
      in a single tick — that suggests something is systematically
      preventing confirmations (e.g. a broken callback route) and is
      alarmed like a detect table.

  Alerting: operator alarms are deduped per `(table, UTC day)` via
  `OperatorEvents.record_once/1` (the `BriefingCron.claim_late_alert/2`
  pattern) and delivered **by email** via `Maraithon.EmailDelivery.send/2`
  to `Config.get(:dogfood_user_id)` — which is an email address, never a
  chat id, so `PushBroker.deliver/1` must not be used here (it would
  return `{:error, :missing_chat_id}` on every call and the watchdog's own
  alarm would be exactly the silent failure it exists to cure). The
  user-facing "I fixed something" self-report is a completely separate
  surface: a durable `ActionLedger` `runtime.self_healed` fact that the
  user's own morning-briefing model may choose to mention (model-gated),
  never pushed by the runtime.

  Each registry entry runs inside its own rescue — one bad table never
  aborts the cycle — and the next tick is scheduled only after the current
  cycle completes, so overlapping cycles are impossible.
  """

  use GenServer

  import Ecto.Query

  alias Maraithon.ActionLedger
  alias Maraithon.Briefs.Brief
  alias Maraithon.DeliveryErrorCopy
  alias Maraithon.EmailDelivery
  alias Maraithon.Effects.Effect
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.OperatorEvents
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.IncidentLog
  alias Maraithon.Runtime.ScheduledJob
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.ProactiveCandidate
  alias Maraithon.TelegramAssistant.ProactiveQueue

  require Logger

  @name __MODULE__
  @default_interval_ms :timer.minutes(30)
  @default_batch_size 500
  @default_initial_delay_ms :timer.seconds(45)

  # Alarm thresholds (see @moduledoc for the reasoning per table).
  @background_jobs_max_pending_minutes 30
  @effects_max_pending_minutes 30
  @briefs_max_late_minutes 90
  @insight_deliveries_max_pending_minutes 10
  @scheduled_jobs_failed_lookback_hours 24
  @prepared_action_mass_expiry_threshold 20

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, @name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        positive_integer_opt(
          opts,
          :interval_ms,
          Config.positive_integer(:stuck_state_watchdog_interval_ms, @default_interval_ms)
        ),
      batch_size:
        positive_integer_opt(
          opts,
          :batch_size,
          Config.positive_integer(:stuck_state_watchdog_batch_size, @default_batch_size)
        ),
      observer: Keyword.get(opts, :observer),
      email_module: Keyword.get(opts, :email_module),
      operator_id: Keyword.get(opts, :operator_id)
    }

    initial_delay_ms = positive_integer_opt(opts, :initial_delay_ms, @default_initial_delay_ms)
    schedule_tick(initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    result =
      run_cycle(
        operator_id: state.operator_id,
        email_module: state.email_module,
        batch_size: state.batch_size
      )

    if result.detected > 0 or result.swept > 0 do
      Logger.info("Stuck-state watchdog cycle",
        detected: result.detected,
        swept: result.swept,
        alerted: result.alerted
      )
    end

    if is_pid(state.observer) do
      send(state.observer, {:stuck_state_watchdog_cycle, result})
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Stuck-state watchdog cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  @doc """
  Runs one full watchdog cycle: the two sweeps this module owns, then the
  detect-only registry. Public so tests (and a console session) can drive a
  cycle directly. Returns `%{detected:, swept:, alerted:}`.
  """
  def run_cycle(opts \\ []) do
    now = DateTime.utc_now()

    sweep_result =
      %{swept: 0, alarms: []}
      |> merge_sweep(safe_sweep(fn -> sweep_held_candidates(now, opts) end))
      |> merge_sweep(safe_sweep(fn -> sweep_prepared_actions(now, opts) end))

    detections =
      Enum.flat_map(detect_specs(), fn spec ->
        case safe_check(spec, now) do
          nil -> []
          alarm -> [alarm]
        end
      end)

    alarms = detections ++ sweep_result.alarms

    alerted =
      Enum.count(alarms, fn alarm ->
        alert_operator(alarm, now, opts) == :alerted
      end)

    %{detected: length(alarms), swept: sweep_result.swept, alerted: alerted}
  end

  # ==========================================================================
  # Detect-only registry (R2)
  # ==========================================================================

  defp detect_specs do
    [
      %{table: "scheduled_jobs", check: &check_scheduled_jobs/1},
      %{table: "background_jobs", check: &check_background_jobs/1},
      %{table: "effects", check: &check_effects/1},
      %{table: "briefs", check: &check_briefs/1},
      %{table: "proactive_candidates", check: &check_live_proactive_candidates/1},
      %{table: "insight_deliveries", check: &check_insight_deliveries/1}
    ]
  end

  # One bad table must never abort the cycle.
  defp safe_check(%{table: table, check: check}, now) do
    case check.(now) do
      %{count: count} = alarm when count > 0 -> Map.put(alarm, :table, table)
      _other -> nil
    end
  rescue
    error ->
      Logger.warning("Stuck-state check failed",
        table: table,
        reason: Exception.message(error)
      )

      nil
  end

  # Detect only: Scheduler owns these rows. Any recent dead-letter means an
  # agent's wakeup silently died. No updated_at on this table; fire_at
  # approximates when the dead-letter happened (see @moduledoc).
  defp check_scheduled_jobs(now) do
    lookback = DateTime.add(now, -@scheduled_jobs_failed_lookback_hours * 3600, :second)

    oldest_first(
      ScheduledJob
      |> where([job], job.status == "failed")
      |> where([job], job.fire_at >= ^lookback),
      :fire_at,
      now,
      reason: "scheduled jobs dead-lettered after repeated unacknowledged dispatches"
    )
  end

  # Detect only: BackgroundJobRunner owns these rows. A *due* pending job
  # this old means the runner is not ticking (claim timeout is 5 minutes).
  defp check_background_jobs(now) do
    cutoff = DateTime.add(now, -@background_jobs_max_pending_minutes * 60, :second)

    oldest_first(
      BackgroundJob
      |> where([job], job.status == "pending")
      # "Due for 30+ minutes": a retry_after-deferred job whose
      # scheduled_at only just passed is not stuck, however old its
      # inserted_at is.
      |> where([job], is_nil(job.scheduled_at) or job.scheduled_at <= ^cutoff)
      |> where([job], job.inserted_at <= ^cutoff),
      :inserted_at,
      now,
      reason: "background job runner appears stalled (due pending jobs > 30m old)"
    )
  end

  # Detect only: EffectRunner owns these rows (claim timeout 5 minutes;
  # retry_after deferrals cap at 5 minutes).
  defp check_effects(now) do
    cutoff = DateTime.add(now, -@effects_max_pending_minutes * 60, :second)

    oldest_first(
      Effect
      |> where([effect], effect.status == "pending")
      |> where([effect], is_nil(effect.retry_after) or effect.retry_after <= ^now)
      |> where([effect], effect.inserted_at <= ^cutoff),
      :inserted_at,
      now,
      reason: "effect runner appears stalled (pending effects > 30m old)"
    )
  end

  # Detect only: Briefs.expire_stale_pending/1 + BriefingCron already own
  # this table (email alert at 60m late); this defensive 90m alarm should be
  # unreachable unless BriefNotifier/BriefingCron itself is not ticking.
  # scheduled_for is stored UTC and compared against UTC — never a local
  # wall clock (the exact bug behind the 2026-07-03 incident).
  defp check_briefs(now) do
    terminal_errors = DeliveryErrorCopy.terminal_storage_messages()
    cutoff = DateTime.add(now, -@briefs_max_late_minutes * 60, :second)

    oldest_first(
      Brief
      |> where(
        [brief],
        brief.status == "pending" or
          (brief.status == "failed" and
             (is_nil(brief.error_message) or brief.error_message not in ^terminal_errors))
      )
      |> where([brief], brief.scheduled_for < ^cutoff),
      :scheduled_for,
      now,
      reason: "briefs stuck past the 90-minute defensive SLA (notifier not ticking?)"
    )
  end

  # Detect only: pending/planned expiry is routine, owned by
  # ProactiveQueue.expire_stale/1. Alarm only at 2x the normal TTL — a sign
  # the planner GenServer died or its feature flag flipped off, not that
  # candidates are expiring normally.
  defp check_live_proactive_candidates(now) do
    threshold_minutes = 2 * ProactiveQueue.candidate_ttl_minutes()
    cutoff = DateTime.add(now, -threshold_minutes * 60, :second)

    oldest_first(
      ProactiveCandidate
      |> where([candidate], candidate.status in ["pending", "planned"])
      |> where([candidate], candidate.inserted_at <= ^cutoff),
      :inserted_at,
      now,
      reason: "proactive candidates live past 2x TTL (planner not ticking?)"
    )
  end

  # Detect only: after SPEC 02 R6, a pending telegram delivery should clear
  # within one InsightNotifier tick (60s); 10 minutes means it is stranded.
  defp check_insight_deliveries(now) do
    cutoff = DateTime.add(now, -@insight_deliveries_max_pending_minutes * 60, :second)

    oldest_first(
      Delivery
      |> where([delivery], delivery.status == "pending")
      |> where([delivery], delivery.channel == "telegram")
      |> where([delivery], delivery.inserted_at <= ^cutoff),
      :inserted_at,
      now,
      reason: "insight deliveries stranded pending (planner not marking them sent?)"
    )
  end

  defp oldest_first(query, age_field, now, opts) do
    count = Repo.aggregate(query, :count, :id)

    if count > 0 do
      oldest = query |> select([row], min(field(row, ^age_field))) |> Repo.one()

      %{
        count: count,
        oldest_age_seconds: age_seconds(oldest, now),
        reason: Keyword.get(opts, :reason)
      }
    else
      nil
    end
  end

  defp age_seconds(%DateTime{} = oldest, now), do: max(DateTime.diff(now, oldest, :second), 0)
  defp age_seconds(_oldest, _now), do: 0

  # ==========================================================================
  # Sweeps this module owns (R7 held candidates, R11 prepared actions)
  # ==========================================================================

  defp safe_sweep(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      Logger.warning("Stuck-state sweep failed", reason: Exception.message(error))
      %{swept: 0, alarms: []}
  end

  defp sweep_held_candidates(now, _opts) do
    expired = ProactiveQueue.expire_stale_held(now)

    if expired != [] do
      _ =
        IncidentLog.record(%{
          kind: "stuck_state_swept",
          reason: "expired held proactive candidates past the 7-day held TTL",
          metadata: %{
            "table" => "proactive_candidates",
            "count" => length(expired),
            "candidate_ids" => Enum.map(expired, & &1.id)
          }
        })

      expired
      |> Enum.group_by(& &1.user_id)
      |> Enum.each(fn {user_id, rows} -> record_self_heal(user_id, rows, now) end)
    end

    %{swept: length(expired), alarms: []}
  end

  # SPEC 02 R13: the user-facing self-report fact. Scoped to per-user tables
  # only — infra tables have no natural single affected end-user and stay
  # operator-only via the email alert. Goes through ActionLedger.record/1
  # (never a raw insert) so the summary passes the ledger's redaction pass.
  defp record_self_heal(user_id, rows, now) do
    _ =
      ActionLedger.record(%{
        user_id: user_id,
        surface: "runtime",
        event_type: "runtime.self_healed",
        status: "completed",
        model_summary: self_heal_summary(rows, now),
        metadata: %{
          "table" => "proactive_candidates",
          "count" => length(rows),
          "candidate_ids" => Enum.map(rows, & &1.id)
        }
      })

    :ok
  rescue
    error ->
      Logger.warning("Failed to record self-heal ledger entry",
        user_id: user_id,
        reason: Exception.message(error)
      )

      :ok
  end

  # Reads like a person wrote it — this is the string a later brief may
  # quote or paraphrase, not a log line.
  defp self_heal_summary([row], now) do
    "Cleared 1 held nudge#{held_title_fragment(row)} that had been waiting #{held_days(row, now)}."
  end

  defp self_heal_summary(rows, now) do
    oldest = Enum.min_by(rows, &sortable_held_since/1, fn -> hd(rows) end)

    "Cleared #{length(rows)} held nudges that had been waiting over a week; " <>
      "the oldest#{held_title_fragment(oldest)} had been waiting #{held_days(oldest, now)}."
  end

  defp held_title_fragment(%{title: title}) when is_binary(title) and title != "",
    do: " (“#{title}”)"

  defp held_title_fragment(_row), do: ""

  defp held_days(%{held_since: %DateTime{} = held_since}, now) do
    case DateTime.diff(now, held_since, :day) do
      days when days <= 1 -> "about a day"
      days -> "#{days} days"
    end
  end

  defp held_days(_row, _now), do: "over a week"

  defp sortable_held_since(%{held_since: %DateTime{} = held_since}),
    do: DateTime.to_unix(held_since)

  defp sortable_held_since(_row), do: 0

  # A user never tapping Confirm is normal UX — flip silently. Only a mass
  # expiry (> @prepared_action_mass_expiry_threshold in one tick) is
  # pathological (something is systematically preventing confirmations) and
  # gets an incident + operator alarm.
  defp sweep_prepared_actions(now, _opts) do
    count = TelegramAssistant.expire_stale_prepared_actions(now)

    alarms =
      if count > @prepared_action_mass_expiry_threshold do
        _ =
          IncidentLog.record(%{
            kind: "stuck_state_swept",
            reason: "unusually large prepared-action expiry batch",
            metadata: %{"table" => "telegram_prepared_actions", "count" => count}
          })

        [
          %{
            table: "telegram_prepared_actions",
            count: count,
            oldest_age_seconds: 0,
            reason:
              "#{count} prepared actions expired unconfirmed in one sweep " <>
                "(are Telegram confirmations broken?)"
          }
        ]
      else
        []
      end

    %{swept: count, alarms: alarms}
  end

  defp merge_sweep(acc, %{swept: swept, alarms: alarms}) do
    %{acc | swept: acc.swept + swept, alarms: acc.alarms ++ alarms}
  end

  # ==========================================================================
  # Operator alerting (R4/R5): email, deduped per (table, UTC day)
  # ==========================================================================

  defp alert_operator(alarm, now, opts) do
    operator_id = operator_id(opts)

    case claim_alarm(operator_id, alarm, now) do
      {:ok, :inserted} ->
        record_detected_incident(alarm)
        deliver_operator_email(operator_id, alarm, opts)
        :alerted

      {:ok, :existing} ->
        :deduped

      :no_operator ->
        # Never crash on a missing operator: still durable (IncidentLog) and
        # loud (Logger), just no email and no OperatorEvents dedupe row.
        record_detected_incident(alarm)

        Logger.warning(
          "Stuck state detected but no operator configured for email alert",
          table: alarm.table,
          count: alarm.count,
          oldest_age_seconds: alarm.oldest_age_seconds
        )

        :alerted

      {:error, reason} ->
        Logger.warning("Stuck-state alert dedupe failed",
          table: alarm.table,
          reason: inspect(reason)
        )

        :deduped
    end
  rescue
    error ->
      Logger.warning("Stuck-state operator alert failed",
        table: alarm.table,
        reason: Exception.message(error)
      )

      :deduped
  end

  defp claim_alarm(operator_id, alarm, now) do
    if is_binary(operator_id) and operator_id != "" do
      case OperatorEvents.record_once(%{
             user_id: operator_id,
             source: "stuck_state_watchdog",
             event_type: "stuck_state.alert_attempted",
             source_item_id: alarm.table,
             dedupe_key: alarm_dedupe_key(alarm.table, now),
             occurred_at: now,
             payload: %{
               "table" => alarm.table,
               "count" => alarm.count,
               "oldest_age_seconds" => alarm.oldest_age_seconds
             },
             metadata: %{"delivery_channel" => "email"}
           }) do
        {:ok, status, _event} -> {:ok, status}
        {:error, reason} -> {:error, reason}
      end
    else
      :no_operator
    end
  end

  defp alarm_dedupe_key(table, now) do
    "stuck_state_watchdog:#{table}:#{Date.to_iso8601(DateTime.to_date(now))}"
  end

  defp record_detected_incident(alarm) do
    _ =
      IncidentLog.record(%{
        kind: "stuck_state_detected",
        reason: alarm.reason,
        metadata: %{
          "table" => alarm.table,
          "count" => alarm.count,
          "oldest_age_seconds" => alarm.oldest_age_seconds
        }
      })

    :ok
  end

  # Operator alerts go by email — the one canonical operator channel —
  # never through PushBroker/Telegram (see @moduledoc).
  defp deliver_operator_email(operator_id, alarm, opts) do
    if is_binary(operator_id) and String.contains?(operator_id, "@") do
      oldest_minutes = div(alarm.oldest_age_seconds, 60)

      email_module(opts).send(operator_id, %{
        subject: "Maraithon stuck-state alarm: #{alarm.table}",
        text_body: """
        Maraithon's stuck-state watchdog found rows stuck past their SLA.

        Table: #{alarm.table}
        Live rows past SLA: #{alarm.count}
        Oldest row age: #{oldest_minutes} minutes
        Detail: #{alarm.reason}

        This alert is sent at most once per table per day. Check the runtime
        incident log and the System pages in the web app for detail.
        """,
        html_body: """
        <p>Maraithon's stuck-state watchdog found rows stuck past their SLA.</p>
        <ul>
          <li><b>Table:</b> #{alarm.table}</li>
          <li><b>Live rows past SLA:</b> #{alarm.count}</li>
          <li><b>Oldest row age:</b> #{oldest_minutes} minutes</li>
          <li><b>Detail:</b> #{alarm.reason}</li>
        </ul>
        <p>This alert is sent at most once per table per day. Check the runtime
        incident log and the System pages in the web app for detail.</p>
        """
      })
    end

    :ok
  rescue
    error ->
      Logger.warning("Stuck-state alert email failed",
        table: alarm.table,
        reason: Exception.message(error)
      )

      :ok
  end

  defp operator_id(opts) do
    case Keyword.get(opts, :operator_id) do
      value when is_binary(value) and value != "" -> value
      _other -> Config.get(:dogfood_user_id, nil)
    end
  end

  defp email_module(opts) do
    Keyword.get(opts, :email_module) ||
      Application.get_env(:maraithon, :stuck_state_watchdog, [])
      |> Keyword.get(:email_module, EmailDelivery)
  end

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end

  defp positive_integer_opt(opts, key, default) when is_list(opts) and is_atom(key) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
