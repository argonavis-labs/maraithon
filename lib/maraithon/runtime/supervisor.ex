defmodule Maraithon.Runtime.Supervisor do
  @moduledoc """
  Top-level supervisor for the Maraithon runtime.
  """

  use Supervisor

  alias Maraithon.Runtime.BootGate
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.PeriodicJobs

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    background_workers? = Application.get_env(:maraithon, :start_background_workers, true)
    if background_workers?, do: BootGate.close(), else: BootGate.open()

    agent_supervisor =
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Maraithon.Runtime.AgentSupervisor,
       max_restarts: 20,
       max_seconds: 60}

    dependency_children = [
      {Registry, keys: :unique, name: Maraithon.Runtime.AgentRegistry},
      {Task.Supervisor, name: Maraithon.Runtime.EffectSupervisor},
      Maraithon.Runtime.EffectTaskSupervisor,
      {Task.Supervisor, name: Maraithon.Runtime.ToolCallSupervisor},
      Maraithon.Runtime.Effects.LLMRateLimiter,
      {Task.Supervisor, name: Maraithon.Runtime.BackgroundJobTaskSupervisor},
      {Task.Supervisor, name: Maraithon.Runtime.AgentRecoveryTaskSupervisor}
    ]

    children =
      if background_workers? do
        dependency_children ++
          [
            # EffectRunner starts closed behind BootGate. Keeping it before the
            # Agent supervisor means Agents terminate and fence their outbox
            # work while the runner is still alive during reverse-order stop.
            Maraithon.Runtime.EffectRunner,
            agent_supervisor,
            # Exact owners are temporary children. The watcher must be online
            # before Bootstrap or any producer can spawn an Agent.
            Maraithon.Runtime.AgentWatcher,
            Maraithon.Runtime.WakeCoordinator,
            Maraithon.Runtime.Bootstrap,
            Supervisor.child_spec(
              {Maraithon.Runtime.BackgroundJobRunner,
               exclude_queues: [PeriodicJobs.provider_queue(), PeriodicJobs.model_queue()]},
              id: Maraithon.Runtime.BackgroundJobRunner
            ),
            Supervisor.child_spec(
              {Maraithon.Runtime.BackgroundJobRunner,
               name: Maraithon.Runtime.ProviderBackgroundJobRunner,
               queues: [PeriodicJobs.provider_queue()],
               fair?: true,
               max_concurrency: Config.positive_integer(:provider_job_max_concurrency, 4),
               max_partition_concurrency: 1,
               max_rate_limit_concurrency: 1,
               reconcile_recurring_jobs?: false},
              id: Maraithon.Runtime.ProviderBackgroundJobRunner
            ),
            Supervisor.child_spec(
              {Maraithon.Runtime.BackgroundJobRunner,
               name: Maraithon.Runtime.ModelBackgroundJobRunner,
               queues: [PeriodicJobs.model_queue()],
               fair?: true,
               max_concurrency: Config.positive_integer(:model_job_max_concurrency, 3),
               max_partition_concurrency: 1,
               max_rate_limit_concurrency: Config.positive_integer(:model_job_max_concurrency, 3),
               reconcile_recurring_jobs?: false},
              id: Maraithon.Runtime.ModelBackgroundJobRunner
            ),
            Maraithon.Runtime.Scheduler,
            Maraithon.Runtime.ShutdownReporter,
            # These two remain independent observers by design. If the durable
            # queue or every lane runner wedges, putting its reporter/alarm in
            # that same queue would silence the only signal about the failure.
            Maraithon.Runtime.HealthReporter,
            Maraithon.Runtime.StuckStateWatchdog
          ]
      else
        # Exact starts are still exercised in focused tests. Keep the mandatory
        # monitor online even when periodic/background producers are disabled.
        dependency_children ++ [agent_supervisor, Maraithon.Runtime.AgentWatcher]
      end

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 20,
      max_seconds: 60
    )
  end
end
