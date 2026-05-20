defmodule Maraithon.Runtime.AgentWatcherTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Agents
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.IncidentLog

  test "records crash and targeted resume incidents after abnormal agent exit" do
    {:ok, agent} = running_agent("watcher-resume")
    {:ok, pid} = AgentSupervisor.start_agent(agent)
    wait_for_idle(agent.id)

    watcher =
      start_supervised!(
        {AgentWatcher,
         [
           name: :"agent_watcher_#{System.unique_integer([:positive])}",
           poll_interval_ms: 10,
           reresume_backoffs: [10],
           crash_loop_max: 3,
           crash_loop_window_ms: 60_000
         ]}
      )

    assert_eventually(fn ->
      watcher
      |> :sys.get_state()
      |> Map.get(:pids)
      |> Map.has_key?(pid)
    end)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    assert_eventually(fn ->
      crash_recorded? =
        :agent_crash
        |> IncidentLog.by_kind()
        |> Enum.any?(&(&1.agent_id == agent.id))

      resumed_recorded? =
        :agent_resumed
        |> IncidentLog.by_kind()
        |> Enum.any?(
          &(&1.agent_id == agent.id and &1.metadata["resume_trigger"] == "targeted_reresume")
        )

      crash_recorded? and resumed_recorded?
    end)
  end

  test "records stopped unexpectedly when crash loop threshold is reached" do
    {:ok, agent} = running_agent("watcher-threshold")
    {:ok, pid} = AgentSupervisor.start_agent(agent)
    wait_for_idle(agent.id)

    watcher =
      start_supervised!(
        {AgentWatcher,
         [
           name: :"agent_watcher_#{System.unique_integer([:positive])}",
           poll_interval_ms: 10,
           reresume_backoffs: [10],
           crash_loop_max: 1,
           crash_loop_window_ms: 60_000
         ]}
      )

    assert_eventually(fn ->
      watcher
      |> :sys.get_state()
      |> Map.get(:pids)
      |> Map.has_key?(pid)
    end)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    assert_eventually(fn ->
      :agent_stopped_unexpectedly
      |> IncidentLog.by_kind()
      |> Enum.any?(&(&1.agent_id == agent.id and &1.reason == "crash_loop_threshold"))
    end)

    refute Enum.any?(IncidentLog.by_kind(:agent_resumed), &(&1.agent_id == agent.id))
  end

  defp running_agent(name) do
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        status: "running",
        started_at: DateTime.utc_now(),
        config: %{"name" => name}
      })

    on_exit(fn -> stop_agent(agent.id) end)

    {:ok, agent}
  end

  defp wait_for_idle(agent_id) do
    assert_eventually(fn ->
      try do
        case Registry.lookup(AgentRegistry, agent_id) do
          [{pid, _value}] ->
            match?({:idle, _data}, :sys.get_state(pid))

          _other ->
            false
        end
      catch
        :exit, _reason -> false
      end
    end)
  end

  defp stop_agent(agent_id) do
    case Registry.lookup(AgentRegistry, agent_id) do
      [{pid, _value}] -> AgentSupervisor.stop_agent(pid, "test_cleanup")
      _other -> :ok
    end
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      receive do
      after
        20 -> assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met before timeout")
end
