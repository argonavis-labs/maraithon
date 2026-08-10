defmodule Maraithon.Runtime.AgentWatcher do
  @moduledoc """
  Monitors exact Agent incarnations and durably records ownership loss.

  Registry and PID data are routing hints only. A DOWN is actionable solely
  when its captured owner token still matches the database lease.
  """

  use GenServer

  import Ecto.Query

  alias Maraithon.Agents
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Events
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.IncidentLog

  require Logger

  @name __MODULE__
  @default_poll_interval_ms 2_000
  @default_crash_loop_max 3
  @default_crash_loop_window_ms 600_000
  @default_reresume_backoffs [5_000, 15_000, 30_000]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc false
  def ensure_available(server \\ @name) do
    GenServer.call(server, :ping)
  catch
    :exit, _reason -> {:error, :watcher_unavailable}
  end

  @doc "Synchronously monitors one exact `{pid, agent_id, owner_token}`."
  def track(pid, agent_id, owner_token) when is_pid(pid) do
    track(@name, pid, agent_id, owner_token)
  end

  def track(server, pid, agent_id, owner_token)
      when is_pid(pid) and is_binary(agent_id) and is_binary(owner_token) do
    GenServer.call(server, {:track, pid, agent_id, owner_token})
  catch
    :exit, _reason -> {:error, :watcher_unavailable}
  end

  def track(_server, _pid, _agent_id, _owner_token), do: {:error, :invalid_agent_owner}

  @doc """
  Reconciles a token loss through the same guard-first path as a monitor DOWN.

  The launcher uses this only for ambiguous start failures after preclaim.
  """
  def record_owner_down(server, agent_id, owner_token, pid, reason)
      when is_binary(agent_id) and is_binary(owner_token) and is_pid(pid) do
    GenServer.call(server, {:record_owner_down, agent_id, owner_token, pid, reason}, 30_000)
  catch
    :exit, _reason -> {:error, :watcher_unavailable}
  end

  def record_owner_down(_server, _agent_id, _owner_token, _pid, _reason),
    do: {:error, :invalid_agent_owner}

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.get(opts, :name, @name),
      monitors: %{},
      owners: %{},
      pids: %{},
      recoveries: MapSet.new(),
      agent_supervisor: Keyword.get(opts, :agent_supervisor, AgentSupervisor),
      reconcile?: Keyword.get(opts, :reconcile?, true),
      recover?: Keyword.get(opts, :recover?, true),
      poll_interval_ms:
        Keyword.get(opts, :poll_interval_ms) ||
          Config.positive_integer(:agent_watcher_poll_interval_ms, @default_poll_interval_ms),
      crash_loop_max:
        opts
        |> Keyword.get(
          :crash_loop_max,
          Config.positive_integer(:agent_crash_loop_max, @default_crash_loop_max)
        )
        |> max(1)
        |> min(100),
      crash_loop_window_ms:
        opts
        |> Keyword.get(
          :crash_loop_window_ms,
          Config.positive_integer(
            :agent_crash_loop_window_ms,
            @default_crash_loop_window_ms
          )
        )
        |> max(1_000)
        |> min(86_400_000),
      reresume_backoffs:
        opts
        |> Keyword.get(:reresume_backoffs, configured_backoffs())
        |> normalize_backoffs()
    }

    if state.reconcile?, do: send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :ok, state}

  def handle_call({:track, pid, agent_id, owner_token}, _from, state) do
    case validate_exact_owner(agent_id, owner_token) do
      :ok ->
        case monitor_agent(state, agent_id, owner_token, pid) do
          {:ok, tracked} -> {:reply, :ok, tracked}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:record_owner_down, agent_id, owner_token, pid, reason},
        _from,
        state
      ) do
    case validate_exact_owner(agent_id, owner_token) do
      :ok ->
        {result, state} = handle_agent_down(agent_id, owner_token, pid, reason, state)
        {:reply, {:ok, result}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_info(:reconcile, state) do
    state = reconcile_agents(state)
    schedule_reconcile(state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    {monitor, state} = pop_monitor(state, ref, pid)

    state =
      case monitor do
        %{agent_id: agent_id, owner_token: owner_token} ->
          {_result, state} = handle_agent_down(agent_id, owner_token, pid, reason, state)
          state

        nil ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:recover_agent, agent_id, guard_generation, crash_count}, state) do
    key = {agent_id, guard_generation}

    if MapSet.member?(state.recoveries, key) do
      watcher = state.name
      supervisor = state.agent_supervisor

      case Task.Supervisor.start_child(
             Maraithon.Runtime.AgentRecoveryTaskSupervisor,
             fn ->
               result = launch_recovery(supervisor, watcher, agent_id, guard_generation)
               send(watcher, {:recovery_result, agent_id, guard_generation, crash_count, result})
             end
           ) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          send(
            watcher,
            {:recovery_result, agent_id, guard_generation, crash_count,
             {:error, {:recovery_task_start_failed, reason}}}
          )
      end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:recovery_result, agent_id, guard_generation, crash_count, result},
        state
      ) do
    key = {agent_id, guard_generation}
    state = %{state | recoveries: MapSet.delete(state.recoveries, key)}

    case result do
      {:ok, _pid} ->
        IncidentLog.record(%{
          kind: :agent_resumed,
          agent_id: agent_id,
          metadata: %{
            "resume_trigger" => "targeted_reresume",
            "guard_generation" => guard_generation,
            "crash_count_in_window" => crash_count
          }
        })

        {:noreply, state}

      {:error, :agent_restart_backoff} ->
        case AgentRestartGuards.get(agent_id) do
          %{generation: ^guard_generation, needs_recovery: true, tripped: false} = guard ->
            {:noreply, schedule_recovery(agent_id, guard, state)}

          _stale ->
            {:noreply, state}
        end

      {:error, reason} when reason in [:runtime_lease_owned, :stale_recovery_generation] ->
        {:noreply, state}

      {:error, reason} ->
        IncidentLog.record(%{
          kind: :agent_stopped_unexpectedly,
          agent_id: agent_id,
          reason: reason,
          metadata: %{
            "recovery_failed" => true,
            "guard_generation" => guard_generation,
            "crash_count_in_window" => crash_count
          }
        })

        {:noreply, state}
    end
  end

  defp launch_recovery(supervisor, watcher, agent_id, guard_generation) do
    case Agents.get_agent(agent_id, include_removed: true) do
      %{status: status, install_status: "enabled"} = agent
      when status in ["running", "degraded"] ->
        AgentSupervisor.start_agent(agent,
          admission: :recovery,
          recovery_generation: guard_generation,
          supervisor: supervisor,
          watcher: watcher
        )

      nil ->
        {:error, :not_found}

      _inactive ->
        {:error, :agent_not_resumable}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp reconcile_agents(state) do
    state.agent_supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.reduce(state, fn
      {_child_id, pid, :worker, _modules}, acc when is_pid(pid) ->
        case exact_registry_owner(pid) do
          {agent_id, owner_token} ->
            case monitor_agent(acc, agent_id, owner_token, pid) do
              {:ok, tracked} -> tracked
              {:error, _reason} -> acc
            end

          nil ->
            acc
        end

      _other, acc ->
        acc
    end)
  catch
    :exit, reason ->
      Logger.warning("AgentWatcher reconcile failed", reason: inspect(reason))
      state
  end

  defp exact_registry_owner(pid) do
    AgentRegistry
    |> Registry.keys(pid)
    |> Enum.find_value(fn agent_id ->
      AgentRegistry
      |> Registry.lookup(agent_id)
      |> Enum.find_value(fn
        {^pid, owner_token} when is_binary(owner_token) ->
          case validate_exact_owner(agent_id, owner_token) do
            :ok -> {agent_id, owner_token}
            {:error, _reason} -> nil
          end

        _other ->
          nil
      end)
    end)
  catch
    :exit, _reason -> nil
  end

  defp monitor_agent(%{pids: pids} = state, agent_id, owner_token, pid)
       when is_map_key(pids, pid) do
    ref = Map.fetch!(pids, pid)

    case Map.fetch!(state.monitors, ref) do
      %{agent_id: ^agent_id, owner_token: ^owner_token} -> {:ok, state}
      _other -> {:error, :pid_owner_conflict}
    end
  end

  defp monitor_agent(state, agent_id, owner_token, pid) do
    owner = {agent_id, owner_token}

    if Map.has_key?(state.owners, owner) do
      {:error, :owner_already_tracked}
    else
      ref = Process.monitor(pid)

      monitor = %{
        agent_id: agent_id,
        owner_token: owner_token,
        pid: pid,
        started_at: DateTime.utc_now()
      }

      {:ok,
       %{
         state
         | monitors: Map.put(state.monitors, ref, monitor),
           owners: Map.put(state.owners, owner, ref),
           pids: Map.put(state.pids, pid, ref)
       }}
    end
  end

  defp pop_monitor(state, ref, pid) do
    monitor = Map.get(state.monitors, ref)

    owners =
      case monitor do
        %{agent_id: agent_id, owner_token: owner_token} ->
          Map.delete(state.owners, {agent_id, owner_token})

        nil ->
          state.owners
      end

    {monitor,
     %{
       state
       | monitors: Map.delete(state.monitors, ref),
         owners: owners,
         pids: Map.delete(state.pids, pid)
     }}
  end

  defp handle_agent_down(agent_id, owner_token, pid, reason, state) do
    guard_opts = [
      window_ms: state.crash_loop_window_ms,
      max_crashes: state.crash_loop_max,
      backoffs_ms: state.reresume_backoffs
    ]

    case safe_record_crash(agent_id, owner_token, reason, guard_opts) do
      {:recorded, guard} = result ->
        state = record_exact_crash(agent_id, owner_token, pid, reason, guard, state)
        {result, state}

      {:duplicate, guard} = result ->
        {result, recover_and_schedule(agent_id, owner_token, guard, state)}

      {:ignored, :stale_owner} = result ->
        {result, state}

      {:error, error} = result ->
        Logger.warning("Exact Agent DOWN reconciliation failed",
          agent_reference: Maraithon.Redaction.fingerprint(agent_id),
          failure_code: Maraithon.Redaction.error_class(error)
        )

        {result, state}
    end
  end

  defp record_exact_crash(agent_id, owner_token, pid, reason, guard, state) do
    metadata =
      agent_metadata(agent_id)
      |> Map.merge(%{
        "pid" => inspect(pid),
        "owner_generation" => owner_token,
        "guard_generation" => guard.generation,
        "restart_count_in_window" => guard.crash_count,
        "crash_loop_window_ms" => state.crash_loop_window_ms
      })

    IncidentLog.record(%{
      kind: :agent_crash,
      agent_id: agent_id,
      reason: reason,
      metadata: metadata
    })

    if guard.tripped do
      IncidentLog.record(%{
        kind: :agent_stopped_unexpectedly,
        agent_id: agent_id,
        reason: "crash_loop_threshold",
        metadata: metadata
      })
    end

    # A tripped guard forbids replacement but still must recover or dead-letter
    # the exact failed generation's in-flight directive.
    recover_and_schedule(agent_id, owner_token, guard, state)
  end

  defp recover_and_schedule(agent_id, owner_token, guard, state) do
    case AgentDirectives.recover_generation(agent_id, owner_token) do
      {:ok, _directive_or_nil} ->
        schedule_recovery(agent_id, guard, state)

      {:error, reason} ->
        Logger.warning("Exact Agent directive recovery deferred",
          agent_reference: Maraithon.Redaction.fingerprint(agent_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        state
    end
  end

  defp schedule_recovery(_agent_id, _guard, %{recover?: false} = state), do: state
  defp schedule_recovery(_agent_id, %{tripped: true}, state), do: state

  defp schedule_recovery(agent_id, guard, state) do
    key = {agent_id, guard.generation}

    if MapSet.member?(state.recoveries, key) do
      state
    else
      Process.send_after(
        self(),
        {:recover_agent, agent_id, guard.generation, guard.crash_count},
        recovery_delay_ms(guard.blocked_until)
      )

      %{state | recoveries: MapSet.put(state.recoveries, key)}
    end
  end

  defp safe_record_crash(agent_id, owner_token, reason, opts) do
    AgentRestartGuards.record_crash(agent_id, owner_token, reason, opts)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp recovery_delay_ms(nil), do: 0

  defp recovery_delay_ms(blocked_until) do
    max(0, DateTime.diff(blocked_until, DateTime.utc_now(), :millisecond))
  end

  defp agent_metadata(agent_id) do
    agent = Agents.get_agent(agent_id)

    %{
      "behavior" => agent && agent.behavior,
      "user_id" => agent && agent.user_id,
      "last_sequence_num" => safe_latest_sequence_num(agent_id),
      "last_running_run_id" => last_running_run_id(agent_id)
    }
  end

  defp safe_latest_sequence_num(agent_id) do
    Events.latest_sequence_num(agent_id)
  rescue
    _error -> nil
  end

  defp last_running_run_id(agent_id) do
    AgentRun
    |> where([run], run.agent_id == ^agent_id and run.status == "running")
    |> order_by([run], desc: run.started_at)
    |> select([run], run.id)
    |> limit(1)
    |> Repo.one()
  rescue
    _error -> nil
  end

  defp validate_exact_owner(agent_id, owner_token) do
    with {:ok, _agent_id} <- Ecto.UUID.cast(agent_id),
         {:ok, _owner_token} <- Ecto.UUID.cast(owner_token) do
      :ok
    else
      :error -> {:error, :invalid_agent_owner}
    end
  end

  defp configured_backoffs do
    Config.get(:agent_reresume_backoffs, @default_reresume_backoffs)
  end

  defp normalize_backoffs(values) when is_list(values) do
    values
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> Enum.map(&min(&1, 3_600_000))
    |> case do
      [] -> @default_reresume_backoffs
      valid -> valid
    end
  end

  defp normalize_backoffs(_other), do: @default_reresume_backoffs

  defp schedule_reconcile(delay_ms), do: Process.send_after(self(), :reconcile, delay_ms)
end
