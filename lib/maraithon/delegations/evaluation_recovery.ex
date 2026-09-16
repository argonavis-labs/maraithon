defmodule Maraithon.Delegations.EvaluationRecovery do
  @moduledoc "Resume controlled eval reads without replacing their frozen message identities."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo}
  alias Maraithon.Delegations.{Evaluation, Gates, Preferences}
  alias Maraithon.Runtime.{BackgroundJob, DatabaseClock, PeriodicJobs}
  alias Maraithon.Runtime.Coordination.TaskAssignment
  alias Maraithon.Todos.Todo

  def wait(state, reason) do
    case PeriodicJobs.retry_after_seconds_for(reason) do
      {:ok, seconds} ->
        {:ok, Map.put(state, "phase", "waiting_for_provider"),
         {:reschedule_in, max(seconds, 30) * 1_000}}

      :none ->
        nil
    end
  end

  @doc "Recover only an initial rate-limit failure before any delegation was created."
  def resume(id) do
    user = Evaluation.scenarios()["owner"]["email"]

    with {:ok, id} <- Ecto.UUID.cast(id),
         true <- Gates.sends_enabled?(user, "gmail"),
         true <- Application.get_env(:maraithon, :delegation_eval_only, false) == true do
      Repo.transaction(fn ->
        Maraithon.DurablePayload.require_current_mutation!()
        Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(user)

        job =
          Repo.one(
            from j in BackgroundJob,
              where: j.id == ^id and j.user_id == ^user and j.job_type == "delegation_eval",
              lock: "FOR UPDATE"
          )
          |> BackgroundJob.hydrate_payloads()

        unless job && get_in(job.payload, ["scenario", "id"]) == "durable_memory",
          do: Repo.rollback(:controlled_canary_required)

        if job.status in ~w(pending running) do
          report(job)
        else
          recover!(job, user)
        end
      end)
    else
      _ -> {:error, :controlled_canary_required}
    end
  end

  defp recover!(job, user) do
    now = DatabaseClock.now!()
    todo = Repo.get_by(Todo, user_id: user, dedupe_key: "delegation-eval:#{job.id}")

    settled? =
      is_binary(job.coordination_task_assignment_id) and Repo.exists?(
        from a in TaskAssignment,
          where: a.id == ^job.coordination_task_assignment_id and a.work_id == ^job.id,
          where: a.work_kind == "background_job" and a.state == "settled"
      ) and
        not Repo.exists?(
          from a in TaskAssignment,
            where: a.work_id == ^job.id and a.work_kind == "background_job",
            where: a.state != "settled"
        )

    due = now |> DateTime.add(30, :second) |> Preferences.next_work_time(Preferences.get(user))

    with "completed" <- job.status,
         nil <- job.claim_token,
         %{"phase" => "failed", "reason" => "rate_limited"} <- job.result,
         nil <- job.result["delegation_id"],
         nil <- if(todo, do: Delegations.for_todo(user, todo.id)),
         true <- settled?,
         {:ok, deadline, _} <- DateTime.from_iso8601(job.payload["deadline"]),
         :gt <- DateTime.compare(deadline, due) do
      job
      |> BackgroundJob.changeset(%{
        status: "pending",
        scheduled_at: due,
        completed_at: nil,
        attempts: 0,
        result: %{
          "phase" => "waiting_for_provider",
          "recovered_initial_rate_limit" => true,
          "recovered_at" => DateTime.to_iso8601(now)
        }
      })
      |> Repo.update!()
      |> report()
    else
      _ -> Repo.rollback(:initial_rate_limit_recovery_unavailable)
    end
  end

  defp report(job),
    do: %{job_id: job.id, phase: job.result["phase"], scheduled_at: job.scheduled_at}
end
