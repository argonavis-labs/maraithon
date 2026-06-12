defmodule Maraithon.AssistantChat.RunRecovery do
  @moduledoc """
  Recovers mobile assistant runs stranded by restarts.

  Queued runs are dispatched as in-memory casts to per-conversation
  workers; a deploy between enqueue and execution loses the cast while the
  queued run row survives. This sweeper re-dispatches stale queued runs
  (idempotently — `run_queued_request` skips runs that already advanced)
  and fails runs stuck "running" far past every server-side wall clock so
  conversations never wedge.
  """

  use GenServer

  import Ecto.Query

  alias Maraithon.AssistantChat.ThreadWorker
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramConversations.Turn

  require Logger

  @sweep_interval :timer.seconds(60)
  # Old enough that the original cast is certainly gone, young enough that
  # a late answer is still the answer the user asked for.
  @queued_grace_seconds 90
  @queued_max_age_hours 2
  # Every in-run wall clock is well under this.
  @running_timeout_minutes 15

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @doc "Runs one recovery pass. Exposed for ops use."
  def sweep do
    recovered = recover_stale_queued_runs()
    expired = expire_ancient_queued_runs()
    failed = fail_stuck_running_runs()

    if recovered > 0 or failed > 0 or expired > 0 do
      Logger.info("Assistant run recovery sweep",
        recovered_queued: recovered,
        expired_queued: expired,
        failed_stuck_running: failed
      )
    end

    %{recovered: recovered, expired: expired, failed: failed}
  end

  defp recover_stale_queued_runs do
    grace_cutoff = seconds_ago(@queued_grace_seconds)
    age_cutoff = seconds_ago(@queued_max_age_hours * 3600)

    Run
    |> where([r], r.surface == "mobile" and r.status == "queued")
    |> where([r], r.inserted_at < ^grace_cutoff and r.inserted_at > ^age_cutoff)
    |> order_by(asc: :inserted_at)
    |> limit(10)
    |> Repo.all()
    |> Enum.count(fn run ->
      case user_turn_for(run) do
        %Turn{} = turn ->
          Logger.warning("Re-dispatching stranded queued assistant run",
            run_id: run.id,
            conversation_id: run.conversation_id,
            queued_at: run.inserted_at
          )

          :ok ==
            ThreadWorker.enqueue(%{
              run_id: run.id,
              conversation_id: run.conversation_id,
              user_turn_id: turn.id
            })

        _ ->
          _ = TelegramAssistant.fail_run(run, :queued_run_unrecoverable, "failed")
          false
      end
    end)
  end

  # The user turn that triggered a queued run is the newest user turn in its
  # conversation at enqueue time (runs are created in the same transaction
  # breath as the turn, and a conversation has one queued run at a time).
  defp user_turn_for(%Run{} = run) do
    slack = DateTime.add(run.inserted_at, 2, :second)

    Turn
    |> where([t], t.conversation_id == ^run.conversation_id and t.role == "user")
    |> where([t], t.inserted_at <= ^slack)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp expire_ancient_queued_runs do
    age_cutoff = seconds_ago(@queued_max_age_hours * 3600)

    Run
    |> where([r], r.surface == "mobile" and r.status == "queued")
    |> where([r], r.inserted_at <= ^age_cutoff)
    |> limit(25)
    |> Repo.all()
    |> Enum.count(fn run ->
      match?({:ok, _}, TelegramAssistant.fail_run(run, :queued_run_expired, "failed"))
    end)
  end

  defp fail_stuck_running_runs do
    cutoff = seconds_ago(@running_timeout_minutes * 60)

    Run
    |> where([r], r.surface == "mobile" and r.status == "running")
    |> where([r], r.started_at < ^cutoff)
    |> limit(25)
    |> Repo.all()
    |> Enum.count(fn run ->
      Logger.warning("Failing assistant run stuck in running",
        run_id: run.id,
        started_at: run.started_at
      )

      match?({:ok, _}, TelegramAssistant.fail_run(run, :run_lost_after_restart, "degraded"))
    end)
  end

  defp seconds_ago(seconds) do
    DateTime.add(DateTime.utc_now(), -seconds, :second)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end
end
