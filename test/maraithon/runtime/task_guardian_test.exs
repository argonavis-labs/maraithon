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

    waiter =
      Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
        result = TaskGuardian.await_proof(access, reserved, 1_000)
        send(test_pid, {:barrier_wait_result, result})
      end)

    supervisor_ref = Process.monitor(physical_supervisor)
    Process.exit(physical_supervisor, :kill)

    assert_receive {:DOWN, ^supervisor_ref, :process, ^physical_supervisor, _reason}, 2_000
    _ = :sys.get_state(TaskGuardian)

    assert {:pending, :supervisor_down_not_proven} = TaskGuardian.proof(access, reserved)
    refute_receive {:barrier_wait_result, _result}

    send(task_pid, :finish)
    assert_receive {:DOWN, ref, :process, ^task_pid, :normal} when ref == task.ref, 2_000
    _ = :sys.get_state(TaskGuardian)

    assert_receive {:barrier_wait_result, {:ok, {:supervisor_down_before_activation, _proof}}},
                   2_000

    assert_receive {:DOWN, waiter_ref, :process, _pid, :normal} when waiter_ref == waiter.ref,
                   2_000

    assert {:ok, {:supervisor_down_before_activation, _proof}} =
             TaskGuardian.proof(access, reserved)

    assert {:ok, {:task_down, _proof}} = TaskGuardian.proof(access, active)
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
    assert {:ok, :terminated} = EffectTaskSupervisor.terminate_exact(identity)
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
             EffectTaskSupervisor.terminate_exact(identity)
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
             EffectTaskSupervisor.terminate_exact(identity)

    fresh_identity = %{identity | supervisor_id: Ecto.UUID.generate()}

    assert {:unknown, :effect_task_owner_incarnation_unproven} =
             EffectTaskSupervisor.terminate_exact(fresh_identity)
  end

  test "a reservation cancelled before activation cannot later enter" do
    identity = reserve_effect_identity()
    assert {:ok, :never_activated} = EffectTaskSupervisor.terminate_exact(identity)
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        EffectTaskSupervisor.register_current!(identity)
        send(test_pid, :late_activation_entered)
      end)

    assert_receive {:DOWN, ref, :process, _pid, _reason} when ref == task.ref, 2_000
    refute_receive :late_activation_entered
  end

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
             EffectTaskSupervisor.reserve(
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               Ecto.UUID.generate()
             )

    identity
  end

  defp start_registered_effect_task(identity) do
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        :ok = EffectTaskSupervisor.register_current!(identity)
        send(test_pid, {:task_registered, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:task_registered, task_pid}, 2_000
    assert task.pid == task_pid
    task
  end
end
