defmodule Maraithon.Runtime.AgentExactLifecycleTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Effects
  alias Maraithon.Effects.Effect
  alias Maraithon.Events
  alias Maraithon.Repo
  alias Maraithon.Runtime
  alias Maraithon.Runtime.Agent, as: RuntimeAgent
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.Snapshot

  test "preclaims a ready exact lease and exposes only local token metadata" do
    agent = running_agent("exact-launch")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} = start_exact(agent, supervisor, watcher)
    wait_for_state(pid, :idle)

    assert [{^pid, owner_token}] = Registry.lookup(AgentRegistry, agent.id)
    assert {:ok, ^owner_token} = Ecto.UUID.cast(owner_token)

    lease = AgentLeases.get(agent.id)
    assert lease.owner_token == owner_token
    assert lease.ready_at != nil
    assert lease.draining_at == nil
    assert Agents.get_agent(agent.id).status == "running"
    assert :global.whereis_name({:maraithon_agent, agent.id}) == :undefined

    assert RuntimeAgent.child_spec(%{agent: agent, owner_token: owner_token}).restart ==
             :temporary

    assert :ok = AgentSupervisor.stop_agent(pid, "test_cleanup", owner_token)
    assert AgentLeases.get(agent.id) == nil
    assert AgentRestartGuards.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "running"
  end

  test "renews the same owner token in every resident state" do
    agent = running_agent("exact-renewal")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 2_000, renew_interval_ms: 50)

    wait_for_state(pid, :idle)

    expected_token = registry_token(agent.id)

    Enum.each([:idle, :working, :waiting_effect, :recovering], fn state ->
      :sys.replace_state(pid, fn {_old_state, data} -> {state, data} end)
      previous = AgentLeases.get(agent.id).renewed_at

      assert_eventually(fn ->
        case AgentLeases.get(agent.id) do
          %{renewed_at: renewed_at, owner_token: owner_token} ->
            owner_token == expected_token and DateTime.compare(renewed_at, previous) == :gt

          _other ->
            false
        end
      end)
    end)

    :sys.replace_state(pid, fn {_old_state, data} -> {:idle, data} end)
    assert :ok = AgentSupervisor.stop_agent(pid, "test_cleanup", expected_token)
    assert AgentLeases.get(agent.id) == nil
  end

  test "guards a live-lease DOWN before admitting a fresh recovery generation" do
    agent = running_agent("exact-recovery")
    {supervisor, watcher} = exact_runtime(recover?: false, reresume_backoffs: [0])

    {:ok, first_pid} = start_exact(agent, supervisor, watcher)
    wait_for_state(first_pid, :idle)
    first_token = registry_token(agent.id)

    ref = Process.monitor(first_pid)
    Process.exit(first_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}, 1_000

    guard =
      assert_eventually_value(fn ->
        case AgentRestartGuards.get(agent.id) do
          %{last_owner_token: ^first_token, needs_recovery: true} = guard -> guard
          _other -> nil
        end
      end)

    assert AgentLeases.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "running"

    {:ok, recovered_pid} =
      start_exact(agent, supervisor, watcher, recovery_generation: guard.generation)

    wait_for_state(recovered_pid, :idle)
    recovered_token = registry_token(agent.id)
    refute recovered_token == first_token

    recovered_guard = AgentRestartGuards.get(agent.id)
    assert recovered_guard.generation == guard.generation
    refute recovered_guard.needs_recovery

    lease = AgentLeases.get(agent.id)
    assert lease.owner_token == recovered_token
    assert lease.ready_at != nil

    recovered_ref = Process.monitor(recovered_pid)
    send(recovered_pid, {:agent_dispatch, {:control, :stop, "delayed_old", first_token}})
    send(recovered_pid, {:agent_dispatch, {:control, :stop, "legacy_unqualified"}})
    refute_receive {:DOWN, ^recovered_ref, :process, ^recovered_pid, _reason}, 100
    assert Process.alive?(recovered_pid)
    assert registry_token(agent.id) == recovered_token

    started = agent.id |> Events.list_events(limit: 20) |> List.last()
    assert started.event_type == "agent_started"
    assert DateTime.compare(started.created_at, lease.ready_at) in [:eq, :gt]

    send(
      recovered_pid,
      {:agent_dispatch, {:control, :stop, "test_cleanup", recovered_token}}
    )

    assert_receive {:DOWN, ^recovered_ref, :process, ^recovered_pid, :normal}, 1_000
    assert AgentLeases.get(agent.id) == nil
  end

  test "a stale incarnation exits without mutating current durable work" do
    agent = running_agent("stale-stop")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 5_000, renew_interval_ms: 1_000)

    wait_for_state(pid, :idle)
    owner_token = registry_token(agent.id)
    {:ok, effect_id} = Effects.request(agent.id, :tool_call, "time", %{})

    assert {:recorded, _guard} =
             AgentRestartGuards.record_crash(agent.id, owner_token, :simulated_owner_loss,
               backoffs_ms: [0]
             )

    ref = Process.monitor(pid)
    send(pid, {:agent_dispatch, {:control, :stop, "stale_control", owner_token}})
    assert_receive {:DOWN, ^ref, :process, ^pid, _stale_exit_reason}, 1_000

    assert Repo.get!(Effect, effect_id).status == "pending"

    assert %{last_owner_token: ^owner_token, needs_recovery: true} =
             AgentRestartGuards.get(agent.id)
  end

  test "Runtime stop fences the local token before exact cleanup and release" do
    agent = running_agent("local-runtime-stop")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 5_000, renew_interval_ms: 1_000)

    wait_for_state(pid, :idle)
    {:ok, effect_id} = Effects.request(agent.id, :tool_call, "time", %{})
    ref = Process.monitor(pid)

    assert {:ok, %{drain_status: :quiesced, stopped_at: %DateTime{}}} =
             Runtime.stop_agent(agent.id, "local_exact_stop")

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert AgentLeases.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "stopped"
    assert Repo.get!(Effect, effect_id).status == "cancelled"
  end

  test "lease-free local PID remains pending without an unqualified bridge stop" do
    agent = running_agent("legacy-bridge-pending")
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _registered} = Registry.register(AgentRegistry, agent.id, :legacy_unfenced)
        send(parent, {:legacy_registered, self()})

        receive do
          message -> send(parent, {:legacy_received, message})
        end
      end)

    assert_receive {:legacy_registered, ^pid}, 1_000

    assert {:ok, %{drain_status: :reconciliation_pending}} =
             Runtime.stop_agent(agent.id, "legacy_pending")

    refute_receive {:legacy_received, _message}, 100
    assert Process.alive?(pid)
    Process.exit(pid, :kill)
  end

  test "an unreachable remote owner is fenced without broad work cancellation" do
    agent = running_agent("remote-runtime-stop")
    lease = ready_manual_lease(agent, "remote-owner@runtime-stop")
    {:ok, effect_id} = Effects.request(agent.id, :tool_call, "time", %{})

    assert {:ok, %{drain_status: :reconciliation_pending}} =
             Runtime.stop_agent(agent.id, "remote_exact_stop")

    stopped_agent = Agents.get_agent(agent.id)
    fenced_lease = AgentLeases.get(agent.id)

    assert stopped_agent.status == "stopped"
    assert fenced_lease.owner_token == lease.owner_token
    assert fenced_lease.owner_node == "remote-owner@runtime-stop"
    assert fenced_lease.ready_at == nil
    assert fenced_lease.draining_at != nil
    assert Repo.get!(Effect, effect_id).status == "pending"
  end

  test "a concurrent start cannot flip stopped intent while a drain token exists" do
    agent = running_agent("drain-start-race")
    lease = ready_manual_lease(agent, "remote-owner@start-race")

    assert {:ok, %{lease_state: :live}} = AgentLeases.fence_for_stop(agent.id)
    assert Agents.get_agent(agent.id).status == "stopped"

    assert {:error, :agent_drain_pending} = Runtime.start_existing_agent(agent.id)
    assert Agents.get_agent(agent.id).status == "stopped"
    assert AgentLeases.get(agent.id).owner_token == lease.owner_token
  end

  test "an already-draining exact owner can settle after desired status changes again" do
    agent = running_agent("drain-status-flip")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 5_000, renew_interval_ms: 2_000)

    wait_for_state(pid, :idle)
    owner_token = registry_token(agent.id)
    {:ok, effect_id} = Effects.request(agent.id, :tool_call, "time", %{})

    assert {:ok, %{agent: stopped_agent, lease_state: :live}} =
             AgentLeases.fence_for_stop(agent.id)

    assert {:ok, _terminated_agent} = Agents.update_agent(stopped_agent, %{status: "terminated"})

    ref = Process.monitor(pid)
    send(pid, {:agent_dispatch, {:control, :stop, "status_changed", owner_token}})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    assert AgentLeases.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "terminated"
    assert Repo.get!(Effect, effect_id).status == "cancelled"
  end

  test "a delayed DOWN guards the fenced token without cancelling remote work" do
    agent = running_agent("delayed-down")
    {_supervisor, watcher} = exact_runtime(recover?: false)
    lease = ready_manual_lease(agent, "remote-owner@delayed-down")
    {:ok, effect_id} = Effects.request(agent.id, :tool_call, "time", %{})

    dummy = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = AgentWatcher.track(watcher, dummy, agent.id, lease.owner_token)

    assert {:ok, %{drain_status: :reconciliation_pending}} =
             Runtime.stop_agent(agent.id, "remote_delayed_down")

    assert Repo.get!(Effect, effect_id).status == "pending"
    assert AgentLeases.get(agent.id).draining_at != nil

    ref = Process.monitor(dummy)
    Process.exit(dummy, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dummy, :killed}, 1_000

    assert_eventually(fn ->
      match?(
        %{last_owner_token: owner_token, needs_recovery: true}
        when owner_token == lease.owner_token,
        AgentRestartGuards.get(agent.id)
      )
    end)

    assert AgentLeases.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "stopped"
    assert Repo.get!(Effect, effect_id).status == "pending"
  end

  test "an expired stop records exact loss and never resurrects drain authority" do
    agent = running_agent("expired-runtime-stop")
    lease = ready_manual_lease(agent, Atom.to_string(node()))
    {:ok, effect_id} = Effects.request(agent.id, :tool_call, "time", %{})

    expired_until = DateTime.add(lease.ready_at, 1, :microsecond)

    lease
    |> Ecto.Changeset.change(%{lease_until: expired_until})
    |> Repo.update!()

    assert {:ok, %{drain_status: :reconciliation_pending}} =
             Runtime.stop_agent(agent.id, "expired_exact_stop")

    stopped_agent = Agents.get_agent(agent.id)
    guard = AgentRestartGuards.get(agent.id)

    assert stopped_agent.status == "stopped"
    assert AgentLeases.get(agent.id) == nil
    assert guard.last_owner_token == lease.owner_token
    assert guard.needs_recovery
    assert DateTime.compare(guard.updated_at, stopped_agent.stopped_at) in [:lt, :eq]
    assert Repo.get!(Effect, effect_id).status == "pending"
  end

  test "checkpoint Event and Snapshot are atomic against exact lease loss" do
    agent = running_agent("checkpoint-loss")
    {supervisor, watcher} = exact_runtime(recover?: false)

    {:ok, pid} =
      start_exact(agent, supervisor, watcher, ttl_ms: 5_000, renew_interval_ms: 2_000)

    wait_for_state(pid, :idle)
    owner_token = registry_token(agent.id)
    assert Snapshot.latest(agent.id) == nil

    send(pid, {:wakeup, "checkpoint", Ecto.UUID.generate(), %{}})

    assert {:recorded, _guard} =
             AgentRestartGuards.record_crash(agent.id, owner_token, :checkpoint_race,
               backoffs_ms: [0]
             )

    if Process.alive?(pid) do
      try do
        _state = :sys.get_state(pid, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end

    checkpoint_events =
      agent.id
      |> Events.list_events(limit: 20)
      |> Enum.filter(&(&1.event_type == "checkpoint_created"))

    case {checkpoint_events, Snapshot.latest(agent.id)} do
      {[], nil} ->
        :ok

      {[checkpoint_event], snapshot} when is_map(snapshot) ->
        assert snapshot.sequence_num == checkpoint_event.sequence_num

      inconsistent ->
        flunk("checkpoint Event/Snapshot were not atomic: #{inspect(inconsistent)}")
    end

    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  test "does not claim when the mandatory watcher is unavailable" do
    agent = running_agent("watcher-preclaim")
    supervisor = exact_supervisor()
    missing_watcher = :"missing_watcher_#{System.unique_integer([:positive])}"

    assert {:error, :watcher_unavailable} =
             AgentSupervisor.start_agent(agent,
               admission: :bootstrap,
               supervisor: supervisor,
               watcher: missing_watcher,
               ttl_ms: 2_000,
               renew_interval_ms: 50
             )

    assert AgentLeases.get(agent.id) == nil
    assert AgentRestartGuards.get(agent.id) == nil
  end

  test "releases a definitely unspawned claim when the supervisor is absent" do
    agent = running_agent("definite-spawn-failure")
    {_supervisor, watcher} = exact_runtime(recover?: false)
    missing_supervisor = :"missing_supervisor_#{System.unique_integer([:positive])}"

    assert {:error, :noproc} =
             AgentSupervisor.start_agent(agent,
               admission: :bootstrap,
               supervisor: missing_supervisor,
               watcher: watcher,
               ttl_ms: 2_000,
               renew_interval_ms: 50
             )

    assert AgentLeases.get(agent.id) == nil
    assert AgentRestartGuards.get(agent.id) == nil
  end

  defp running_agent(name) do
    user_id = "#{name}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        started_at: DateTime.utc_now(),
        config: %{
          "name" => name,
          "prompt" => "test",
          "subscribe" => [],
          "tools" => []
        }
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    agent
  end

  defp ready_manual_lease(agent, owner_node) do
    {:ok, claimed} = AgentLeases.claim(agent.id, ttl_ms: 5_000)
    {:ok, ready} = AgentLeases.mark_ready(agent.id, claimed.owner_token)

    ready
    |> Ecto.Changeset.change(%{owner_node: owner_node})
    |> Repo.update!()
  end

  defp exact_runtime(opts) do
    supervisor = exact_supervisor()
    suffix = System.unique_integer([:positive])
    watcher_name = :"exact_watcher_#{suffix}"

    watcher =
      start_supervised!(
        {AgentWatcher,
         [
           name: watcher_name,
           agent_supervisor: supervisor,
           reconcile?: false,
           recover?: Keyword.get(opts, :recover?, true),
           reresume_backoffs: Keyword.get(opts, :reresume_backoffs, [0]),
           crash_loop_max: 3,
           crash_loop_window_ms: 60_000
         ]},
        id: watcher_name
      )

    {supervisor, watcher}
  end

  defp exact_supervisor do
    suffix = System.unique_integer([:positive])
    name = :"exact_supervisor_#{suffix}"

    start_supervised!(
      {DynamicSupervisor, strategy: :one_for_one, name: name, max_restarts: 20, max_seconds: 60},
      id: name
    )
  end

  defp start_exact(agent, supervisor, watcher, opts \\ []) do
    AgentSupervisor.start_agent(
      agent,
      Keyword.merge(
        [
          admission: :bootstrap,
          supervisor: supervisor,
          watcher: watcher,
          ttl_ms: 5_000,
          renew_interval_ms: 100
        ],
        opts
      )
    )
  end

  defp registry_token(agent_id) do
    case Registry.lookup(AgentRegistry, agent_id) do
      [{_pid, owner_token}] -> owner_token
      _other -> nil
    end
  end

  defp wait_for_state(pid, expected), do: wait_for_state(pid, expected, 100)

  defp wait_for_state(_pid, expected, 0), do: flunk("Agent did not enter #{expected}")

  defp wait_for_state(pid, expected, attempts) do
    try do
      case :sys.get_state(pid) do
        {^expected, _data} -> :ok
        _other -> retry(fn -> wait_for_state(pid, expected, attempts - 1) end)
      end
    catch
      :exit, _reason -> retry(fn -> wait_for_state(pid, expected, attempts - 1) end)
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.(), do: :ok, else: retry(fn -> assert_eventually(fun, attempts - 1) end)
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met before timeout")

  defp assert_eventually_value(fun, attempts \\ 100)

  defp assert_eventually_value(fun, attempts) when attempts > 0 do
    case fun.() do
      nil -> retry(fn -> assert_eventually_value(fun, attempts - 1) end)
      false -> retry(fn -> assert_eventually_value(fun, attempts - 1) end)
      value -> value
    end
  end

  defp assert_eventually_value(_fun, 0), do: flunk("value was not available before timeout")

  defp retry(fun) do
    Process.sleep(20)
    fun.()
  end
end
