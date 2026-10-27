defmodule Maraithon.Runtime.HealthReporter do
  @moduledoc """
  Periodic health reporting and metrics collection.
  """

  use GenServer
  require Logger

  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.Snapshot

  # Every minute
  @default_report_interval_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    report_interval_ms =
      RuntimeConfig.positive_integer(:health_report_interval_ms, @default_report_interval_ms)

    schedule_report(report_interval_ms)
    {:ok, %{report_interval_ms: report_interval_ms}}
  end

  @impl true
  def handle_info(:report, state) do
    report_health()
    schedule_report(state.report_interval_ms)
    {:noreply, state}
  end

  defp report_health do
    health = Maraithon.Health.check()
    snapshot_stats = snapshot_stats(health.checks.database)

    Logger.info("Health report",
      status: health.status,
      agents_running: health.checks.agents.running,
      agents_degraded: health.checks.agents.degraded,
      memory_mb: health.checks.memory_mb,
      uptime_seconds: health.checks.uptime_seconds,
      snapshot_count: snapshot_stats.retained_snapshot_count,
      snapshot_bytes: snapshot_stats.retained_encoded_bytes,
      agents_without_snapshot: snapshot_stats.active_agents_without_snapshot,
      max_checkpoint_age_ms: snapshot_stats.max_checkpoint_age_ms,
      max_snapshot_bytes: snapshot_stats.max_latest_encoded_bytes
    )
  end

  defp snapshot_stats(:ok) do
    case Snapshot.emit_health_telemetry() do
      {:ok, stats} -> stats
      {:error, _reason} -> empty_snapshot_stats()
    end
  rescue
    _error -> empty_snapshot_stats()
  end

  defp snapshot_stats(_database_status), do: empty_snapshot_stats()

  defp empty_snapshot_stats do
    %{
      retained_snapshot_count: 0,
      retained_encoded_bytes: 0,
      active_agents_without_snapshot: 0,
      max_checkpoint_age_ms: 0,
      max_latest_encoded_bytes: 0
    }
  end

  defp schedule_report(interval_ms) do
    Process.send_after(self(), :report, interval_ms)
  end
end
