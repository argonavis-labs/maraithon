defmodule Maraithon.Runtime.AgentWatcher do
  @moduledoc """
  Observes runtime agent exits, records crash incidents, and performs minimal recovery.

  The dynamic supervisor remains the first recovery layer. The watcher waits for
  the configured backoff and only calls the runtime re-resume path if the agent
  is still not running.
  """

  use GenServer

  import Ecto.Query

  alias Maraithon.Agents
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Events
  alias Maraithon.Repo
  alias Maraithon.Runtime
  alias Maraithon.Runtime.AgentRegistry
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

  @impl true
  def init(opts) do
    state = %{
      monitors: %{},
      pids: %{},
      crashes: %{},
      poll_interval_ms:
        Keyword.get(opts, :poll_interval_ms) ||
          Config.positive_integer(:agent_watcher_poll_interval_ms, @default_poll_interval_ms),
      crash_loop_max:
        Keyword.get(opts, :crash_loop_max) ||
          Config.positive_integer(:agent_crash_loop_max, @default_crash_loop_max),
      crash_loop_window_ms:
        Keyword.get(opts, :crash_loop_window_ms) ||
          Config.positive_integer(:agent_crash_loop_window_ms, @default_crash_loop_window_ms),
      reresume_backoffs:
        Keyword.get(opts, :reresume_backoffs) ||
          configured_backoffs()
    }

    send(self(), :reconcile)
    {:ok, state}
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
        %{agent_id: agent_id} ->
          handle_agent_down(agent_id, pid, reason, state)

        nil ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:recover_agent, agent_id, crash_count}, state) do
    state =
      if agent_running?(agent_id) do
        IncidentLog.record(%{
          kind: :agent_resumed,
          agent_id: agent_id,
          metadata: %{
            "resume_trigger" => "targeted_reresume",
            "already_running" => true,
            "crash_count_in_window" => crash_count
          }
        })

        reconcile_agents(state)
      else
        case Runtime.resume_agent_after_crash(agent_id, %{
               "crash_count_in_window" => crash_count
             }) do
          {:ok, _pid} ->
            reconcile_agents(state)

          {:error, reason} ->
            IncidentLog.record(%{
              kind: :agent_stopped_unexpectedly,
              agent_id: agent_id,
              reason: reason,
              metadata: %{
                "recovery_failed" => true,
                "crash_count_in_window" => crash_count
              }
            })

            state
        end
      end

    {:noreply, state}
  end

  defp reconcile_agents(state) do
    AgentSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.reduce(state, fn
      {_child_id, pid, :worker, _modules}, acc when is_pid(pid) ->
        case Registry.keys(AgentRegistry, pid) do
          [agent_id | _] -> monitor_agent(acc, agent_id, pid)
          [] -> acc
        end

      _other, acc ->
        acc
    end)
  catch
    :exit, reason ->
      Logger.warning("AgentWatcher reconcile failed", reason: inspect(reason))
      state
  end

  defp monitor_agent(%{pids: pids} = state, _agent_id, pid) when is_map_key(pids, pid), do: state

  defp monitor_agent(state, agent_id, pid) do
    ref = Process.monitor(pid)
    monitor = %{agent_id: agent_id, pid: pid, started_at: DateTime.utc_now()}

    %{
      state
      | monitors: Map.put(state.monitors, ref, monitor),
        pids: Map.put(state.pids, pid, ref)
    }
  end

  defp pop_monitor(state, ref, pid) do
    monitor = Map.get(state.monitors, ref)

    {
      monitor,
      %{state | monitors: Map.delete(state.monitors, ref), pids: Map.delete(state.pids, pid)}
    }
  end

  defp handle_agent_down(_agent_id, _pid, reason, state) when reason in [:normal, :shutdown] do
    state
  end

  defp handle_agent_down(_agent_id, _pid, {:shutdown, _detail}, state), do: state

  defp handle_agent_down(agent_id, pid, reason, state) do
    now_ms = System.monotonic_time(:millisecond)
    crash_times = crash_times(state, agent_id, now_ms)
    crash_count = length(crash_times)

    metadata =
      agent_metadata(agent_id)
      |> Map.merge(%{
        "pid" => inspect(pid),
        "restart_count_in_window" => crash_count,
        "crash_loop_window_ms" => state.crash_loop_window_ms
      })

    IncidentLog.record(%{
      kind: :agent_crash,
      agent_id: agent_id,
      reason: reason,
      metadata: metadata
    })

    crashes = Map.put(state.crashes, agent_id, crash_times)
    state = %{state | crashes: crashes}

    if crash_count >= state.crash_loop_max do
      IncidentLog.record(%{
        kind: :agent_stopped_unexpectedly,
        agent_id: agent_id,
        reason: "crash_loop_threshold",
        metadata: metadata
      })

      state
    else
      Process.send_after(
        self(),
        {:recover_agent, agent_id, crash_count},
        backoff_for(state.reresume_backoffs, crash_count)
      )

      state
    end
  end

  defp crash_times(state, agent_id, now_ms) do
    state.crashes
    |> Map.get(agent_id, [])
    |> Enum.filter(&(now_ms - &1 <= state.crash_loop_window_ms))
    |> then(&[now_ms | &1])
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

  defp agent_running?(agent_id) do
    case Registry.lookup(AgentRegistry, agent_id) do
      [{pid, _value} | _] when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp backoff_for(backoffs, crash_count) do
    backoffs
    |> Enum.at(max(crash_count - 1, 0), List.last(backoffs) || 0)
    |> max(0)
  end

  defp configured_backoffs do
    case Config.get(:agent_reresume_backoffs, @default_reresume_backoffs) do
      values when is_list(values) ->
        values
        |> Enum.filter(&(is_integer(&1) and &1 >= 0))
        |> case do
          [] -> @default_reresume_backoffs
          valid -> valid
        end

      _other ->
        @default_reresume_backoffs
    end
  end

  defp schedule_reconcile(delay_ms), do: Process.send_after(self(), :reconcile, delay_ms)
end
