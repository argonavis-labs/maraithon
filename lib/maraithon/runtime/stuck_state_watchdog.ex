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

  Alerting: live backlog alarms are deduped per `(table, UTC day)` via
  `OperatorEvents.record_once/1` (the `BriefingCron.claim_late_alert/2`
  pattern). Terminal scheduled-job dead letters instead use their newest row
  as a durable incident frontier, so the same failed rows cannot alert again
  merely because UTC midnight passed. Alarms are delivered **by email** via
  `Maraithon.EmailDelivery.send/2`
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
  alias Maraithon.TelegramAssistant.PushBroker

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
      Logger.warning("Stuck-state watchdog cycle failed",
        failure_code: Maraithon.Redaction.error_class(error)
      )

      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  @doc """
  Runs one full watchdog cycle: the two sweeps this module owns, then the
  detect-only registry. Public so tests (and a console session) can drive a
  cycle directly. Returns `%{detected:, swept:, alerted:}`.
  """
  def run_cycle(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

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
        failure_code: Maraithon.Redaction.error_class(error)
      )

      nil
  end

  # Detect only: Scheduler owns these rows. Any recent dead-letter means an
  # agent's wakeup silently died. No updated_at on this table; fire_at
  # approximates when the dead-letter happened (see @moduledoc). The newest
  # failed row is a stable incident frontier: retaining the same terminal rows
  # across UTC midnight must not page the operator again.
  defp check_scheduled_jobs(now) do
    lookback = DateTime.add(now, -@scheduled_jobs_failed_lookback_hours * 3600, :second)

    query =
      ScheduledJob
      |> where([job], job.status == "failed")
      |> where([job], job.fire_at >= ^lookback)

    newest_failed_id =
      query
      |> order_by([job], desc: job.fire_at, desc: job.inserted_at, desc: job.id)
      |> select([job], job.id)
      |> limit(1)
      |> Repo.one()

    if newest_failed_id do
      oldest_first(query, :fire_at, now,
        reason: "scheduled jobs dead-lettered after repeated unacknowledged dispatches",
        dedupe_key: "stuck_state_watchdog:scheduled_jobs:dead_letter:#{newest_failed_id}"
      )
    end
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
  #
  # Quiet hours: a brief whose user is inside their quiet-hours window is
  # gated by the send-time budget, not stuck — the planner defers it until
  # morning by design. Those rows are excluded while the window is open; a
  # genuinely stuck brief still alarms on the first post-quiet-hours tick
  # (a 30-minute cadence), when the operator is awake to read the email.
  defp check_briefs(now) do
    terminal_errors = DeliveryErrorCopy.terminal_storage_messages()
    cutoff = DateTime.add(now, -@briefs_max_late_minutes * 60, :second)

    query =
      Brief
      |> where([brief], brief.scheduled_for < ^cutoff)

    query =
      if TelegramAssistant.unified_push_explicitly_disabled?() do
        # Pending rows are retained intentionally while proactive admission is
        # paused. Retryable failed rows crossed an attempted-delivery boundary
        # and remain actionable evidence, so they must continue to alarm.
        where(
          query,
          [brief],
          brief.status == "failed" and
            (is_nil(brief.error_message) or brief.error_message not in ^terminal_errors)
        )
      else
        where(
          query,
          [brief],
          brief.status == "pending" or
            (brief.status == "failed" and
               (is_nil(brief.error_message) or brief.error_message not in ^terminal_errors))
        )
      end

    rows =
      query
      |> select([brief], {brief.user_id, brief.scheduled_for})
      |> Repo.all()

    live =
      rows
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.reject(fn {user_id, _scheduled} ->
        PushBroker.quiet_hours_now_for_user?(user_id)
      end)
      |> Enum.flat_map(&elem(&1, 1))

    if live == [] do
      nil
    else
      oldest = Enum.min_by(live, &DateTime.to_unix(&1, :second))

      %{
        count: length(live),
        oldest_age_seconds: age_seconds(oldest, now),
        reason: "briefs stuck past the 90-minute defensive SLA (notifier not ticking?)"
      }
    end
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
    if TelegramAssistant.unified_push_explicitly_disabled?() do
      # These rows have not crossed an attempted-delivery boundary. The
      # explicit admission pause intentionally leaves them pending.
      nil
    else
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
  end

  defp oldest_first(query, age_field, now, opts) do
    count = Repo.aggregate(query, :count, :id)

    if count > 0 do
      oldest = query |> select([row], min(field(row, ^age_field))) |> Repo.one()

      alarm = %{
        count: count,
        oldest_age_seconds: age_seconds(oldest, now),
        reason: Keyword.get(opts, :reason)
      }

      case Keyword.fetch(opts, :dedupe_key) do
        {:ok, dedupe_key} -> Map.put(alarm, :dedupe_key, dedupe_key)
        :error -> alarm
      end
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
      Logger.warning("Stuck-state sweep failed",
        failure_code: Maraithon.Redaction.error_class(error)
      )

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
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: Maraithon.Redaction.error_class(error)
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
  # expiry of RECENTLY-minted actions (> @prepared_action_mass_expiry_threshold
  # rows inserted in the last 48h expiring in one tick) is pathological —
  # something is systematically preventing confirmations. A mass expiry of
  # old rows is the sweep doing its job on a historical backlog (the very
  # stranded state this module exists to heal): record the incident so it's
  # auditable, but don't page the operator with a false "confirmations
  # broken?" alarm for a one-time cleanup.
  defp sweep_prepared_actions(now, _opts) do
    %{count: count, recent_count: recent_count, oldest_inserted_at: oldest_inserted_at} =
      TelegramAssistant.expire_stale_prepared_actions_with_stats(now)

    oldest_age_seconds =
      case oldest_inserted_at do
        %DateTime{} = at ->
          max(DateTime.diff(now, at, :second), 0)

        %NaiveDateTime{} = at ->
          max(DateTime.diff(now, DateTime.from_naive!(at, "Etc/UTC"), :second), 0)

        _ ->
          0
      end

    alarms =
      cond do
        recent_count > @prepared_action_mass_expiry_threshold ->
          _ =
            IncidentLog.record(%{
              kind: "stuck_state_swept",
              reason: "unusually large prepared-action expiry batch",
              metadata: %{
                "table" => "telegram_prepared_actions",
                "count" => count,
                "recent_count" => recent_count
              }
            })

          [
            %{
              table: "telegram_prepared_actions",
              count: recent_count,
              oldest_age_seconds: oldest_age_seconds,
              reason:
                "#{recent_count} prepared actions minted in the last 48h expired " <>
                  "unconfirmed in one sweep (are Telegram confirmations broken?)"
            }
          ]

        count > @prepared_action_mass_expiry_threshold ->
          _ =
            IncidentLog.record(%{
              kind: "stuck_state_swept",
              reason: "prepared-action backlog cleanup",
              metadata: %{
                "table" => "telegram_prepared_actions",
                "count" => count,
                "recent_count" => recent_count,
                "oldest_inserted_at" => oldest_inserted_at && to_string(oldest_inserted_at)
              }
            })

          []

        true ->
          []
      end

    %{swept: count, alarms: alarms}
  end

  defp merge_sweep(acc, %{swept: swept, alarms: alarms}) do
    %{acc | swept: acc.swept + swept, alarms: acc.alarms ++ alarms}
  end

  # ==========================================================================
  # Operator alerting (R4/R5): email, with per-alarm durable dedupe
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
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        :deduped
    end
  rescue
    error ->
      Logger.warning("Stuck-state operator alert failed",
        table: alarm.table,
        failure_code: Maraithon.Redaction.error_class(error)
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
             dedupe_key: alarm_dedupe_key(alarm, now),
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

  defp alarm_dedupe_key(%{dedupe_key: dedupe_key}, _now)
       when is_binary(dedupe_key) and dedupe_key != "",
       do: dedupe_key

  defp alarm_dedupe_key(%{table: table}, now) do
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
        Affected rows past SLA: #{alarm.count}
        Oldest row age: #{oldest_minutes} minutes
        Detail: #{alarm.reason}

        Alerts are durably deduplicated to limit repeat email. Check the runtime
        incident log and the System pages in the web app for detail.
        """,
        html_body: """
        <p>Maraithon's stuck-state watchdog found rows stuck past their SLA.</p>
        <ul>
          <li><b>Table:</b> #{alarm.table}</li>
          <li><b>Affected rows past SLA:</b> #{alarm.count}</li>
          <li><b>Oldest row age:</b> #{oldest_minutes} minutes</li>
          <li><b>Detail:</b> #{alarm.reason}</li>
        </ul>
        <p>Alerts are durably deduplicated to limit repeat email. Check the runtime
        incident log and the System pages in the web app for detail.</p>
        """
      })
    end

    :ok
  rescue
    error ->
      Logger.warning("Stuck-state alert email failed",
        table: alarm.table,
        failure_code: Maraithon.Redaction.error_class(error)
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
