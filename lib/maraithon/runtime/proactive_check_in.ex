defmodule Maraithon.Runtime.ProactiveCheckIn do
  @moduledoc """
  Cloud worker that periodically asks the model whether Telegram needs a check-in.

  The worker only supplies cadence and batching. The proactive assistant harness
  decides whether to send or hold each candidate check-in.
  """

  use GenServer

  alias Maraithon.Runtime.Config
  alias Maraithon.TelegramAssistant.Proactive

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

  @impl true
  def init(_opts) do
    state = %{
      interval_ms: Config.positive_integer(:proactive_check_in_interval_ms, @default_interval_ms),
      batch_size: Config.positive_integer(:proactive_check_in_batch_size, @default_batch_size)
    }

    schedule_tick(10_000)
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

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Proactive Telegram check-in cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end
end
