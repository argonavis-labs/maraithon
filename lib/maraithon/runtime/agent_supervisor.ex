defmodule Maraithon.Runtime.AgentSupervisor do
  @moduledoc """
  Exact-ownership launcher for temporary Agent processes.

  Every production incarnation claims a fresh database lease before spawn. The
  DynamicSupervisor never restarts an Agent with old launch arguments; recovery
  is admitted only after AgentWatcher durably records the failed generation.
  """

  alias Maraithon.Agents.Agent, as: AgentRecord
  alias Maraithon.Runtime.Agent
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.BootGate
  alias Maraithon.Runtime.Config, as: RuntimeConfig

  require Logger

  @default_lease_ttl_ms 60_000
  @default_stop_timeout_ms 15_000
  @allowed_start_options [
    :admission,
    :recovery_generation,
    :renew_interval_ms,
    :supervisor,
    :ttl_ms,
    :watcher
  ]

  @doc """
  Claims exact ownership and only then starts a temporary Agent child.

  `:supervisor` and `:watcher` are injectable solely for physical lifecycle
  tests. Runtime production callers use the registered defaults.
  """
  def start_agent(agent, opts \\ [])

  def start_agent(%AgentRecord{} = agent, opts) when is_list(opts) do
    with :ok <- validate_start_options(opts),
         :ok <- ensure_admission(opts),
         {:ok, launch_config} <- launch_config(opts),
         :ok <- AgentWatcher.ensure_available(launch_config.watcher),
         {:ok, lease} <-
           claim(agent.id, launch_config.recovery_generation, launch_config.ttl_ms) do
      start_claimed_agent(agent, lease, launch_config)
    end
  end

  def start_agent(_agent, _opts), do: {:error, :invalid_agent_start}

  @doc "Stops an Agent through its explicit drain-and-release control path."
  def stop_agent(pid, reason \\ "manual_stop")

  def stop_agent(pid, reason) when is_pid(pid) do
    stop_agent(pid, reason, [])
  end

  def stop_agent(pid, reason, owner_token)
      when is_pid(pid) and is_binary(owner_token) do
    stop_agent(pid, reason, owner_token: owner_token)
  end

  def stop_agent(pid, reason, opts) when is_pid(pid) and is_list(opts) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)

    timeout_ms =
      Keyword.get(
        opts,
        :timeout_ms,
        RuntimeConfig.positive_integer(:agent_stop_timeout_ms, @default_stop_timeout_ms)
      )

    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      stop_message =
        case Keyword.get(opts, :owner_token) || local_exact_owner_token(pid) do
          owner_token when is_binary(owner_token) -> {:control, :stop, reason, owner_token}
          _legacy_local_pid -> {:control, :stop, reason}
        end

      send(pid, {:agent_dispatch, stop_message})

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          :ok
      after
        timeout_ms ->
          Process.demonitor(ref, [:flush])
          DynamicSupervisor.terminate_child(supervisor, pid)
      end
    else
      DynamicSupervisor.terminate_child(supervisor, pid)
    end
  end

  defp local_exact_owner_token(pid) do
    AgentRegistry
    |> Registry.keys(pid)
    |> Enum.find_value(fn agent_id ->
      case Registry.lookup(AgentRegistry, agent_id) do
        [{^pid, owner_token}] when is_binary(owner_token) -> owner_token
        _not_exact_owner -> nil
      end
    end)
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp validate_start_options(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @allowed_start_options)),
      do: :ok,
      else: {:error, :invalid_agent_start}
  end

  defp ensure_admission(opts) do
    admission = Keyword.get(opts, :admission, :normal)
    background_workers? = Application.get_env(:maraithon, :start_background_workers, true)

    cond do
      admission in [:bootstrap, :recovery] -> :ok
      admission != :normal -> {:error, :invalid_agent_start}
      not background_workers? -> :ok
      BootGate.open?() -> :ok
      true -> {:error, :runtime_admission_closed}
    end
  end

  defp launch_config(opts) do
    ttl_ms =
      Keyword.get(
        opts,
        :ttl_ms,
        RuntimeConfig.positive_integer(:agent_lease_ttl_ms, @default_lease_ttl_ms)
      )

    configured_renewal =
      RuntimeConfig.positive_integer(:agent_lease_renew_interval_ms, max(div(ttl_ms, 3), 1))

    renew_interval_ms = Keyword.get(opts, :renew_interval_ms, configured_renewal)

    if is_integer(ttl_ms) and ttl_ms in 1_000..300_000 and
         is_integer(renew_interval_ms) and renew_interval_ms > 0 and
         renew_interval_ms < ttl_ms do
      {:ok,
       %{
         recovery_generation: Keyword.get(opts, :recovery_generation),
         renew_interval_ms: renew_interval_ms,
         supervisor: Keyword.get(opts, :supervisor, __MODULE__),
         ttl_ms: ttl_ms,
         watcher: Keyword.get(opts, :watcher, AgentWatcher)
       }}
    else
      {:error, :invalid_agent_start}
    end
  end

  defp claim(agent_id, nil, ttl_ms), do: AgentLeases.claim(agent_id, ttl_ms: ttl_ms)

  defp claim(agent_id, recovery_generation, ttl_ms) do
    AgentLeases.claim_recovery(agent_id, recovery_generation, ttl_ms: ttl_ms)
  end

  defp start_claimed_agent(agent, lease, config) do
    init_arg = %{
      agent: agent,
      owner_token: lease.owner_token,
      guard_generation: config.recovery_generation,
      lease_ttl_ms: config.ttl_ms,
      lease_renew_interval_ms: config.renew_interval_ms
    }

    case start_child(config.supervisor, Agent.child_spec(init_arg)) do
      {:ok, pid} ->
        finish_tracked_start(config, pid, agent.id, lease.owner_token)

      {:error, {:already_started, _pid}} = error ->
        release_unspawned(config.watcher, agent.id, lease.owner_token)
        error

      {:error, reason} = error when reason in [:already_present, :max_children, :noproc] ->
        release_unspawned(config.watcher, agent.id, lease.owner_token)
        error

      {:error, reason} = error ->
        record_failed_start(config.watcher, agent.id, lease.owner_token, reason)
        error

      :ignore ->
        record_failed_start(config.watcher, agent.id, lease.owner_token, :agent_start_ignored)
        {:error, :agent_start_ignored}
    end
  end

  defp start_child(supervisor, child_spec) do
    DynamicSupervisor.start_child(supervisor, child_spec)
  catch
    :exit, {:noproc, _detail} -> {:error, :noproc}
    :exit, :noproc -> {:error, :noproc}
    :exit, reason -> {:error, {:supervisor_exit, reason}}
  end

  defp finish_tracked_start(config, pid, agent_id, owner_token) do
    case AgentWatcher.track(config.watcher, pid, agent_id, owner_token) do
      :ok ->
        Agent.activate_exact(pid, owner_token)
        {:ok, pid}

      {:error, reason} ->
        case DynamicSupervisor.terminate_child(config.supervisor, pid) do
          :ok -> :ok
          _not_a_child -> Process.exit(pid, :kill)
        end

        record_failed_start(config.watcher, agent_id, owner_token, {:track_failed, reason})
        {:error, :agent_watcher_unavailable}
    end
  end

  defp release_unspawned(watcher, agent_id, owner_token) do
    case AgentLeases.release(agent_id, owner_token) do
      {:ok, :released} -> :ok
      _lost_or_unavailable -> record_failed_start(watcher, agent_id, owner_token, :release_failed)
    end
  end

  defp record_failed_start(watcher, agent_id, owner_token, reason) do
    case AgentWatcher.record_owner_down(
           watcher,
           agent_id,
           owner_token,
           self(),
           {:agent_start_failed, reason}
         ) do
      {:ok, _result} ->
        :ok

      {:error, _watcher_reason} ->
        record_failed_start_without_watcher(agent_id, owner_token, reason)
    end
  end

  # The watcher is required before claim. This fallback only closes the tiny
  # race where it exits after admission but before failure reconciliation.
  defp record_failed_start_without_watcher(agent_id, owner_token, reason) do
    case AgentRestartGuards.record_crash(agent_id, owner_token, {:agent_start_failed, reason}) do
      result when elem(result, 0) in [:recorded, :duplicate] ->
        _ = AgentDirectives.recover_generation(agent_id, owner_token)
        :ok

      _stale_or_error ->
        :ok
    end
  rescue
    error ->
      Logger.error("Failed to reconcile exact Agent start",
        agent_reference: Maraithon.Redaction.fingerprint(agent_id),
        failure_code: Maraithon.Redaction.error_class(error)
      )

      :ok
  catch
    :exit, reason ->
      Logger.error("Exact Agent start reconciliation exited",
        agent_reference: Maraithon.Redaction.fingerprint(agent_id),
        failure_code: Maraithon.Redaction.error_class(reason)
      )

      :ok
  end
end
