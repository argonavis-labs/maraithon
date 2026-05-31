defmodule Maraithon.Runtime.DogfoodDigest do
  @moduledoc """
  Daily Telegram digest for the Chief of Staff dogfood stability run.
  """

  use GenServer

  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Telegram
  alias Maraithon.Health
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.IncidentLog
  alias Maraithon.Runtime.RuntimeIncident

  require Logger

  @name __MODULE__
  @day_seconds 86_400

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(opts) do
    state = %{
      user_id: Keyword.get(opts, :user_id) || Config.get(:dogfood_user_id, nil),
      hour: Keyword.get(opts, :hour) || Config.positive_integer(:dogfood_digest_hour, 7),
      minute: Keyword.get(opts, :minute) || Config.get(:dogfood_digest_minute, 30),
      timezone:
        Keyword.get(opts, :timezone) || Config.get(:dogfood_digest_timezone, "America/Toronto"),
      timezone_offset_hours:
        Keyword.get(opts, :timezone_offset_hours) ||
          Config.get(:dogfood_digest_timezone_offset_hours, -4),
      telegram_module: Keyword.get(opts, :telegram_module, Telegram)
    }

    schedule_next(state, DateTime.utc_now())
    {:ok, state}
  end

  @impl true
  def handle_info(:send_digest, state) do
    case deliver(DateTime.utc_now(), state) do
      {:ok, :sent} ->
        Logger.info("Dogfood digest sent", user_id: state.user_id)

      {:ok, :skipped} ->
        :ok

      {:error, reason} ->
        Logger.warning("Dogfood digest failed", reason: inspect(reason), user_id: state.user_id)
    end

    schedule_next(state, DateTime.utc_now())
    {:noreply, state}
  end

  def deliver(now \\ DateTime.utc_now(), opts \\ []) do
    opts = Map.new(opts)
    user_id = Map.get(opts, :user_id) || Config.get(:dogfood_user_id, nil)
    telegram_module = Map.get(opts, :telegram_module, Telegram)

    with {:user_id, user_id} when is_binary(user_id) and user_id != "" <- {:user_id, user_id},
         destination when is_binary(destination) <-
           ConnectedAccounts.telegram_destination(user_id),
         body <- compose(now, Map.put(opts, :user_id, user_id)),
         {:ok, _response} <- telegram_module.send_message(destination, body) do
      {:ok, :sent}
    else
      {:user_id, _} -> {:ok, :skipped}
      nil -> {:ok, :skipped}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def compose(now \\ DateTime.utc_now(), opts \\ []) do
    opts = Map.new(opts)
    since = DateTime.add(now, -@day_seconds, :second)
    incidents = IncidentLog.between(since, now)
    counts = IncidentLog.count_by_kind(incidents)
    segments = IncidentLog.uptime_segments(since, now: now)
    health = Health.check()
    timezone = Map.get(opts, :timezone) || Config.get(:dogfood_digest_timezone, "America/Toronto")
    baseline = latest_boot_baseline(incidents)

    [
      "Chief of Staff daily check",
      "Window: last 24 hours, ending #{format_time(now)} UTC",
      "Local time: #{timezone}",
      "Runtime: #{uptime_line(segments, since, now)}",
      "Incidents: #{counts_line(counts)}",
      crash_lines(incidents),
      "Work still in flight: #{backlog_line(IncidentLog.backlog_snapshot())}",
      baseline && "At last boot: #{backlog_line(baseline)}",
      "Current health: #{health_line(health)}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  def next_fire_after(now, hour, minute, offset_hours) do
    local_now = DateTime.add(now, offset_hours * 3600, :second)
    local_date = DateTime.to_date(local_now)
    local_time = Time.new!(hour, minute, 0)
    target_local = DateTime.new!(local_date, local_time, "Etc/UTC")
    target_utc = DateTime.add(target_local, -offset_hours * 3600, :second)

    if DateTime.compare(target_utc, now) == :gt do
      target_utc
    else
      target_utc
      |> DateTime.add(@day_seconds, :second)
    end
  end

  defp schedule_next(state, now) do
    next_fire =
      next_fire_after(
        now,
        clamp_hour(state.hour),
        clamp_minute(state.minute),
        normalize_offset(state.timezone_offset_hours)
      )

    delay_ms =
      max(DateTime.diff(next_fire, now, :millisecond), 1_000)

    Process.send_after(self(), :send_digest, delay_ms)
  end

  defp latest_boot_baseline(incidents) do
    incidents
    |> Enum.filter(&(&1.kind == "node_boot"))
    |> List.last()
    |> case do
      %RuntimeIncident{metadata: %{"baseline" => baseline}} when is_map(baseline) -> baseline
      _ -> nil
    end
  end

  defp uptime_line([], _since, _now),
    do: "no restart marker in this window; process was already running or telemetry is incomplete"

  defp uptime_line(segments, since, now) do
    window_seconds = max(DateTime.diff(now, since, :second), 1)

    total_seconds =
      segments
      |> Enum.map(&segment_seconds/1)
      |> Enum.sum()

    longest_seconds =
      segments
      |> Enum.map(&segment_seconds/1)
      |> Enum.max(fn -> 0 end)

    "#{percent(total_seconds, window_seconds)}% measured uptime; longest run #{format_duration(longest_seconds)}"
  end

  defp segment_seconds(%{started_at: started_at, ended_at: ended_at}) do
    max(DateTime.diff(ended_at, started_at, :second), 0)
  end

  defp counts_line(counts) when map_size(counts) == 0, do: "none recorded"

  defp counts_line(counts) do
    counts
    |> Enum.sort_by(fn {kind, _count} -> incident_sort_key(kind) end)
    |> Enum.map_join(", ", fn {kind, count} -> counted_incident(kind, count) end)
  end

  defp crash_lines(incidents) do
    crashes =
      incidents
      |> Enum.filter(&(&1.kind == "agent_crash"))
      |> Enum.take(-5)

    if crashes == [] do
      "Agent crashes: none"
    else
      [
        "Agent crashes:",
        crashes
        |> Enum.map_join("\n", fn incident ->
          "- #{format_time(incident.occurred_at)}: #{agent_label(incident)} stopped unexpectedly; #{reason_label(incident.reason)}; #{recovery_outcome(incident, incidents)}."
        end)
      ]
      |> Enum.join("\n")
    end
  end

  defp recovery_outcome(crash, incidents) do
    incidents
    |> Enum.filter(&same_agent_after?(&1, crash))
    |> Enum.find_value("recovery pending", fn
      %RuntimeIncident{kind: "agent_resumed", metadata: metadata} ->
        if metadata["resume_trigger"] == "targeted_reresume" do
          "recovered by the monitor"
        end

      %RuntimeIncident{kind: "agent_stopped_unexpectedly"} ->
        "not recovered after repeated crashes"

      _incident ->
        nil
    end)
  end

  defp same_agent_after?(incident, crash) when is_binary(crash.agent_id) do
    incident.agent_id == crash.agent_id and
      DateTime.compare(incident.occurred_at, crash.occurred_at) == :gt
  end

  defp same_agent_after?(_incident, _crash), do: false

  defp backlog_line(%{"error" => _reason}), do: "could not read the backlog"

  defp backlog_line(snapshot) when is_map(snapshot) do
    rows =
      [
        {"pending_effects", "pending delivery job", "pending delivery jobs"},
        {"failed_effects", "failed delivery job", "failed delivery jobs"},
        {"pending_scheduled_jobs", "scheduled follow-up", "scheduled follow-ups"},
        {"running_agent_runs", "active agent run", "active agent runs"}
      ]
      |> Enum.map(fn {key, singular, plural} ->
        value = Map.get(snapshot, key, 0)
        {value, pluralize(singular, value, plural)}
      end)

    active_rows = Enum.reject(rows, fn {value, _label} -> zero?(value) end)

    if active_rows == [] do
      "none"
    else
      active_rows
      |> Enum.map_join(", ", fn {value, label} -> "#{format_count(value)} #{label}" end)
    end
  end

  defp backlog_line(_snapshot), do: "unavailable"

  defp health_line(%{status: status, checks: checks}) when is_map(checks) do
    database = Map.get(checks, :database) || Map.get(checks, "database")
    agents = Map.get(checks, :agents) || Map.get(checks, "agents") || %{}
    memory = Map.get(checks, :memory_mb) || Map.get(checks, "memory_mb")

    [
      status_label(status),
      "database #{database_label(database)}",
      agent_counts_line(agents),
      memory && "memory #{format_count(memory)} MB"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("; ")
  end

  defp health_line(_health), do: "unavailable"

  defp agent_counts_line(agents) when is_map(agents) do
    running = Map.get(agents, :running) || Map.get(agents, "running") || 0
    degraded = Map.get(agents, :degraded) || Map.get(agents, "degraded") || 0
    stopped = Map.get(agents, :stopped) || Map.get(agents, "stopped") || 0

    "#{format_count(running)} running, #{format_count(degraded)} degraded, #{format_count(stopped)} stopped"
  end

  defp agent_counts_line(_agents), do: nil

  defp counted_incident(kind, count) do
    "#{format_count(count)} #{incident_label(kind, count)}"
  end

  defp incident_label("node_boot", count), do: pluralize("restart", count)
  defp incident_label("node_shutdown", count), do: pluralize("clean shutdown", count)
  defp incident_label("agent_crash", 1), do: "agent crash"
  defp incident_label("agent_crash", _count), do: "agent crashes"
  defp incident_label("agent_resumed", 1), do: "agent recovery"
  defp incident_label("agent_resumed", _count), do: "agent recoveries"
  defp incident_label("agent_stopped_unexpectedly", 1), do: "agent stopped after retries"
  defp incident_label("agent_stopped_unexpectedly", _count), do: "agents stopped after retries"
  defp incident_label("db_outage", count), do: pluralize("database outage", count)
  defp incident_label("db_recovered", 1), do: "database recovery"
  defp incident_label("db_recovered", _count), do: "database recoveries"

  defp incident_label(kind, count) do
    kind
    |> to_string()
    |> String.replace("_", " ")
    |> pluralize(count)
  end

  defp incident_sort_key("node_boot"), do: 0
  defp incident_sort_key("node_shutdown"), do: 1
  defp incident_sort_key("agent_crash"), do: 2
  defp incident_sort_key("agent_resumed"), do: 3
  defp incident_sort_key("agent_stopped_unexpectedly"), do: 4
  defp incident_sort_key("db_outage"), do: 5
  defp incident_sort_key("db_recovered"), do: 6
  defp incident_sort_key(kind), do: to_string(kind)

  defp agent_label(%RuntimeIncident{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("behavior")
    |> behavior_label()
  end

  defp agent_label(_incident), do: "Agent"

  defp behavior_label("ai_chief_of_staff"), do: "Chief of Staff agent"
  defp behavior_label("founder_followthrough_agent"), do: "Follow-through agent"
  defp behavior_label("slack_followthrough_agent"), do: "Slack follow-through agent"

  defp behavior_label(value) when is_binary(value) and value != "" do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
    |> Kernel.<>(" agent")
  end

  defp behavior_label(_value), do: "Agent"

  defp reason_label(nil), do: "cause unavailable"

  defp reason_label(reason) do
    normalized = reason |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, "crash_loop_threshold") ->
        "repeated crashes crossed the recovery limit"

      String.contains?(normalized, "killed") ->
        "process was killed"

      String.contains?(normalized, "timeout") ->
        "timed out"

      String.contains?(normalized, "shutdown") ->
        "shutdown was interrupted"

      true ->
        "cause recorded in runtime incidents"
    end
  end

  defp status_label(:healthy), do: "healthy"
  defp status_label("healthy"), do: "healthy"
  defp status_label(:unhealthy), do: "needs attention"
  defp status_label("unhealthy"), do: "needs attention"
  defp status_label(status), do: to_string(status)

  defp database_label(:ok), do: "reachable"
  defp database_label("ok"), do: "reachable"
  defp database_label(:error), do: "needs attention"
  defp database_label("error"), do: "needs attention"
  defp database_label(value), do: to_string(value)

  defp pluralize(label, 1), do: label
  defp pluralize(label, _count), do: "#{label}s"

  defp pluralize(singular, 1, _plural), do: singular
  defp pluralize(_singular, _count, plural), do: plural

  defp format_count(value) when is_integer(value), do: Integer.to_string(value)
  defp format_count(value), do: to_string(value)

  defp zero?(0), do: true
  defp zero?(_value), do: false

  defp percent(numerator, denominator), do: Float.round(numerator * 100 / denominator, 1)

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{Float.round(seconds / 3600, 1)}h"

  defp format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp clamp_hour(value) when is_integer(value), do: value |> max(0) |> min(23)
  defp clamp_hour(_value), do: 7

  defp clamp_minute(value) when is_integer(value), do: value |> max(0) |> min(59)
  defp clamp_minute(_value), do: 30

  defp normalize_offset(value) when is_integer(value), do: value |> max(-12) |> min(14)
  defp normalize_offset(_value), do: -4
end
