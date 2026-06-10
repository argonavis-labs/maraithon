defmodule Maraithon.Runtime.TodoCompletionSweep do
  @moduledoc """
  Periodically runs the deterministic todo completion sweep.
  """

  use GenServer

  alias Maraithon.Runtime.Config
  alias Maraithon.Todos.{CompletionSweep, CrossSourceCompletion}

  require Logger

  @name __MODULE__
  @default_interval_ms :timer.minutes(30)
  @default_batch_size 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  def run_once(opts \\ []) do
    CompletionSweep.run_for_all_users(opts)
  end

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get(
        opts,
        :interval_ms,
        Config.positive_integer(:todo_completion_sweep_interval_ms, @default_interval_ms)
      )

    initial_delay_ms =
      Keyword.get(
        opts,
        :initial_delay_ms,
        Config.positive_integer(:todo_completion_sweep_initial_delay_ms, interval_ms)
      )

    state = %{
      interval_ms: interval_ms,
      initial_delay_ms: initial_delay_ms,
      user_limit:
        Keyword.get(
          opts,
          :user_limit,
          Config.positive_integer(:todo_completion_sweep_user_limit, @default_batch_size)
        )
    }

    schedule_tick(state.initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    summary = run_once(user_limit: state.user_limit)

    if summary.completed > 0 or summary.errors > 0 or summary.fetch_errors > 0 do
      Logger.info("Todo completion sweep cycle",
        users: summary.users,
        checked: summary.checked,
        completed: summary.completed,
        errors: summary.errors,
        fetch_errors: summary.fetch_errors,
        completed_by_source: inspect(summary.completed_by_source),
        completed_by_reason: inspect(summary.completed_by_reason)
      )
    end

    run_cross_source_pass(state.user_limit)

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Todo completion sweep cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  # Cross-channel LLM pass after the deterministic sweep. Failures here must
  # never break the sweep cadence, so everything is rescued.
  defp run_cross_source_pass(user_limit) do
    summary = CrossSourceCompletion.run_for_all_users(user_limit: user_limit)

    if summary.completed > 0 or summary.errors > 0 do
      Logger.info("Cross-source completion cycle",
        users: summary.users,
        checked: summary.checked,
        completed: summary.completed,
        skipped: summary.skipped,
        errors: summary.errors
      )
    end
  rescue
    error ->
      Logger.warning("Cross-source completion cycle failed",
        reason: Exception.message(error)
      )
  end

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end
end
