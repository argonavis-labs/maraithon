defmodule Maraithon.Runtime.AgentCapabilityControllerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.AgentWatcher

  test "preparation, confirmation, discard, and first track are caller-bound" do
    watcher = start_watcher()
    {:ok, agent} = running_agent("controller-bound")
    owner_token = Ecto.UUID.generate()
    controller = start_controller(watcher)

    send(controller, {:prepare, self(), agent.id, owner_token})
    assert_receive {:controller_result, ^controller, {:ok, digest}}, 1_000
    assert byte_size(digest) == 32

    preparation = preparation!(watcher, agent.id, owner_token)

    assert {:error, :agent_termination_controller_mismatch} =
             AgentWatcher.prepare_lease_capability(watcher, agent.id, owner_token)

    assert {:error, :agent_termination_controller_mismatch} =
             GenServer.call(
               watcher,
               {:confirm_lease_capability, preparation.capability_id, preparation.expected}
             )

    assert {:error, :agent_termination_controller_mismatch} =
             AgentWatcher.discard_lease_capability(watcher, agent.id, owner_token)

    assert {:error, :agent_termination_controller_mismatch} =
             AgentWatcher.track(watcher, self(), agent.id, owner_token)

    send(controller, {:discard, self(), agent.id, owner_token})
    assert_receive {:controller_result, ^controller, :ok}, 1_000
    assert_preparations_empty(watcher)

    send(
      controller,
      {:confirm, self(), preparation.capability_id, preparation.expected}
    )

    assert_receive {:controller_result, ^controller,
                    {:error, :agent_termination_capability_required}},
                   1_000

    send(controller, :stop)
  end

  test "forged controller DOWN remonitors while real controller death only scrubs preparation" do
    watcher = start_watcher()
    {:ok, agent} = running_agent("controller-down")
    first_owner = Ecto.UUID.generate()
    controller = start_controller(watcher)

    send(controller, {:prepare, self(), agent.id, first_owner})
    assert_receive {:controller_result, ^controller, {:ok, _digest}}, 1_000

    first = preparation!(watcher, agent.id, first_owner)
    send(watcher, {:DOWN, first.controller_ref, :process, controller, :forged})
    _ = :sys.get_state(watcher)

    remonitored = preparation!(watcher, agent.id, first_owner)
    refute remonitored.controller_ref == first.controller_ref
    assert remonitored.controller_pid == controller
    assert preparation_table_size(watcher) == 1
    assert AgentTerminations.get_by_lease(first_owner) == nil

    controller_ref = Process.monitor(controller)
    send(controller, :stop)
    assert_receive {:DOWN, ^controller_ref, :process, ^controller, :normal}, 1_000
    assert_eventually(fn -> preparation_count(watcher) == 0 end)
    assert preparation_table_size(watcher) == 0
    assert AgentTerminations.get_by_lease(first_owner) == nil
  end

  test "preparation TTL and global and per-controller capacities are bounded" do
    ttl_watcher = start_watcher(preparation_ttl_ms: 20)
    {:ok, agent} = running_agent("controller-ttl")
    owner_token = Ecto.UUID.generate()
    controller = start_controller(ttl_watcher)

    send(controller, {:prepare, self(), agent.id, owner_token})
    assert_receive {:controller_result, ^controller, {:ok, _digest}}, 1_000
    Process.send_after(self(), :ttl_barrier, 40)
    assert_receive :ttl_barrier, 1_000
    assert_eventually(fn -> preparation_count(ttl_watcher) == 0 end)
    assert preparation_table_size(ttl_watcher) == 0
    assert AgentTerminations.get_by_lease(owner_token) == nil

    send(controller, {:discard, self(), agent.id, owner_token})

    assert_receive {:controller_result, ^controller,
                    {:error, :agent_termination_capability_required}},
                   1_000

    send(controller, :stop)

    capacity_watcher =
      start_watcher(
        preparation_capacity: 2,
        preparation_per_controller_capacity: 1,
        preparation_ttl_ms: 5_000
      )

    first_key = {Ecto.UUID.generate(), Ecto.UUID.generate()}
    second_key = {Ecto.UUID.generate(), Ecto.UUID.generate()}
    third_key = {Ecto.UUID.generate(), Ecto.UUID.generate()}
    fourth_key = {Ecto.UUID.generate(), Ecto.UUID.generate()}

    assert {:ok, _digest} =
             AgentWatcher.prepare_lease_capability(
               capacity_watcher,
               elem(first_key, 0),
               elem(first_key, 1)
             )

    assert {:error, :agent_termination_controller_capacity} =
             AgentWatcher.prepare_lease_capability(
               capacity_watcher,
               elem(second_key, 0),
               elem(second_key, 1)
             )

    other_controller = start_controller(capacity_watcher)
    send(other_controller, {:prepare, self(), elem(third_key, 0), elem(third_key, 1)})
    assert_receive {:controller_result, ^other_controller, {:ok, _digest}}, 1_000

    rejected_controller = start_controller(capacity_watcher)
    send(rejected_controller, {:prepare, self(), elem(fourth_key, 0), elem(fourth_key, 1)})

    assert_receive {:controller_result, ^rejected_controller,
                    {:error, :agent_termination_preparation_capacity}},
                   1_000

    assert preparation_count(capacity_watcher) == 2
    assert preparation_table_size(capacity_watcher) == 2

    assert :ok =
             AgentWatcher.discard_lease_capability(
               capacity_watcher,
               elem(first_key, 0),
               elem(first_key, 1)
             )

    send(other_controller, :stop)
    send(rejected_controller, :stop)
    assert_eventually(fn -> preparation_count(capacity_watcher) == 0 end)
  end

  test "total capability capacity stays charged across preparation to adopted monitor" do
    watcher =
      start_watcher(
        total_capability_capacity: 1,
        preparation_capacity: 2,
        preparation_per_controller_capacity: 2,
        preparation_ttl_ms: 5_000
      )

    {:ok, agent} = running_agent("total-capability-monitor")
    assert {:ok, lease} = AgentLeases.claim(agent.id, watcher: watcher)
    assert total_capability_count(watcher) == 1

    blocked_key = {Ecto.UUID.generate(), Ecto.UUID.generate()}

    assert {:error, :agent_termination_capability_capacity} =
             AgentWatcher.prepare_lease_capability(
               watcher,
               elem(blocked_key, 0),
               elem(blocked_key, 1)
             )

    owner_pid = start_registered_owner(agent.id, lease.owner_token)
    assert :ok = AgentWatcher.track(watcher, owner_pid, agent.id, lease.owner_token)

    state = :sys.get_state(watcher)
    assert state.preparations == %{}
    assert map_size(state.monitors) == 1
    assert state.pending_downs == %{}
    assert total_capability_count(state) == 1
    assert :ets.info(state.prepared_lease_capabilities, :size) == 0
    assert :ets.info(state.local_down_capabilities, :size) == 1

    assert {:error, :agent_termination_capability_capacity} =
             AgentWatcher.prepare_lease_capability(
               watcher,
               elem(blocked_key, 0),
               elem(blocked_key, 1)
             )

    unchanged = :sys.get_state(watcher)
    assert Map.has_key?(unchanged.pids, owner_pid)
    assert total_capability_count(unchanged) == 1

    {:ok, watcherless_agent} = running_agent("total-capability-watcherless")
    assert {:ok, watcherless_lease} = AgentLeases.claim(watcherless_agent.id)
    assert watcherless_lease.termination_capability_digest == nil
    assert total_capability_count(watcher) == 1
  end

  test "total capability capacity stays charged from monitor to pending during database failure" do
    test_pid = self()
    gate = :ets.new(:agent_capability_capacity_persist_gate, [:set, :public])
    true = :ets.insert(gate, {:allowed, false})

    persist_gate = fn ->
      case :ets.lookup(gate, :allowed) do
        [{:allowed, true}] ->
          :ok

        _blocked ->
          send(test_pid, {:capacity_persist_blocked, self()})
          {:error, :simulated_database_unavailable}
      end
    end

    watcher =
      start_watcher(
        total_capability_capacity: 1,
        preparation_capacity: 2,
        preparation_per_controller_capacity: 2,
        preparation_ttl_ms: 5_000,
        down_persist_gate: persist_gate,
        down_retry_backoffs: [30_000]
      )

    {:ok, agent} = running_agent("total-capability-pending")
    assert {:ok, lease} = AgentLeases.claim(agent.id, watcher: watcher)
    owner_pid = start_registered_owner(agent.id, lease.owner_token)
    assert :ok = AgentWatcher.track(watcher, owner_pid, agent.id, lease.owner_token)
    assert total_capability_count(watcher) == 1

    owner_ref = Process.monitor(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}, 1_000
    assert_receive {:capacity_persist_blocked, ^watcher}, 1_000

    pending_key = {agent.id, lease.owner_token}
    pending_state = :sys.get_state(watcher)

    assert pending_state.monitors == %{}
    assert %{^pending_key => pending} = pending_state.pending_downs
    assert is_reference(pending.retry_tag)
    assert total_capability_count(pending_state) == 1
    assert :ets.info(pending_state.local_down_capabilities, :size) == 1

    blocked_key = {Ecto.UUID.generate(), Ecto.UUID.generate()}

    assert {:error, :agent_termination_capability_capacity} =
             AgentWatcher.prepare_lease_capability(
               watcher,
               elem(blocked_key, 0),
               elem(blocked_key, 1)
             )

    still_pending = :sys.get_state(watcher)
    still_pending_entry = Map.fetch!(still_pending.pending_downs, pending_key)
    assert still_pending_entry.witness.capability_id == pending.witness.capability_id
    assert total_capability_count(still_pending) == 1
    assert AgentLeases.owner?(agent.id, lease.owner_token)

    true = :ets.insert(gate, {:allowed, true})
    send(watcher, {:retry_local_down, pending_key, pending.retry_tag})

    assert_eventually(fn -> total_capability_count(watcher) == 0 end)
    assert AgentLeases.get(agent.id) == nil

    assert {:ok, _digest} =
             AgentWatcher.prepare_lease_capability(
               watcher,
               elem(blocked_key, 0),
               elem(blocked_key, 1)
             )

    assert total_capability_count(watcher) == 1

    assert :ok =
             AgentWatcher.discard_lease_capability(
               watcher,
               elem(blocked_key, 0),
               elem(blocked_key, 1)
             )

    assert total_capability_count(watcher) == 0
  end

  test "state, API envelopes, and closure environments never expose the private preimage" do
    watcher = start_watcher()
    {:ok, agent} = running_agent("controller-secret-boundary")
    owner_token = Ecto.UUID.generate()

    assert {:ok, digest} =
             AgentWatcher.prepare_lease_capability(watcher, agent.id, owner_token)

    envelope =
      GenServer.call(watcher, {:prepare_lease_capability, agent.id, owner_token})

    assert {:ok, ^digest, _capability_id, capability} = envelope
    assert {:env, environment} = :erlang.fun_info(capability, :env)

    state = :sys.get_state(watcher)
    exposed_32_byte_values = binaries_of_size([state, envelope, environment], 32)
    assert exposed_32_byte_values != []
    assert Enum.all?(exposed_32_byte_values, &Plug.Crypto.secure_compare(&1, digest))

    assert_raise ArgumentError, fn ->
      :ets.tab2list(state.prepared_lease_capabilities)
    end

    assert :ok = AgentWatcher.discard_lease_capability(watcher, agent.id, owner_token)
    assert_preparations_empty(watcher)
  end

  test "durable lease checks gate honest preparation and mismatched preparations cannot hijack" do
    watcher = start_watcher()
    {:ok, external_agent} = running_agent("controller-existing-external")
    assert {:ok, external_lease} = AgentLeases.claim(external_agent.id)
    assert external_lease.termination_capability_digest == nil

    assert {:error, :runtime_lease_owned} =
             AgentLeases.claim(external_agent.id, watcher: watcher)

    assert_preparations_empty(watcher)

    assert {:ok, _mismatched_digest} =
             AgentWatcher.prepare_lease_capability(
               watcher,
               external_agent.id,
               external_lease.owner_token
             )

    assert {:ok, _registered} =
             Registry.register(
               AgentRegistry,
               external_agent.id,
               external_lease.owner_token
             )

    assert {:error, :agent_termination_capability_mismatch} =
             AgentWatcher.track(
               watcher,
               self(),
               external_agent.id,
               external_lease.owner_token
             )

    assert AgentTerminations.get_by_lease(external_lease.owner_token) == nil

    assert :ok =
             AgentWatcher.discard_lease_capability(
               watcher,
               external_agent.id,
               external_lease.owner_token
             )

    assert {:error, :agent_termination_preparation_required} =
             GenServer.call(
               watcher,
               {:issue_lease_capability, external_agent.id, Ecto.UUID.generate()}
             )

    assert_preparations_empty(watcher)

    {:ok, tracked_agent} = running_agent("controller-existing-tracked")
    {supervisor, lifecycle_watcher} = exact_runtime()
    lifecycle_controller = start_controller(lifecycle_watcher)

    send(lifecycle_controller, {:start_agent, self(), tracked_agent, supervisor})

    assert_receive {:controller_result, ^lifecycle_controller, {:ok, owner_pid}}, 2_000
    [{^owner_pid, owner_token}] = Registry.lookup(AgentRegistry, tracked_agent.id)
    local_lease = AgentLeases.get(tracked_agent.id)
    assert local_lease.owner_token == owner_token
    assert byte_size(local_lease.termination_capability_digest) == 32
    assert_preparations_empty(lifecycle_watcher)

    assert {:error, :owner_already_tracked} =
             AgentWatcher.prepare_lease_capability(
               lifecycle_watcher,
               tracked_agent.id,
               owner_token
             )

    send(
      lifecycle_controller,
      {:track, self(), owner_pid, tracked_agent.id, owner_token}
    )

    assert_receive {:controller_result, ^lifecycle_controller, :ok}, 1_000

    assert {:error, :agent_termination_controller_mismatch} =
             AgentWatcher.track(
               lifecycle_watcher,
               owner_pid,
               tracked_agent.id,
               owner_token
             )

    before_controller_down = :sys.get_state(lifecycle_watcher)
    assert map_size(before_controller_down.monitors) == 1
    assert :ets.info(before_controller_down.local_down_capabilities, :size) == 1

    controller_ref = Process.monitor(lifecycle_controller)
    send(lifecycle_controller, :stop)

    assert_receive {:DOWN, ^controller_ref, :process, ^lifecycle_controller, :normal}, 1_000
    _ = :sys.get_state(lifecycle_watcher)

    after_controller_down = :sys.get_state(lifecycle_watcher)
    assert map_size(after_controller_down.monitors) == 1
    assert :ets.info(after_controller_down.local_down_capabilities, :size) == 1
    assert AgentTerminations.get_by_lease(owner_token) == nil
  end

  defp start_watcher(opts \\ []) do
    name = :"agent_capability_watcher_#{System.unique_integer([:positive])}"

    start_supervised!(
      {AgentWatcher,
       Keyword.merge(
         [name: name, reconcile?: false, recover?: false, shutdown_down_barrier_ms: 0],
         opts
       )},
      id: name
    )
  end

  defp exact_runtime do
    suffix = System.unique_integer([:positive])
    supervisor_name = :"agent_capability_supervisor_#{suffix}"

    supervisor =
      start_supervised!(
        {DynamicSupervisor,
         strategy: :one_for_one, name: supervisor_name, max_restarts: 20, max_seconds: 60},
        id: supervisor_name
      )

    watcher = start_watcher(agent_supervisor: supervisor)
    {supervisor, watcher}
  end

  defp start_controller(watcher) do
    test_pid = self()
    id = {:agent_capability_controller, make_ref()}

    start_supervised!(
      {Task, fn -> controller_loop(test_pid, watcher) end},
      id: id
    )
  end

  defp start_registered_owner(agent_id, owner_token) do
    test_pid = self()
    id = {:agent_capability_owner, make_ref()}

    owner_pid =
      start_supervised!(
        {Task,
         fn ->
           result = Registry.register(AgentRegistry, agent_id, owner_token)
           send(test_pid, {:agent_capability_owner_registered, self(), result})

           receive do
             :stop -> :ok
           end
         end},
        id: id
      )

    assert_receive {:agent_capability_owner_registered, ^owner_pid, {:ok, _registered}}, 1_000
    owner_pid
  end

  defp controller_loop(test_pid, watcher) do
    receive do
      {:prepare, reply_to, agent_id, owner_token} ->
        result = AgentWatcher.prepare_lease_capability(watcher, agent_id, owner_token)
        send(reply_to, {:controller_result, self(), result})
        controller_loop(test_pid, watcher)

      {:discard, reply_to, agent_id, owner_token} ->
        result = AgentWatcher.discard_lease_capability(watcher, agent_id, owner_token)
        send(reply_to, {:controller_result, self(), result})
        controller_loop(test_pid, watcher)

      {:confirm, reply_to, capability_id, expected} ->
        result =
          GenServer.call(
            watcher,
            {:confirm_lease_capability, capability_id, expected}
          )

        send(reply_to, {:controller_result, self(), result})
        controller_loop(test_pid, watcher)

      {:track, reply_to, pid, agent_id, owner_token} ->
        result = AgentWatcher.track(watcher, pid, agent_id, owner_token)
        send(reply_to, {:controller_result, self(), result})
        controller_loop(test_pid, watcher)

      {:start_agent, reply_to, agent, supervisor} ->
        result =
          AgentSupervisor.start_agent(agent,
            supervisor: supervisor,
            watcher: watcher,
            ttl_ms: 60_000,
            renew_interval_ms: 30_000
          )

        send(reply_to, {:controller_result, self(), result})
        controller_loop(test_pid, watcher)

      :stop ->
        :ok
    after
      5_000 ->
        send(test_pid, {:controller_timeout, self()})
        :ok
    end
  end

  defp preparation!(watcher, agent_id, owner_token) do
    watcher
    |> :sys.get_state()
    |> Map.fetch!(:preparations)
    |> Map.fetch!({agent_id, owner_token})
  end

  defp preparation_count(watcher) do
    watcher
    |> :sys.get_state()
    |> Map.fetch!(:preparations)
    |> map_size()
  end

  defp total_capability_count(watcher) when is_pid(watcher) do
    watcher
    |> :sys.get_state()
    |> total_capability_count()
  end

  defp total_capability_count(state) when is_map(state) do
    map_size(state.preparations) + map_size(state.monitors) + map_size(state.pending_downs)
  end

  defp preparation_table_size(watcher) do
    watcher
    |> :sys.get_state()
    |> Map.fetch!(:prepared_lease_capabilities)
    |> :ets.info(:size)
  end

  defp assert_preparations_empty(watcher) do
    state = :sys.get_state(watcher)
    assert state.preparations == %{}
    assert state.preparation_controller_refs == %{}
    assert state.preparation_counts == %{}
    assert :ets.info(state.prepared_lease_capabilities, :size) == 0
  end

  defp binaries_of_size(term, size) when is_binary(term) do
    if byte_size(term) == size, do: [term], else: []
  end

  defp binaries_of_size(term, size) when is_function(term) do
    case :erlang.fun_info(term, :env) do
      {:env, environment} -> binaries_of_size(environment, size)
      _other -> []
    end
  end

  defp binaries_of_size(term, size) when is_map(term) do
    Enum.flat_map(term, fn {key, value} ->
      binaries_of_size(key, size) ++ binaries_of_size(value, size)
    end)
  end

  defp binaries_of_size(term, size) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> binaries_of_size(size)
  end

  defp binaries_of_size(term, size) when is_list(term) do
    Enum.flat_map(term, &binaries_of_size(&1, size))
  end

  defp binaries_of_size(_term, _size), do: []

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
         {:ok, _binding} <-
           AgentIsolation.grant_binding_consent(agent, binding_consent(agent)) do
      {:ok, agent}
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      receive do
      after
        5 -> assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met before timeout")
end
