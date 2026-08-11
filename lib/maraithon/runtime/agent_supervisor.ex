defmodule Maraithon.Runtime.AgentSupervisor do
  @moduledoc """
  Exact-ownership launcher for temporary Agent processes.

  Every production incarnation claims a fresh database lease before spawn. The
  DynamicSupervisor never restarts an Agent with old launch arguments; recovery
  is admitted only after AgentWatcher durably records the failed generation.
  """

  alias Maraithon.Agents.Agent, as: AgentRecord
  alias Maraithon.Runtime.Agent
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentTerminations
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
         :ok <- ensure_supervisor_available(launch_config.supervisor),
         {:ok, lease} <-
           claim(
             agent.id,
             launch_config.recovery_generation,
             launch_config.ttl_ms,
             launch_config.watcher
           ) do
      start_claimed_agent(agent, lease, launch_config)
    end
  end

  def start_agent(_agent, _opts), do: {:error, :invalid_agent_start}

  @doc "Fail-closed static/process admission check used before durable creation."
  def preflight(opts \\ [])

  def preflight(opts) when is_list(opts) do
    with :ok <- validate_start_options(opts),
         :ok <- ensure_admission(opts),
         {:ok, launch_config} <- launch_config(opts),
         :ok <- AgentWatcher.ensure_available(launch_config.watcher),
         :ok <- ensure_supervisor_available(launch_config.supervisor) do
      :ok
    end
  end

  def preflight(_opts), do: {:error, :invalid_agent_start}

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

      case await_down(ref, pid, timeout_ms) do
        :down ->
          :ok

        :timeout ->
          # DynamicSupervisor return values are routing results, never physical
          # proof. Keep the monitor installed and wait for its actual DOWN.
          _termination_attempt = DynamicSupervisor.terminate_child(supervisor, pid)

          case await_down(ref, pid, timeout_ms) do
            :down ->
              :ok

            :timeout ->
              Process.demonitor(ref, [:flush])
              {:error, :termination_unproven}
          end
      end
    else
      # A Registry/supervisor miss and :not_found are deliberately non-proving.
      {:error, :not_found}
    end
  catch
    :exit, _reason -> {:error, :termination_unproven}
  end

  defp await_down(ref, pid, timeout_ms) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :down
    after
      timeout_ms -> :timeout
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
      not RuntimeConfig.exact_agent_runtime_ready?() -> {:error, :exact_runtime_disabled}
      admission in [:bootstrap, :recovery] -> :ok
      admission != :normal -> {:error, :invalid_agent_start}
      not background_workers? -> :ok
      BootGate.open?() -> :ok
      true -> {:error, :runtime_admission_closed}
    end
  end

  defp ensure_supervisor_available(supervisor) when is_pid(supervisor) do
    if Process.alive?(supervisor), do: :ok, else: {:error, :agent_supervisor_unavailable}
  end

  defp ensure_supervisor_available(supervisor) when is_atom(supervisor) do
    if Process.whereis(supervisor), do: :ok, else: {:error, :agent_supervisor_unavailable}
  end

  defp ensure_supervisor_available(_supervisor), do: {:error, :agent_supervisor_unavailable}

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

  defp claim(agent_id, nil, ttl_ms, watcher),
    do: AgentLeases.claim(agent_id, ttl_ms: ttl_ms, watcher: watcher)

  defp claim(agent_id, recovery_generation, ttl_ms, watcher) do
    AgentLeases.claim_recovery(agent_id, recovery_generation,
      ttl_ms: ttl_ms,
      watcher: watcher
    )
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

      {:error, reason} = error ->
        discard_lease_capability(config.watcher, agent.id, lease.owner_token)
        request_failed_start(agent.id, lease.owner_token, reason)
        error

      :ignore ->
        discard_lease_capability(config.watcher, agent.id, lease.owner_token)
        request_failed_start(agent.id, lease.owner_token, :agent_start_ignored)
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
    # This caller-side monitor closes the spawn-to-guardian handoff gap, but it
    # is not the watcher-owned proof capability. A failed handoff remains
    # ambiguous even if this caller later observes DOWN.
    ref = Process.monitor(pid)

    case AgentWatcher.track(config.watcher, pid, agent_id, owner_token) do
      :ok ->
        Process.demonitor(ref, [:flush])
        Agent.activate_exact(pid, owner_token)
        {:ok, pid}

      {:error, reason} ->
        discard_lease_capability(config.watcher, agent_id, owner_token)
        _termination_attempt = DynamicSupervisor.terminate_child(config.supervisor, pid)

        proof_result =
          case await_down(ref, pid, @default_stop_timeout_ms) do
            :down ->
              request_failed_start(agent_id, owner_token, {:watcher_handoff_down, reason})

            :timeout ->
              Process.demonitor(ref, [:flush])
              request_failed_start(agent_id, owner_token, {:track_failed, reason})
          end

        _ = proof_result
        {:error, :agent_watcher_unavailable}
    end
  end

  defp discard_lease_capability(watcher, agent_id, owner_token) do
    _ = AgentWatcher.discard_lease_capability(watcher, agent_id, owner_token)
    :ok
  end

  defp request_failed_start(agent_id, owner_token, reason) do
    case AgentTerminations.request_ambiguous(
           agent_id,
           owner_token,
           {:agent_start_ambiguous, reason}
         ) do
      result when elem(result, 0) in [:requested, :duplicate, :ignored] ->
        :ok

      {:error, error} ->
        Logger.error("Failed to request exact Agent start reconciliation",
          agent_reference: Maraithon.Redaction.fingerprint(agent_id),
          failure_code: Maraithon.Redaction.error_class(error)
        )

        :ok
    end
  rescue
    error ->
      Logger.error("Failed to request exact Agent start reconciliation",
        agent_reference: Maraithon.Redaction.fingerprint(agent_id),
        failure_code: Maraithon.Redaction.error_class(error)
      )

      :ok
  catch
    :exit, reason ->
      Logger.error("Exact Agent start reconciliation request exited",
        agent_reference: Maraithon.Redaction.fingerprint(agent_id),
        failure_code: Maraithon.Redaction.error_class(reason)
      )

      :ok
  end
end
