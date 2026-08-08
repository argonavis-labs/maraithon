defmodule Maraithon.Runtime.ProactiveCheckIn do
  @moduledoc """
  Cloud worker that periodically asks the model whether Telegram needs a check-in.

  The worker only supplies cadence and batching. The proactive assistant harness
  decides whether to send or hold each candidate check-in.

  SPEC 04 R6: this worker is delivery-side plumbing only (dispatching
  already-decided check-ins and running the budget-enforced delivery
  planner) — it does not run any candidate-generation/intelligence pipeline
  of its own. `Maraithon.Proactive.LocalPatterns` detection now happens
  inside `Maraithon.ChiefOfStaff.Skills.LocalPatternReview`, a normal skill
  in the supervised Chief of Staff wakeup cycle, so the 10-15 minute model
  wakeup is the single always-on intelligence loop.
  """

  use GenServer

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

    if result.sent > 0 or result.held > 0 or result.suppressed > 0 or result.failed > 0 or
         result.disabled > 0 do
      Logger.log(cycle_log_level(result), "Proactive Telegram check-in cycle",
        sent: result.sent,
        held: result.held,
        suppressed: result.suppressed,
        failed: result.failed,
        disabled: result.disabled
      )
    end

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
      Logger.log(cycle_log_level(result), "Proactive delivery planner cycle",
        user_count: result.users,
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

  defp cycle_log_level(%{failed: failed}) when is_integer(failed) and failed > 0, do: :warning
  defp cycle_log_level(_result), do: :info

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end
end
