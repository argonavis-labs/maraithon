defmodule Maraithon.Runtime.BriefingCron do
  @moduledoc """
  Database-driven cron for recurring operator briefings.

  The actual briefing work stays inside the Chief of Staff morning briefing
  skill. Each durable recurring cycle scans persisted agent configuration and
  ensures a due morning briefing wakeup is queued once per local day per user.
  """

  alias Maraithon.BriefingSchedules
  alias Maraithon.EmailDelivery
  alias Maraithon.OperatorEvents
  alias Maraithon.Runtime.Scheduler

  require Logger

  # If the briefing still has not landed this long after its scheduled
  # time, tell the user by email instead of leaving an empty inbox.
  @late_alert_after_minutes 60

  @doc "Runs one briefing scheduling and late-alert cycle."
  def run_once(now \\ DateTime.utc_now()) do
    result = schedule_due_morning_briefings(now)

    if result.scheduled > 0 or result.skipped > 0 do
      Logger.info("Briefing cron cycle",
        scheduled: result.scheduled,
        skipped: result.skipped
      )
    end

    _state = alert_late_briefings(now)
    result
  end

  @doc false
  def alert_late_briefings(%DateTime{} = now, state \\ %{alerted_keys: MapSet.new()}) do
    state = Map.put_new(state, :alerted_keys, MapSet.new())

    BriefingSchedules.list_due_morning_agents(now)
    |> Enum.filter(&briefing_late?(&1, now))
    |> Enum.reduce(state, fn due, acc ->
      alert_key = late_alert_key(due)

      if MapSet.member?(acc.alerted_keys, alert_key) do
        acc
      else
        maybe_deliver_late_alert(due, now)
        %{acc | alerted_keys: MapSet.put(acc.alerted_keys, alert_key)}
      end
    end)
  end

  defp briefing_late?(due, now) do
    local_now = DateTime.add(now, due.timezone_offset_hours, :hour)

    scheduled_minutes = due.morning_brief_hour_local * 60 + due.morning_brief_minute_local
    now_minutes = local_now.hour * 60 + local_now.minute

    now_minutes - scheduled_minutes >= @late_alert_after_minutes
  end

  defp maybe_deliver_late_alert(due, now) do
    case claim_late_alert(due, now) do
      {:ok, :inserted} ->
        deliver_late_alert(due)

      {:ok, :existing} ->
        :ok

      {:error, reason} ->
        Logger.warning("Late-briefing alert dedupe failed",
          user_id: due.user_id,
          dedupe_key: due.dedupe_key,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp claim_late_alert(due, now) do
    case OperatorEvents.record_once(%{
           user_id: due.user_id,
           source: "briefing_cron",
           event_type: "morning_briefing.late_alert_attempted",
           source_item_id: due.dedupe_key,
           dedupe_key: operator_event_late_alert_key(due),
           occurred_at: now,
           payload: %{
             "agent_id" => due.agent_id,
             "briefing_dedupe_key" => due.dedupe_key,
             "local_date" => Date.to_iso8601(due.local_date),
             "timezone" => due.timezone_name,
             "timezone_offset_hours" => due.timezone_offset_hours,
             "morning_brief_hour_local" => due.morning_brief_hour_local,
             "morning_brief_minute_local" => due.morning_brief_minute_local
           },
           metadata: %{"delivery_channel" => "email"}
         }) do
      {:ok, status, _event} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_late_alert(due) do
    user_id = due.user_id

    if is_binary(user_id) and String.contains?(user_id, "@") do
      Logger.warning("Morning briefing is late; alerting user",
        user_id: user_id,
        dedupe_key: due.dedupe_key
      )

      email_module().send(user_id, %{
        subject: "Your morning briefing is running late",
        text_body: """
        Your Maraithon morning briefing has not been generated yet today.

        Maraithon keeps retrying automatically every 30 minutes and will email
        the briefing as soon as it is ready. If this keeps happening, check
        the Agents page in the web app.
        """,
        html_body: """
        <p>Your Maraithon morning briefing has not been generated yet today.</p>
        <p>Maraithon keeps retrying automatically every 30 minutes and will email
        the briefing as soon as it is ready. If this keeps happening, check the
        Agents page in the web app.</p>
        """
      })
    end
  rescue
    exception ->
      Logger.warning("Late-briefing alert failed", reason: Exception.message(exception))
  end

  defp late_alert_key(due), do: "#{due.user_id}:#{operator_event_late_alert_key(due)}"

  defp operator_event_late_alert_key(due) do
    "briefing_cron:late_alert:#{due.dedupe_key}"
  end

  defp email_module do
    Application.get_env(:maraithon, :briefing_cron, [])
    |> Keyword.get(:email_module, EmailDelivery)
  end

  # Briefings deliver by email and Telegram; generation must never be
  # gated on any single channel being healthy.
  def schedule_due_morning_briefings(%DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    BriefingSchedules.list_due_morning_agents(now)
    |> Enum.reduce(%{scheduled: 0, skipped: 0}, fn due, acc ->
      timezone_name = Map.get(due, :timezone_name)

      payload = %{
        "source" => "briefing_cron",
        "cadence" => "morning",
        "dedupe_key" => due.dedupe_key,
        "local_date" => Date.to_iso8601(due.local_date),
        "timezone" => timezone_name,
        "timezone_name" => timezone_name,
        "timezone_offset_hours" => due.timezone_offset_hours,
        "morning_brief_hour_local" => due.morning_brief_hour_local,
        "morning_brief_minute_local" => due.morning_brief_minute_local
      }

      if Scheduler.pending_payload?(due.agent_id, "wakeup", "dedupe_key", due.dedupe_key) or
           recently_attempted?(due.agent_id, due.dedupe_key, now) do
        %{acc | skipped: acc.skipped + 1}
      else
        case Scheduler.schedule_at(due.agent_id, "wakeup", now, payload) do
          {:ok, _job_id} ->
            %{acc | scheduled: acc.scheduled + 1}

          {:error, reason} ->
            Logger.warning("Failed to schedule morning briefing",
              agent_id: due.agent_id,
              user_id: due.user_id,
              reason: inspect(reason)
            )

            %{acc | skipped: acc.skipped + 1}
        end
      end
    end)
  end

  # A briefing run can legitimately take many minutes (large prompt, long
  # LLM call). Without this guard the cron re-fired the same briefing every
  # minute while a run was still in flight — burning model spend and
  # stacking concurrent runs whenever a run was slow or died silently.
  @retry_after_seconds 30 * 60

  defp recently_attempted?(agent_id, dedupe_key, now) do
    cutoff = DateTime.add(now, -@retry_after_seconds, :second)

    import Ecto.Query

    Maraithon.Repo.exists?(
      from(j in Maraithon.Runtime.ScheduledJob,
        where:
          j.agent_id == ^agent_id and j.job_type == "wakeup" and
            fragment("?->>? = ?", j.payload, "dedupe_key", ^dedupe_key) and
            j.inserted_at >= ^cutoff
      )
    )
  end
end
