defmodule Maraithon.Runtime.AgentWatcherTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentLocalDownWitness
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.AgentTerminationProof
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.IncidentLog

  test "records crash and targeted resume incidents after abnormal agent exit" do
    {:ok, agent} = running_agent("watcher-resume")
    {supervisor, watcher} = exact_runtime(crash_loop_max: 3)

    {:ok, pid} =
      AgentSupervisor.start_agent(agent,
        supervisor: supervisor,
        watcher: watcher,
        ttl_ms: 60_000,
        renew_interval_ms: 30_000
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
    :ok = :sys.suspend(pid)
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

    wait_for_idle(agent.id)
    stop_exact_runtime(supervisor, watcher)
  end

  test "durably guards a normal DOWN that still owns a live lease" do
    {:ok, agent} = running_agent("watcher-normal-live")
    {supervisor, watcher} = exact_runtime(crash_loop_max: 3, recover?: false)

    {:ok, pid} =
      AgentSupervisor.start_agent(agent,
        supervisor: supervisor,
        watcher: watcher,
        ttl_ms: 60_000,
        renew_interval_ms: 30_000
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

    stop_exact_runtime(supervisor, watcher)
  end

  test "records stopped unexpectedly when crash loop threshold is reached" do
    {:ok, agent} = running_agent("watcher-threshold")
    {supervisor, watcher} = exact_runtime(crash_loop_max: 1)

    {:ok, pid} =
      AgentSupervisor.start_agent(agent,
        supervisor: supervisor,
        watcher: watcher,
        ttl_ms: 60_000,
        renew_interval_ms: 30_000
      )

    wait_for_idle(agent.id)

    assert_eventually(fn ->
      watcher
      |> :sys.get_state()
      |> Map.get(:pids)
      |> Map.has_key?(pid)
    end)

    ref = Process.monitor(pid)
    :ok = :sys.suspend(pid)
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

    stop_exact_runtime(supervisor, watcher)
  end

  test "direct and dummy-PID local DOWN reports cannot mint physical proof" do
    {:ok, agent} = running_agent("watcher-proof-capability")
    {supervisor, watcher} = exact_runtime(crash_loop_max: 3, recover?: false)

    {:ok, owner_pid} =
      AgentSupervisor.start_agent(agent,
        supervisor: supervisor,
        watcher: watcher,
        ttl_ms: 60_000,
        renew_interval_ms: 5_000
      )

    wait_for_idle(agent.id)
    [{^owner_pid, owner_token}] = Registry.lookup(AgentRegistry, agent.id)
    watcher_ref = watcher |> :sys.get_state() |> Map.fetch!(:pids) |> Map.fetch!(owner_pid)

    dummy = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:error, :agent_termination_capability_required} =
             AgentWatcher.track(watcher, dummy, agent.id, owner_token)

    {:ok, unprepared_agent} = running_agent("watcher-proof-no-private-capability")
    {:ok, unprepared_lease} = AgentLeases.claim(unprepared_agent.id)
    unprepared_pid = registered_owner(unprepared_agent.id, unprepared_lease.owner_token)

    assert {:error, :agent_termination_capability_required} =
             AgentWatcher.track(
               watcher,
               unprepared_pid,
               unprepared_agent.id,
               unprepared_lease.owner_token
             )

    Process.exit(unprepared_pid, :kill)

    monitor_started_at = DatabaseClock.now!()
    ref = Process.monitor(dummy)
    Process.exit(dummy, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dummy, :killed}, 1_000

    assert {:error, :local_down_witness_required} =
             AgentTerminations.record_local_down(
               agent.id,
               owner_token,
               dummy,
               :killed,
               monitor_started_at
             )

    forged = %AgentLocalDownWitness{
      watcher_pid: self(),
      monitor_ref: ref,
      pid: dummy,
      agent_id: agent.id,
      lease_token: owner_token,
      monitor_started_at: monitor_started_at,
      down_reason: :killed,
      capability_id: make_ref(),
      capability: fn _binding -> {:ok, make_ref(), :first} end
    }

    assert {:error, :local_down_witness_required} =
             AgentTerminations.record_watcher_down(forged)

    assert AgentLeases.owner?(agent.id, owner_token)
    assert AgentRestartGuards.get(agent.id) == nil
    assert AgentTerminations.get_by_lease(owner_token) == nil
    assert Repo.aggregate(AgentTerminationProof, :count, :id) == 0

    send(watcher, {:DOWN, watcher_ref, :process, owner_pid, :killed})
    _ = :sys.get_state(watcher)

    remonitored_ref = watcher |> :sys.get_state() |> Map.fetch!(:pids) |> Map.fetch!(owner_pid)
    refute remonitored_ref == watcher_ref
    assert AgentLeases.owner?(agent.id, owner_token)
    assert AgentRestartGuards.get(agent.id) == nil
    assert AgentTerminations.get_by_lease(owner_token) == nil

    owner_ref = Process.monitor(owner_pid)
    :ok = :sys.suspend(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}, 1_000

    assert %{last_owner_token: ^owner_token, crash_count: 1} =
             assert_eventually_value(fn -> AgentRestartGuards.get(agent.id) end)

    assert AgentLeases.get(agent.id) == nil
    assert Repo.aggregate(AgentTerminationProof, :count, :id) == 1

    stop_exact_runtime(supervisor, watcher)
  end

  test "a real DOWN survives transient persistence failure and stale replay is idempotent" do
    test_pid = self()
    gate = :ets.new(:agent_down_persist_gate, [:set, :public])
    true = :ets.insert(gate, {:allowed, false})

    persist_gate = fn ->
      case :ets.lookup(gate, :allowed) do
        [{:allowed, true}] ->
          :ok

        _blocked ->
          send(test_pid, {:local_down_persist_blocked, self()})
          {:error, :simulated_database_unavailable}
      end
    end

    {:ok, agent} = running_agent("watcher-proof-retry")

    {supervisor, watcher} =
      exact_runtime(
        crash_loop_max: 3,
        recover?: false,
        down_persist_gate: persist_gate,
        down_retry_backoffs: [10],
        reresume_backoffs: [0]
      )

    {:ok, owner_pid} =
      AgentSupervisor.start_agent(agent,
        supervisor: supervisor,
        watcher: watcher,
        ttl_ms: 60_000,
        renew_interval_ms: 5_000
      )

    wait_for_idle(agent.id)
    [{^owner_pid, owner_token}] = Registry.lookup(AgentRegistry, agent.id)
    watcher_ref = watcher |> :sys.get_state() |> Map.fetch!(:pids) |> Map.fetch!(owner_pid)

    ref = Process.monitor(owner_pid)
    :ok = :sys.suspend(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner_pid, :killed}, 1_000
    assert_receive {:local_down_persist_blocked, ^watcher}, 1_000

    pending_key = {agent.id, owner_token}

    watcher_state = :sys.get_state(watcher)

    assert %{^pending_key => %{attempts: attempts, witness: witness}} =
             watcher_state.pending_downs

    assert attempts >= 1
    refute Map.has_key?(witness, :termination_capability)
    assert :ets.info(watcher_state.prepared_lease_capabilities, :protection) == :private
    assert :ets.info(watcher_state.prepared_lease_capabilities, :size) == 0
    assert :ets.info(watcher_state.local_down_capabilities, :protection) == :private

    assert_raise ArgumentError, fn ->
      :ets.tab2list(watcher_state.local_down_capabilities)
    end

    assert AgentLeases.owner?(agent.id, owner_token)
    assert AgentRestartGuards.get(agent.id) == nil

    true = :ets.insert(gate, {:allowed, true})

    guard =
      assert_eventually_value(fn ->
        case AgentRestartGuards.get(agent.id) do
          %{last_owner_token: ^owner_token, crash_count: 1} = guard -> guard
          _other -> nil
        end
      end)

    assert AgentLeases.get(agent.id) == nil
    incident = AgentTerminations.get_by_lease(owner_token)
    assert incident.status == "reconciled"
    assert Repo.aggregate(AgentTerminationProof, :count, :id) == 1

    assert {:ok, replacement} =
             AgentLeases.claim_recovery(agent.id, guard.generation, ttl_ms: 60_000)

    send(watcher, {:DOWN, watcher_ref, :process, owner_pid, :killed})
    _ = :sys.get_state(watcher)

    persisted = AgentRestartGuards.get(agent.id)
    assert persisted.generation == guard.generation
    assert persisted.crash_count == 1
    assert AgentLeases.get(agent.id).owner_token == replacement.owner_token
    assert Repo.aggregate(AgentTerminationProof, :count, :id) == 1

    stop_exact_runtime(supervisor, watcher)
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

  defp registered_owner(agent_id, owner_token) do
    parent = self()

    pid =
      spawn(fn ->
        result = Registry.register(AgentRegistry, agent_id, owner_token)
        send(parent, {:owner_registered, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:owner_registered, ^pid, {:ok, _owner}}, 1_000
    pid
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
           reresume_backoffs: Keyword.get(opts, :reresume_backoffs, [10]),
           crash_loop_max: Keyword.fetch!(opts, :crash_loop_max),
           crash_loop_window_ms: 60_000,
           down_persist_gate: Keyword.get(opts, :down_persist_gate),
           down_retry_backoffs: Keyword.get(opts, :down_retry_backoffs, [10])
         ]},
        id: watcher_name
      )

    {supervisor, watcher}
  end

  defp stop_exact_runtime(supervisor, watcher) do
    {:registered_name, watcher_name} = Process.info(watcher, :registered_name)
    {:registered_name, supervisor_name} = Process.info(supervisor, :registered_name)
    :ok = stop_supervised(watcher_name)
    :ok = stop_supervised(supervisor_name)
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

  defp assert_eventually_value(fun, attempts \\ 100)

  defp assert_eventually_value(fun, attempts) when attempts > 0 do
    case fun.() do
      nil -> retry_assertion(fn -> assert_eventually_value(fun, attempts - 1) end)
      false -> retry_assertion(fn -> assert_eventually_value(fun, attempts - 1) end)
      value -> value
    end
  end

  defp assert_eventually_value(_fun, 0),
    do: flunk("value was not available before timeout")

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

  defp retry_assertion(fun) do
    receive do
    after
      20 -> fun.()
    end
  end
end
