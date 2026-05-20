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
    incidents = IncidentLog.since(since)
    counts = IncidentLog.count_by_kind(incidents)
    segments = IncidentLog.uptime_segments(since, now: now)
    health = Health.check()
    timezone = Map.get(opts, :timezone) || Config.get(:dogfood_digest_timezone, "America/Toronto")
    baseline = latest_boot_baseline(incidents)

    [
      "Chief of Staff dogfood digest",
      "Window: trailing 24h ending #{format_time(now)} UTC",
      "Timezone: #{timezone}",
      "Uptime: #{uptime_line(segments, since, now)}",
      "Incidents: #{counts_line(counts)}",
      crash_lines(incidents),
      "Backlog now: #{backlog_line(IncidentLog.backlog_snapshot())}",
      baseline && "Last boot baseline: #{backlog_line(baseline)}",
      "Health: #{health.status}; DB #{health.checks.database}; agents #{inspect(health.checks.agents)}"
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

  defp uptime_line([], _since, _now), do: "unknown (no node_boot in window)"

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

    "#{percent(total_seconds, window_seconds)}% (longest #{format_duration(longest_seconds)})"
  end

  defp segment_seconds(%{started_at: started_at, ended_at: ended_at}) do
    max(DateTime.diff(ended_at, started_at, :second), 0)
  end

  defp counts_line(counts) when map_size(counts) == 0, do: "none"

  defp counts_line(counts) do
    counts
    |> Enum.sort_by(fn {kind, _count} -> kind end)
    |> Enum.map_join(", ", fn {kind, count} -> "#{kind}=#{count}" end)
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
          "- #{format_time(incident.occurred_at)} #{incident.agent_id}: #{incident.reason || "unknown"}"
        end)
      ]
      |> Enum.join("\n")
    end
  end

  defp backlog_line(snapshot) when is_map(snapshot) do
    snapshot
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)
  end

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
