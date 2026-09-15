defmodule Maraithon.Runtime.JobAuthority do
  @moduledoc "Shared transaction fence for durable background work. Never wraps provider I/O."
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.Coordination.{Scope, TaskAssignment, TaskClaims}

  def transaction(%BackgroundJob{} = job, fun, opts \\ []) when is_function(fun, 0) do
    Repo.transaction(fn ->
      fence!(job, opts)
      if job.user_id, do: WriteFence.lock_user_writable!(job.user_id)
      fun.()
    end)
  end

  def fence!(%BackgroundJob{} = job, opts \\ []) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "job authority requires a transaction")

    if job.coordination_task_assignment_id do
      case Repo.get(TaskAssignment, job.coordination_task_assignment_id) do
        %TaskAssignment{work_kind: "background_job", work_id: id, claim_token: token} = assignment
        when id == job.id and token == job.claim_token ->
          TaskClaims.fence_running!(assignment)

        _ ->
          Repo.rollback(:task_authority_lost)
      end
    else
      if Keyword.get(opts, :required, true) or Scope.enabled?(),
        do: Repo.rollback(:task_authority_required)
    end

    owned =
      Repo.one(
        from j in BackgroundJob,
          where: j.id == ^job.id and j.claim_token == ^job.claim_token and j.status == "running",
          select: j.id,
          lock: "FOR SHARE"
      )

    if is_nil(owned), do: Repo.rollback(:claim_lost)
    :ok
  end
end
