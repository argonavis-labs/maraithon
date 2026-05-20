defmodule Maraithon.Runtime.ProactiveCheckIn do
  @moduledoc """
  Cloud worker that periodically asks the model whether Telegram needs a check-in.

  The worker only supplies cadence and batching. The proactive assistant harness
  decides whether to send or hold each candidate check-in.
  """

  use GenServer

  alias Maraithon.Proactive.LocalPatterns
  alias Maraithon.Runtime.Config
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.DeliveryPlanner
  alias Maraithon.TelegramAssistant.Proactive
  alias Maraithon.TelegramAssistant.ProactiveQueue

  require Logger

  @name __MODULE__
  @default_interval_ms :timer.minutes(10)
  @default_batch_size 25

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def run_once(opts \\ []) do
    Proactive.deliver_due_check_ins(opts)
  end

  def run_delivery_planner(opts \\ []) do
    if TelegramAssistant.proactive_delivery_planner_enabled?() do
      DeliveryPlanner.run_for_due_users(opts)
    else
      :disabled
    end
  end

  def expire_stale_candidates(now \\ DateTime.utc_now()) do
    ProactiveQueue.expire_stale(now)
  end

  @impl true
  def init(_opts) do
    interval_ms = Config.positive_integer(:proactive_check_in_interval_ms, @default_interval_ms)

    state = %{
      interval_ms: interval_ms,
      initial_delay_ms:
        Config.positive_integer(:proactive_check_in_initial_delay_ms, interval_ms),
      batch_size: Config.positive_integer(:proactive_check_in_batch_size, @default_batch_size)
    }

    schedule_tick(state.initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    result = run_once(batch_size: state.batch_size)

    if result.sent > 0 or result.held > 0 or result.failed > 0 do
      Logger.info("Proactive Telegram check-in cycle",
        sent: result.sent,
        held: result.held,
        suppressed: result.suppressed,
        failed: result.failed
      )
    end

    run_local_pattern_detectors()
    expired = maybe_expire_stale_candidates()
    planner_result = run_delivery_planner(batch_size: state.batch_size)
    log_delivery_planner_cycle(planner_result, expired)

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Proactive Telegram check-in cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  defp run_local_pattern_detectors do
    summary = LocalPatterns.run_for_all_users()
    detector_total = Enum.sum(Enum.map(detector_keys(), &Map.get(summary, &1, 0)))

    if detector_total > 0 do
      Logger.info("Local-pattern detectors emitted insights",
        users: Map.get(summary, :user_count, 0),
        total: detector_total,
        cold_thread: Map.get(summary, :cold_thread, 0),
        dropped_commitment: Map.get(summary, :dropped_commitment, 0),
        untranscribed_memo: Map.get(summary, :untranscribed_memo, 0),
        note_follow_up: Map.get(summary, :note_follow_up, 0),
        calendar_conflict: Map.get(summary, :calendar_conflict, 0),
        file_mention: Map.get(summary, :file_mention, 0)
      )
    end

    :ok
  rescue
    error ->
      Logger.warning("Local-pattern detector cycle failed",
        reason: Exception.message(error)
      )

      :ok
  end

  defp detector_keys do
    [
      :cold_thread,
      :dropped_commitment,
      :untranscribed_memo,
      :note_follow_up,
      :calendar_conflict,
      :file_mention
    ]
  end

  defp maybe_expire_stale_candidates do
    if TelegramAssistant.proactive_delivery_planner_enabled?() do
      expire_stale_candidates()
    else
      0
    end
  end

  defp log_delivery_planner_cycle(:disabled, _expired), do: :ok

  defp log_delivery_planner_cycle(%{} = result, expired) do
    if result.planned > 0 or result.delivered > 0 or result.held > 0 or result.failed > 0 or
         expired > 0 do
      Logger.info("Proactive delivery planner cycle",
        users: result.users,
        planned: result.planned,
        interrupt_now: result.interrupt_now,
        digest: result.digest,
        held: result.held,
        delivered: result.delivered,
        failed: result.failed,
        expired: expired
      )
    end

    :ok
  end

  defp log_delivery_planner_cycle(_result, _expired), do: :ok

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end
end
