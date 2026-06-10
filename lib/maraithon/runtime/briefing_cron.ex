defmodule Maraithon.Runtime.BriefingCron do
  @moduledoc """
  Database-driven cron for recurring operator briefings.

  The actual briefing work stays inside the Chief of Staff morning briefing
  skill. This process only scans persisted agent configuration and ensures a
  due morning briefing wakeup is queued once per local day per user.
  """

  use GenServer

  alias Maraithon.BriefingSchedules
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.Scheduler

  require Logger

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    state = %{
      interval_ms: Config.positive_integer(:briefing_cron_interval_ms, 60_000)
    }

    schedule_tick(5_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    result = schedule_due_morning_briefings(DateTime.utc_now())

    if result.scheduled > 0 or result.skipped > 0 do
      Logger.info("Briefing cron cycle",
        scheduled: result.scheduled,
        skipped: result.skipped
      )
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Briefing cron cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
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

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
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
