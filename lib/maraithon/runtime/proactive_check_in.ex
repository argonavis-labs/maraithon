defmodule Maraithon.Runtime.ProactiveCheckIn do
  @moduledoc """
  Cloud worker that expires queued proactive candidates and runs the bounded
  Telegram delivery planner on a fixed cadence.

  Candidate generation belongs to the supervised Chief-of-Staff cycle. This
  worker only decides how already-generated candidates should be delivered.

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
  alias Maraithon.TelegramAssistant.ProactiveQueue

  require Logger

  @name __MODULE__
  @default_interval_ms :timer.minutes(10)
  @default_batch_size 25

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def run_once(opts \\ []) do
    recovered = ProactiveQueue.recover_stale_planned()
    expired = maybe_expire_stale_candidates()
    planner = run_delivery_planner(opts)

    planner
    |> compatibility_summary()
    |> Map.merge(%{expired: expired, recovered: recovered, planner: planner})
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

  defp compatibility_summary(%{} = planner) do
    %{
      sent: Map.get(planner, :delivered, 0),
      held: Map.get(planner, :held, 0),
      suppressed: 0,
      failed: Map.get(planner, :failed, 0),
      disabled: 0
    }
  end

  defp compatibility_summary(_planner) do
    %{sent: 0, held: 0, suppressed: 0, failed: 0, disabled: 0}
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
    log_delivery_planner_cycle(result.planner, result.expired, result.recovered)

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Proactive delivery planner worker cycle failed",
        failure_code: "worker_exception",
        error: error.__struct__
      )

      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  defp maybe_expire_stale_candidates, do: expire_stale_candidates()

  defp log_delivery_planner_cycle(:disabled, expired, recovered)
       when expired > 0 or recovered > 0 do
    Logger.info("Proactive queue hygiene cycle", expired: expired, recovered: recovered)
  end

  defp log_delivery_planner_cycle(:disabled, _expired, _recovered), do: :ok

  defp log_delivery_planner_cycle(%{} = result, expired, recovered) do
    if result.planned > 0 or result.delivered > 0 or result.delivery_unknown > 0 or
         result.held > 0 or result.failed > 0 or result.undeliverable > 0 or expired > 0 or
         recovered > 0 do
      level =
        if result.failed > 0 or result.delivery_unknown > 0,
          do: :warning,
          else: :info

      Logger.log(level, "Proactive delivery planner cycle",
        users: result.users,
        planned: result.planned,
        interrupt_now: result.interrupt_now,
        digest: result.digest,
        held: result.held,
        delivered: result.delivered,
        delivery_unknown: result.delivery_unknown,
        failed: result.failed,
        undeliverable: result.undeliverable,
        failure_codes: result.failure_codes,
        expired: expired,
        recovered: recovered
      )
    end

    :ok
  end

  defp log_delivery_planner_cycle(_result, _expired, _recovered), do: :ok

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end
end
