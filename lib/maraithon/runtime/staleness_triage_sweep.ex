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

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Runtime.Config
  alias Maraithon.Todos.StalenessTriage
  alias Maraithon.Todos.Todo

  require Logger

  @name __MODULE__
  @default_interval_ms :timer.hours(24)
  @open_statuses ~w(open snoozed)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Runs one full sweep synchronously (directly callable in tests, no timer).
  """
  def run_once(opts \\ []) do
    user_ids =
      case Keyword.get(opts, :user_ids) do
        user_ids when is_list(user_ids) ->
          user_ids

        _other ->
          # Same user-enumeration pattern as CrossSourceCompletion.run_for_all_users/1:
          # every user with open todos, no cap — a capped enumeration with no
          # rotation would starve users past the cutoff forever, and user
          # counts are small.
          Repo.all(
            from(t in Todo,
              where: t.status in @open_statuses,
              distinct: true,
              select: t.user_id
            )
          )
      end
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    empty = %{users: length(user_ids), proposed: 0, skipped: 0, errors: 0}

    Enum.reduce(user_ids, empty, fn user_id, acc ->
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
          user_id: user_id,
          reason: inspect(reason)
        )

        error

      other ->
        other
    end
  rescue
    error ->
      Logger.info("Staleness triage crashed for user",
        user_id: user_id,
        reason: Exception.message(error)
      )

      {:error, error}
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

    state = %{interval_ms: interval_ms}

    schedule_tick(initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    summary = run_once()

    if summary.proposed > 0 or summary.errors > 0 do
      Logger.info("Staleness triage sweep cycle",
        users: summary.users,
        proposed: summary.proposed,
        skipped: summary.skipped,
        errors: summary.errors
      )
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Staleness triage sweep cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end
end
