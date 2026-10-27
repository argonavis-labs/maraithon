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

  def bind_task(identity, task_pid),
    do: Maraithon.Runtime.Coordination.TaskAuthority.bind_task(identity, task_pid)

  def release(identity), do: Maraithon.Runtime.Coordination.TaskAuthority.release(identity)

  def authorize_activation(identity) do
    Maraithon.Runtime.Coordination.TaskAuthority.authorize_activation(identity)
  catch
    :exit, _reason -> {:error, :task_supervisor_unavailable}
  end

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
        {Task.Supervisor, name: @task_supervisor},
        Maraithon.Runtime.Coordination.TaskAuthority
      ],
      strategy: :one_for_all,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
