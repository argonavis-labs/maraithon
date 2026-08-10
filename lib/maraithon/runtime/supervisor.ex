defmodule Maraithon.Runtime.Supervisor do
  @moduledoc """
  Top-level supervisor for the Maraithon runtime.
  """

  use Supervisor

  alias Maraithon.Runtime.BootGate

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
      Maraithon.Runtime.TaskSystemSupervisor,
      {Task.Supervisor, name: Maraithon.Runtime.ToolCallSupervisor},
      Maraithon.Runtime.Effects.LLMRateLimiter,
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
            # AgentWatcher is supervised above Runtime.Supervisor so this whole
            # subtree (including AgentSupervisor) can restart or stop while the
            # exact PID monitors remain alive.
            agent_supervisor,
            Maraithon.Runtime.WakeCoordinator,
            Maraithon.Runtime.Bootstrap,
            Maraithon.Runtime.BackgroundJobRunner,
            Maraithon.Runtime.Scheduler,
            Maraithon.Runtime.ShutdownReporter,
            Maraithon.Runtime.HealthReporter,
            Maraithon.Runtime.InsightNotifier,
            Maraithon.Runtime.BriefingCron,
            Maraithon.Runtime.DogfoodDigest,
            Maraithon.Runtime.BriefNotifier,
            Maraithon.Runtime.ProactiveCheckIn,
            Maraithon.Runtime.TodoCompletionSweep,
            Maraithon.Runtime.NudgeSweep,
            Maraithon.Runtime.StalenessTriageSweep,
            Maraithon.Runtime.TokenRefresher,
            Maraithon.Runtime.WatchRenewer,
            Maraithon.Runtime.FreshnessSweep,
            Maraithon.Runtime.StuckStateWatchdog,
            Maraithon.TelegramAssistant.RunReaper,
            # Supervised last so graceful shutdown revokes PostgreSQL readiness
            # before any scoped worker or exact task supervisor stops locally.
            Maraithon.Runtime.Coordination.Session
          ]
      else
        # The mandatory watcher is a parent-level application child. Exact
        # starts remain available while periodic/background producers are off.
        dependency_children ++ [agent_supervisor]
      end

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 20,
      max_seconds: 60
    )
  end
end
