defmodule Maraithon.Runtime.StalenessTriageSweep do
  @moduledoc """
  Daily tick that runs the batched staleness triage per user (SPEC 05 R14).

  The tick itself is daily, but `StalenessTriage.run_for_user/2` refuses to
  build a card for any user who received one within the last 6 days, so users
  stagger naturally into a weekly-ish cadence instead of all firing in
  lockstep on a global weekly timer. Mirrors `TodoCompletionSweep` exactly in
  structure: `Process.send_after` scheduling where the next tick is armed
  only after the current one completes (overlapping ticks can never stack),
  and a rescue around the tick body so one failure never breaks the cadence.
  """

  use GenServer

  alias Maraithon.Runtime.Config
  alias Maraithon.Todos.StalenessTriage
  alias Maraithon.Todos.UserBatch

  require Logger

  @name __MODULE__
  @default_interval_ms :timer.hours(24)
  @max_interval_ms :timer.hours(24)
  @cursor_key "staleness_triage_sweep"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Runs one full sweep synchronously (directly callable in tests, no timer).
  """
  def run_once(opts \\ []) do
    user_ids = UserBatch.open_todo_user_ids(opts)

    empty = %{users: length(user_ids), proposed: 0, skipped: 0, errors: 0}

    user_ids
    |> Enum.reduce(empty, fn user_id, acc ->
      case run_for_user_safely(user_id, opts) do
        {:ok, %{sent: true}} -> %{acc | proposed: acc.proposed + 1}
        {:ok, _held} -> %{acc | skipped: acc.skipped + 1}
        {:skip, _reason} -> %{acc | skipped: acc.skipped + 1}
        {:error, _reason} -> %{acc | errors: acc.errors + 1}
      end
    end)
  end

  # One user's failure/crash must never block the sweep for the others, and
  # must never be silently swallowed (SPEC 05 silent-failure rule).
  defp run_for_user_safely(user_id, opts) do
    triage_opts = Keyword.take(opts, [:now, :llm_complete, :llm_timeout_ms, :push_deliver])

    case StalenessTriage.run_for_user(user_id, triage_opts) do
      {:error, reason} = error ->
        Logger.info("Staleness triage failed for user",
          user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        error

      other ->
        other
    end
  rescue
    error ->
      failure_code = Maraithon.Redaction.error_class(error)

      Logger.info("Staleness triage crashed for user",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: failure_code
      )

      {:error, failure_code}
  end

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get(
        opts,
        :interval_ms,
        Config.positive_integer(:staleness_triage_sweep_interval_ms, @default_interval_ms)
      )

    initial_delay_ms =
      Keyword.get(
        opts,
        :initial_delay_ms,
        Config.positive_integer(:staleness_triage_sweep_initial_delay_ms, interval_ms)
      )

    interval_ms = min(positive_integer(interval_ms, @default_interval_ms), @max_interval_ms)
    initial_delay_ms = min(positive_integer(initial_delay_ms, interval_ms), @max_interval_ms)
    state = %{interval_ms: interval_ms, user_cursor: UserBatch.load_cursor(@cursor_key)}

    schedule_tick(initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    user_ids = UserBatch.open_todo_user_ids(after_user_id: state.user_cursor)
    summary = run_once(user_ids: user_ids)

    if summary.proposed > 0 or summary.errors > 0 do
      Logger.info("Staleness triage sweep cycle",
        users: summary.users,
        proposed: summary.proposed,
        skipped: summary.skipped,
        errors: summary.errors
      )
    end

    next_cursor = List.last(user_ids) || state.user_cursor
    if is_binary(next_cursor), do: UserBatch.record_cursor(@cursor_key, next_cursor)

    schedule_tick(state.interval_ms)
    {:noreply, %{state | user_cursor: next_cursor}}
  rescue
    error ->
      Logger.warning("Staleness triage sweep cycle failed",
        failure_code: Maraithon.Redaction.error_class(error)
      )

      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, min(delay_ms, @max_interval_ms))
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
