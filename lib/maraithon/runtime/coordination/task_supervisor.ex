defmodule Maraithon.Runtime.Coordination.TaskSupervisor do
  @moduledoc "Coupled proof authority and Task.Supervisor for coordinated jobs."
  use Supervisor

  @task_supervisor Maraithon.Runtime.BackgroundJobTaskSupervisor
  @registry Maraithon.Runtime.Coordination.TaskRegistry

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def task_supervisor, do: @task_supervisor

  def reserve(work_kind, work_id, claim_token, assignment_id),
    do:
      Maraithon.Runtime.Coordination.TaskAuthority.reserve(
        work_kind,
        work_id,
        claim_token,
        assignment_id
      )

  def release(identity), do: Maraithon.Runtime.Coordination.TaskAuthority.release(identity)

  def register_current!(identity) do
    :ok = Maraithon.Runtime.Coordination.TaskAuthority.activate(identity)
    {:ok, _} = Registry.register(@registry, registry_key(identity), identity)
    :ok
  end

  def terminate_exact(identity),
    do: Maraithon.Runtime.Coordination.TaskAuthority.terminate_exact(identity)

  def registry_key(identity),
    do:
      {identity.assignment_id, identity.claim_token, identity.supervisor_id,
       identity.local_task_id}

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: @registry},
        Maraithon.Runtime.Coordination.TaskAuthority,
        {Task.Supervisor, name: @task_supervisor}
      ],
      strategy: :one_for_all,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
