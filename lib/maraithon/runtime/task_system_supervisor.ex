defmodule Maraithon.Runtime.TaskSystemSupervisor do
  @moduledoc """
  Keeps the physical-task guardian outside both coupled task groups.

  `:rest_for_one` makes guardian loss synchronously terminate both downstream
  groups and every task they supervise. A nested group restart does not restart
  the guardian, so its exact monitor observations survive crash convergence.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        Maraithon.Runtime.TaskGuardian,
        Maraithon.Runtime.EffectTaskSupervisor,
        Maraithon.Runtime.Coordination.TaskSupervisor
      ],
      strategy: :rest_for_one,
      max_restarts: 20,
      max_seconds: 60
    )
  end
end
