defmodule Maraithon.Runtime.AgentWatcherTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.IncidentLog

  test "records crash and targeted resume incidents after abnormal agent exit" do
    {:ok, agent} = running_agent("watcher-resume")
    {supervisor, watcher} = exact_runtime(crash_loop_max: 3)

    {:ok, pid} =
      AgentSupervisor.start_agent(agent,
        supervisor: supervisor,
        watcher: watcher,
        ttl_ms: 5_000,
        renew_interval_ms: 500
      )

    wait_for_idle(agent.id)

    assert_eventually(fn ->
      watcher
      |> :sys.get_state()
      |> Map.get(:pids)
      |> Map.has_key?(pid)
    end)

    [{^pid, failed_owner_token}] = Registry.lookup(AgentRegistry, agent.id)
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

    assert_eventually(fn ->
      case {AgentRestartGuards.get(agent.id), AgentLeases.get(agent.id)} do
        {%{needs_recovery: false}, %{owner_token: replacement, ready_at: ready_at}} ->
          replacement != failed_owner_token and ready_at != nil

        _other ->
          false
      end
    end)
  end

  test "durably guards a normal DOWN that still owns a live lease" do
    {:ok, agent} = running_agent("watcher-normal-live")
    {supervisor, watcher} = exact_runtime(crash_loop_max: 3, recover?: false)

    {:ok, pid} =
      AgentSupervisor.start_agent(agent,
        supervisor: supervisor,
        watcher: watcher,
        ttl_ms: 5_000,
        renew_interval_ms: 500
      )

    wait_for_idle(agent.id)
    [{^pid, owner_token}] = Registry.lookup(AgentRegistry, agent.id)
    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    assert_eventually(fn ->
      match?(
        %{last_owner_token: ^owner_token, needs_recovery: true},
        AgentRestartGuards.get(agent.id)
      )
    end)

    assert AgentLeases.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "running"
  end

  test "records stopped unexpectedly when crash loop threshold is reached" do
    {:ok, agent} = running_agent("watcher-threshold")
    {supervisor, watcher} = exact_runtime(crash_loop_max: 1)

    {:ok, pid} =
      AgentSupervisor.start_agent(agent,
        supervisor: supervisor,
        watcher: watcher,
        ttl_ms: 5_000,
        renew_interval_ms: 500
      )

    wait_for_idle(agent.id)

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
    assert %{tripped: true, needs_recovery: true} = AgentRestartGuards.get(agent.id)
    assert AgentLeases.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "stopped"
  end

  defp running_agent(name) do
    user_id = "#{name}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    with {:ok, agent} <-
           Agents.create_agent(%{
             user_id: user_id,
             behavior: "prompt_agent",
             status: "running",
             started_at: DateTime.utc_now(),
             config: %{"name" => name}
           }),
         {:ok, _binding} <- AgentIsolation.grant_binding_consent(agent, binding_consent(agent)) do
      {:ok, agent}
    end
  end

  defp exact_runtime(opts) do
    suffix = System.unique_integer([:positive])
    supervisor_name = :"agent_supervisor_#{suffix}"
    watcher_name = :"agent_watcher_#{suffix}"

    supervisor =
      start_supervised!(
        {DynamicSupervisor,
         strategy: :one_for_one, name: supervisor_name, max_restarts: 20, max_seconds: 60},
        id: supervisor_name
      )

    watcher =
      start_supervised!(
        {AgentWatcher,
         [
           name: watcher_name,
           agent_supervisor: supervisor,
           reconcile?: false,
           recover?: Keyword.get(opts, :recover?, true),
           poll_interval_ms: 10,
           reresume_backoffs: [10],
           crash_loop_max: Keyword.fetch!(opts, :crash_loop_max),
           crash_loop_window_ms: 60_000
         ]},
        id: watcher_name
      )

    {supervisor, watcher}
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
