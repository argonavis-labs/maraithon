defmodule Maraithon.AssistantChat.RunRecovery do
  @moduledoc """
  Bounded repair for accepted assistant requests and legacy orphan runs.

  The recurring cadence is a backstop. New requests already have a durable
  job. Recovery uses the source turn's persisted run identity, never temporal
  proximity, and leaves owned or termination-pending work to the job runtime.
  """

  import Ecto.Query

  alias Maraithon.AssistantChat.{Execution, ThreadWorker}
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramConversations.Turn

  require Logger

  # Old enough that the original cast is certainly gone, young enough that
  # a late answer is still the answer the user asked for.
  @queued_grace_seconds 90
  @queued_max_age_hours 2
  # Every in-run wall clock is well under this.
  @running_timeout_minutes 15

  @doc "Runs one recovery pass. Exposed for ops use and durable recurring jobs."
  def run_once, do: sweep()

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
    |> Enum.reject(&Execution.job_active?(&1.id))
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
          _ = fail_if_unowned(run, :queued_run_source_missing, "failed")
          false
      end
    end)
  end

  defp user_turn_for(%Run{} = run) do
    Turn
    |> where([t], t.conversation_id == ^run.conversation_id and t.role == "user")
    |> where([t], t.assistant_run_id == ^run.id)
    |> limit(2)
    |> Repo.all()
    |> case do
      [turn] -> Turn.hydrate(turn)
      _ -> nil
    end
  end

  defp expire_ancient_queued_runs do
    age_cutoff = seconds_ago(@queued_max_age_hours * 3600)

    Run
    |> where([r], r.surface == "mobile" and r.status == "queued")
    |> where([r], r.inserted_at <= ^age_cutoff)
    |> limit(25)
    |> Repo.all()
    |> Enum.count(fn run ->
      match?({:ok, _}, fail_if_unowned(run, :queued_run_expired, "failed"))
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

      match?({:ok, _}, fail_if_unowned(run, :run_lost_after_restart, "degraded"))
    end)
  end

  defp fail_if_unowned(run, reason, status) do
    # Enqueue takes this same privacy/user lock. Recheck status and ownership
    # under the lock so a stale sweep cannot fail newly accepted/owned work.
    case Repo.transaction(fn ->
           _ = Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(run.user_id)
           current = Repo.one(from r in Run, where: r.id == ^run.id, lock: "FOR UPDATE")

           if current && current.status == run.status && current.started_at == run.started_at &&
                not Execution.job_active?(run.id) do
             TelegramAssistant.fail_run(current, reason, status)
           else
             {:error, :run_advanced_or_owned}
           end
         end) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp seconds_ago(seconds) do
    DateTime.add(DateTime.utc_now(), -seconds, :second)
  end
end
