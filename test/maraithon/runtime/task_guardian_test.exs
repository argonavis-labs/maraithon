defmodule Maraithon.Runtime.TaskGuardianTest do
  use ExUnit.Case, async: false

  alias Maraithon.Runtime.{EffectTaskAuthority, EffectTaskSupervisor, TaskGuardian}

  @effect_supervisor Maraithon.Runtime.EffectTaskSupervisor
  @task_supervisor Maraithon.Runtime.ExactEffectTaskSupervisor
  @registry Maraithon.Runtime.EffectTaskRegistry

  setup do
    _ = :sys.get_state(@effect_supervisor)
    _ = :sys.get_state(Maraithon.Runtime.Coordination.TaskSupervisor)
    :ok
  end

  test "deleted cleanup entries do not consume the live cleanup retry budget" do
    restart_task_system!()
    on_exit(&restart_task_system!/0)

    authority = Process.whereis(EffectTaskAuthority)
    initial_state = :sys.get_state(authority)
    assert :queue.is_empty(initial_state.cleanup_queue)
    assert MapSet.size(initial_state.cleanup_set) == 0
    assert is_nil(initial_state.cleanup_timer)

    :sys.replace_state(authority, fn state ->
      %{state | cleanup_retry_ms: 600_000}
    end)

    leading_tombstones =
      for _index <- 1..2 do
        identity = enqueue_bound_task_cleanup!()
        assert :ok = EffectTaskSupervisor.release(identity)
        identity
      end

    live_identity = enqueue_bound_task_cleanup!()
    trailing_tombstone = enqueue_bound_task_cleanup!()
    assert :ok = EffectTaskSupervisor.release(trailing_tombstone)

    queued_state = :sys.get_state(authority)

    assert :queue.to_list(queued_state.cleanup_queue) ==
             Enum.map(leading_tombstones, & &1.task_id) ++
               [live_identity.task_id, trailing_tombstone.task_id]

    assert MapSet.equal?(queued_state.cleanup_set, MapSet.new([live_identity.task_id]))
    assert is_reference(queued_state.cleanup_timer)

    _ = Process.cancel_timer(queued_state.cleanup_timer)
    :sys.replace_state(authority, fn state -> %{state | cleanup_timer: nil} end)
    send(authority, :retry_effect_task_cleanup)

    retried_state = :sys.get_state(authority, 15_000)

    assert :queue.to_list(retried_state.cleanup_queue) ==
             [trailing_tombstone.task_id, live_identity.task_id]

    assert MapSet.equal?(retried_state.cleanup_set, MapSet.new([live_identity.task_id]))
    assert Map.has_key?(retried_state.reservations, live_identity.task_id)
  end

  test "generation access is bound to its exact controller PID" do
    physical_supervisor =
      start_supervised!(
        Supervisor.child_spec({Task.Supervisor, []}, id: :controller_bound_supervisor)
      )

    guardian = Process.whereis(TaskGuardian)
    assert {:ok, access} = TaskGuardian.open_generation(guardian, :effect, physical_supervisor)
    identity = guardian_effect_identity(access.supervisor_id)
    test_pid = self()

    spawn(fn ->
      send(
        test_pid,
        {:foreign_reopen, TaskGuardian.open_generation(guardian, :effect, physical_supervisor)}
      )

      send(test_pid, {:foreign_replay, TaskGuardian.reserve(access, identity)})
    end)

    assert_receive {:foreign_reopen, {:error, :task_guardian_controller_mismatch}}, 2_000
    assert_receive {:foreign_replay, {:error, :task_guardian_access_lost}}, 2_000
    assert :ok = TaskGuardian.reserve(access, identity)
  end

  test "a generation waits for supervisor DOWN and every registered task DOWN" do
    physical_supervisor =
      start_supervised!(
        Supervisor.child_spec({Task.Supervisor, []}, id: :guardian_barrier_supervisor)
      )

    guardian = Process.whereis(TaskGuardian)
    assert {:ok, access} = TaskGuardian.open_generation(guardian, :effect, physical_supervisor)
    reserved = guardian_effect_identity(access.supervisor_id)
    active = guardian_effect_identity(access.supervisor_id)
    assert :ok = TaskGuardian.reserve(access, reserved)
    assert :ok = TaskGuardian.reserve(access, active)
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
        send(test_pid, {:barrier_task_ready, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:barrier_task_ready, task_pid}, 2_000
    assert :ok = TaskGuardian.activate(access, active, task_pid)

    supervisor_ref = Process.monitor(physical_supervisor)
    Process.exit(physical_supervisor, :kill)

    assert_receive {:DOWN, ^supervisor_ref, :process, ^physical_supervisor, _reason}, 2_000
    _ = :sys.get_state(TaskGuardian)

    assert {:pending, :supervisor_down_not_proven} = TaskGuardian.proof(access, reserved)
    send(task_pid, :finish)
    assert_receive {:DOWN, ref, :process, ^task_pid, :normal} when ref == task.ref, 2_000
    _ = :sys.get_state(TaskGuardian)

    assert {:ok, {:supervisor_down_before_activation, _proof}} =
             TaskGuardian.proof(access, reserved)

    assert {:ok, {:task_down, _proof}} = TaskGuardian.proof(access, active)
  end

  test "closed generation rejects new reservations but preserves historical proof access" do
    physical_supervisor =
      start_supervised!(
        Supervisor.child_spec({Task.Supervisor, []}, id: :closed_generation_supervisor)
      )

    guardian = Process.whereis(TaskGuardian)
    assert {:ok, access} = TaskGuardian.open_generation(guardian, :effect, physical_supervisor)
    existing = guardian_effect_identity(access.supervisor_id)
    assert :ok = TaskGuardian.reserve(access, existing)

    supervisor_ref = Process.monitor(physical_supervisor)
    Process.exit(physical_supervisor, :kill)
    assert_receive {:DOWN, ^supervisor_ref, :process, ^physical_supervisor, _reason}, 2_000
    _ = :sys.get_state(guardian)

    fresh = guardian_effect_identity(access.supervisor_id)
    assert {:error, :task_guardian_generation_closed} = TaskGuardian.reserve(access, fresh)

    assert {:ok, {:supervisor_down_before_activation, _proof}} =
             TaskGuardian.proof(access, existing)
  end

  test "forged task and supervisor DOWN tuples are remonitored without releasing proof" do
    physical_supervisor =
      start_supervised!(
        Supervisor.child_spec({Task.Supervisor, []}, id: :guardian_spoof_supervisor)
      )

    guardian = Process.whereis(TaskGuardian)
    assert {:ok, access} = TaskGuardian.open_generation(guardian, :effect, physical_supervisor)
    identity = guardian_effect_identity(access.supervisor_id)
    assert :ok = TaskGuardian.reserve(access, identity)
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
        send(test_pid, {:spoof_task_ready, self()})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:spoof_task_ready, task_pid}, 2_000
    assert :ok = TaskGuardian.activate(access, identity, task_pid)

    generation_key = {:effect, access.supervisor_id}
    state = :sys.get_state(guardian)
    generation = Map.fetch!(state.generations, generation_key)

    {_identity_key, record} =
      Enum.find(generation.identities, fn {_key, record} -> record.identity == identity end)

    old_task_ref = record.task_ref
    send(guardian, {:DOWN, old_task_ref, :process, task_pid, :killed})
    state = :sys.get_state(guardian)
    generation = Map.fetch!(state.generations, generation_key)

    {_identity_key, remonitored} =
      Enum.find(generation.identities, fn {_key, record} -> record.identity == identity end)

    assert Process.alive?(task_pid)
    refute remonitored.task_ref == old_task_ref
    assert {:pending, :task_down_not_observed} = TaskGuardian.proof(access, identity)

    old_supervisor_ref = generation.supervisor_ref

    send(
      guardian,
      {:DOWN, old_supervisor_ref, :process, physical_supervisor, :killed}
    )

    state = :sys.get_state(guardian)
    generation = Map.fetch!(state.generations, generation_key)
    assert Process.alive?(physical_supervisor)
    refute generation.supervisor_ref == old_supervisor_ref
    assert {:pending, :task_down_not_observed} = TaskGuardian.proof(access, identity)

    send(task_pid, :finish)
    assert_receive {:DOWN, ref, :process, ^task_pid, :normal} when ref == task.ref, 2_000
  end

  test "evicted exact identities block instead of inheriting generation proof" do
    guardian =
      start_supervised!(
        Supervisor.child_spec(
          {TaskGuardian,
           [
             name: nil,
             max_identities: 1,
             max_completed_generations: 1,
             max_open_generations: 2
           ]},
          id: :bounded_task_guardian
        )
      )

    physical_supervisor =
      start_supervised!(
        Supervisor.child_spec({Task.Supervisor, []}, id: :bounded_guardian_supervisor)
      )

    assert {:ok, access} = TaskGuardian.open_generation(guardian, :effect, physical_supervisor)
    evicted = guardian_effect_identity(access.supervisor_id)
    retained = guardian_effect_identity(access.supervisor_id)
    assert :ok = TaskGuardian.reserve(access, evicted)
    assert :ok = TaskGuardian.cancel_reserved(access, evicted)
    assert :ok = TaskGuardian.reserve(access, retained)

    assert {:unknown, :task_identity_untracked} = TaskGuardian.proof(access, evicted)
    assert {:pending, :supervisor_down_not_proven} = TaskGuardian.proof(access, retained)
  end

  test "capability preimage is absent from public replies, state, proof, and RPC terms" do
    identity = reserve_effect_identity()

    assert Map.keys(identity) |> Enum.sort() ==
             [
               :agent_id,
               :assignment_id,
               :claim_token,
               :effect_id,
               :supervisor_id,
               :task_id,
               :termination_capability_digest
             ]
             |> Enum.sort()

    assert byte_size(identity.termination_capability_digest) == 32
    refute is_struct(identity)

    guardian_state = :sys.get_state(TaskGuardian)

    assert_raise ArgumentError, fn ->
      :ets.tab2list(guardian_state.termination_capabilities)
    end

    authority_state = :sys.get_state(EffectTaskAuthority)

    assert identity.termination_capability_digest in collect_32_byte_binaries(authority_state)
    assert identity.termination_capability_digest in collect_32_byte_binaries(guardian_state)

    task = start_registered_effect_task(identity)

    rpc_result = EffectTaskSupervisor.terminate_exact(identity)
    assert {:unknown, :termination_proof_persistence_failed} = rpc_result
    assert collect_32_byte_binaries(rpc_result) == []
    assert_receive {:DOWN, ref, :process, _pid, _reason} when ref == task.ref, 2_000

    authority_state = :sys.get_state(EffectTaskAuthority)
    guardian_state = :sys.get_state(TaskGuardian)
    refute secret_bearing_term?(authority_state)
    refute secret_bearing_term?(guardian_state)
    refute secret_bearing_term?(rpc_result)
  end

  test "one_for_all Authority restart converges only after exact task and supervisor DOWN" do
    identity = reserve_effect_identity()
    task = start_registered_effect_task(identity)

    authority = Process.whereis(EffectTaskAuthority)
    physical_supervisor = Process.whereis(@task_supervisor)
    authority_ref = Process.monitor(authority)
    supervisor_ref = Process.monitor(physical_supervisor)

    Process.exit(authority, :kill)

    assert_receive {:DOWN, ^authority_ref, :process, ^authority, _reason}, 2_000
    assert_receive {:DOWN, ^supervisor_ref, :process, ^physical_supervisor, _reason}, 2_000
    assert_receive {:DOWN, ref, :process, _pid, _reason} when ref == task.ref, 2_000

    _ = :sys.get_state(@effect_supervisor)

    assert {:unknown, :termination_proof_persistence_failed} =
             terminate_effect_identity(identity)

    assert {:ok, successor_id} = EffectTaskSupervisor.identity()
    refute successor_id == identity.supervisor_id
  end

  test "guardian restart fails closed, kills coupled tasks, and loses prior proof" do
    identity = reserve_effect_identity()
    task = start_registered_effect_task(identity)

    guardian = Process.whereis(TaskGuardian)
    authority = Process.whereis(EffectTaskAuthority)
    physical_supervisor = Process.whereis(@task_supervisor)
    guardian_ref = Process.monitor(guardian)
    authority_ref = Process.monitor(authority)
    supervisor_ref = Process.monitor(physical_supervisor)

    Process.exit(guardian, :kill)

    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, _reason}, 2_000
    assert_receive {:DOWN, ^authority_ref, :process, ^authority, _reason}, 2_000
    assert_receive {:DOWN, ^supervisor_ref, :process, ^physical_supervisor, _reason}, 2_000
    assert_receive {:DOWN, ref, :process, _pid, _reason} when ref == task.ref, 2_000

    _ = :sys.get_state(Maraithon.Runtime.TaskSystemSupervisor)
    _ = :sys.get_state(@effect_supervisor)

    assert {:unknown, :effect_task_owner_incarnation_unproven} =
             terminate_effect_identity(identity)
  end

  test "fresh and Registry-missing identities never become physical proof" do
    {:ok, supervisor_id} = EffectTaskSupervisor.identity()

    identity = %{
      effect_id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      claim_token: Ecto.UUID.generate(),
      supervisor_id: supervisor_id,
      task_id: Ecto.UUID.generate()
    }

    assert [] == Registry.lookup(@registry, EffectTaskSupervisor.registry_key(identity))

    assert {:unknown, :effect_task_owner_incarnation_unproven} =
             terminate_effect_identity(identity)

    fresh_identity = %{identity | supervisor_id: Ecto.UUID.generate()}

    assert {:unknown, :effect_task_owner_incarnation_unproven} =
             terminate_effect_identity(fresh_identity)
  end

  test "only the owner-bound exact Effect child PID may activate" do
    identity = reserve_effect_identity()
    test_pid = self()

    foreign =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        send(test_pid, {:foreign_effect_activation, EffectTaskAuthority.activate(identity)})
      end)

    assert_receive {:foreign_effect_activation, {:error, :effect_task_reservation_lost}}, 2_000
    assert_receive {:DOWN, ref, :process, _pid, :normal} when ref == foreign.ref, 2_000

    task = start_registered_effect_task(identity)

    assert {:error, :effect_task_activation_not_authorized} =
             EffectTaskSupervisor.authorize_activation(identity)

    send(task.pid, :finish)
    assert_receive {:DOWN, ref, :process, _pid, :normal} when ref == task.ref, 2_000
  end

  test "a reservation cancelled before activation cannot later enter" do
    identity = reserve_effect_identity()

    assert {:unknown, :termination_proof_persistence_failed} =
             terminate_effect_identity(identity)

    test_pid = self()

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        EffectTaskSupervisor.register_current!(identity)
        send(test_pid, :late_activation_entered)
      end)

    assert_receive {:DOWN, ref, :process, _pid, _reason} when ref == task.ref, 2_000
    refute_receive :late_activation_entered
  end

  defp enqueue_bound_task_cleanup! do
    identity = reserve_effect_identity()
    task = start_bound_effect_task(identity)
    send(task.pid, :finish)

    assert_receive {:DOWN, ref, :process, pid, :normal}
                   when ref == task.ref and pid == task.pid,
                   2_000

    await_cleanup_enqueue!(identity.task_id, 100)
    identity
  end

  defp start_bound_effect_task(identity) do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        receive do: (:finish -> :ok)
      end)

    assert :ok = EffectTaskSupervisor.bind_task(identity, task.pid)
    task
  end

  defp await_cleanup_enqueue!(_task_id, 0), do: flunk("cleanup task DOWN was not enqueued")

  defp await_cleanup_enqueue!(task_id, attempts) do
    state = :sys.get_state(EffectTaskAuthority)

    if MapSet.member?(state.cleanup_set, task_id) do
      state
    else
      await_cleanup_enqueue!(task_id, attempts - 1)
    end
  end

  defp restart_task_system! do
    parent = Maraithon.Runtime.Supervisor
    child = Maraithon.Runtime.TaskSystemSupervisor

    :ok = Supervisor.terminate_child(parent, child)
    {:ok, _pid} = Supervisor.restart_child(parent, child)
    _ = :sys.get_state(EffectTaskAuthority)
    :ok
  end

  defp terminate_effect_identity(identity), do: EffectTaskSupervisor.terminate_exact(identity)

  defp collect_32_byte_binaries(term) when is_binary(term) do
    if byte_size(term) == 32, do: [term], else: []
  end

  defp collect_32_byte_binaries(term) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.flat_map(&collect_32_byte_binaries/1)
  end

  defp collect_32_byte_binaries(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.flat_map(&collect_32_byte_binaries/1)
  end

  defp collect_32_byte_binaries(term) when is_list(term),
    do: Enum.flat_map(term, &collect_32_byte_binaries/1)

  defp collect_32_byte_binaries(_term), do: []

  defp secret_bearing_term?(term) when is_map(term) do
    Map.has_key?(term, :secret) or Map.has_key?(term, :termination_capability) or
      Enum.any?(Map.to_list(term), &secret_bearing_term?/1)
  end

  defp secret_bearing_term?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&secret_bearing_term?/1)

  defp secret_bearing_term?(term) when is_list(term),
    do: Enum.any?(term, &secret_bearing_term?/1)

  defp secret_bearing_term?(_term), do: false

  defp guardian_effect_identity(supervisor_id) do
    %{
      effect_id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      claim_token: Ecto.UUID.generate(),
      supervisor_id: supervisor_id,
      task_id: Ecto.UUID.generate()
    }
  end

  defp reserve_effect_identity do
    assert {:ok, identity} =
             EffectTaskSupervisor.reserve_coordinated(
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               Ecto.UUID.generate()
             )

    identity
  end

  defp start_registered_effect_task(identity) do
    test_pid = self()

    gate = make_ref()

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        receive do: ({:bound, ^gate} -> :ok)
        :ok = EffectTaskSupervisor.register_current!(identity)
        send(test_pid, {:task_registered, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert :ok = EffectTaskSupervisor.bind_task(identity, task.pid)
    send(task.pid, {:bound, gate})
    assert_receive {:task_registered, task_pid}, 2_000
    assert task.pid == task_pid
    task
  end
end
