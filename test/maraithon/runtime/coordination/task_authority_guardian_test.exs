defmodule Maraithon.Runtime.Coordination.TaskAuthorityGuardianTest do
  use ExUnit.Case, async: false

  alias Maraithon.Runtime.Coordination.TaskAuthority
  alias Maraithon.Runtime.TaskGuardian

  setup do
    _ = :sys.get_state(Maraithon.Runtime.TaskSystemSupervisor)
    _ = :sys.get_state(Maraithon.Runtime.Coordination.TaskSupervisor)
    :ok
  end

  test "Task capability vault is private and authority/public terms contain digest only" do
    authority = start_isolated_authority()
    identity = reserve(authority)
    authority_state = :sys.get_state(authority)
    guardian_state = :sys.get_state(TaskGuardian)

    assert_raise ArgumentError, fn ->
      :ets.tab2list(guardian_state.termination_capabilities)
    end

    reservation = Map.fetch!(authority_state.reservations, identity.local_task_id)
    assert reservation.termination_capability_digest == identity.termination_capability_digest
    refute Map.has_key?(reservation, :termination_capability_id)
    refute secret_bearing_term?(authority_state)
    refute secret_bearing_term?(guardian_state)

    assert identity.termination_capability_digest in collect_32_byte_binaries(authority_state)
    assert identity.termination_capability_digest in collect_32_byte_binaries(guardian_state)
  end

  test "Guardian retains and retries exact task DOWN independently of Authority state" do
    owner = start_isolated_authority()
    identity = reserve(owner)
    test_pid = self()

    task =
      start_bound_task(owner, identity, fn ->
        send(test_pid, {:coordinated_task_registered, self()})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:coordinated_task_registered, task_pid}, 2_000
    send(task_pid, :finish)
    assert_receive {:DOWN, ref, :process, ^task_pid, :normal} when ref == task.ref, 2_000

    guardian_state = :sys.get_state(TaskGuardian)
    assert MapSet.size(guardian_state.pending_persistence_set) > 0

    assert {:unknown, :termination_proof_persistence_failed} =
             GenServer.call(owner, {:terminate_exact, identity})

    guardian_state = :sys.get_state(TaskGuardian)
    assert MapSet.size(guardian_state.pending_persistence_set) > 0
    refute secret_bearing_term?(guardian_state)
  end

  test "only the owner-bound coordinated child PID may activate" do
    authority = start_isolated_authority()
    identity = reserve(authority)
    test_pid = self()

    foreign =
      Task.Supervisor.async_nolink(:sys.get_state(authority).supervisor_pid, fn ->
        send(
          test_pid,
          {:foreign_coordination_activation, GenServer.call(authority, {:activate, identity})}
        )
      end)

    assert_receive {:foreign_coordination_activation, {:error, :task_reservation_lost}}, 2_000
    assert_receive {:DOWN, ref, :process, _pid, :normal} when ref == foreign.ref, 2_000

    task = start_bound_task(authority, identity, fn -> :ok end)
    assert_receive {:DOWN, ref, :process, _pid, :normal} when ref == task.ref, 2_000
  end

  test "forged Authority owner and task DOWN tuples cannot create proof" do
    authority = start_isolated_authority()
    identity = reserve(authority)
    reservation = :sys.get_state(authority).reservations[identity.local_task_id]
    old_owner_ref = reservation.owner_ref
    send(authority, {:DOWN, old_owner_ref, :process, self(), :killed})
    reservation = :sys.get_state(authority).reservations[identity.local_task_id]
    refute reservation.owner_ref == old_owner_ref

    test_pid = self()

    task =
      start_bound_task(authority, identity, fn ->
        send(test_pid, {:spoof_authority_task_ready, self()})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:spoof_authority_task_ready, task_pid}, 2_000
    reservation = :sys.get_state(authority).reservations[identity.local_task_id]
    old_task_ref = reservation.task_ref
    send(authority, {:DOWN, old_task_ref, :process, task_pid, :killed})
    reservation = :sys.get_state(authority).reservations[identity.local_task_id]
    assert Process.alive?(task_pid)
    refute reservation.task_ref == old_task_ref

    guardian = :sys.get_state(TaskGuardian)
    generation = Map.fetch!(guardian.generations, {:coordination, identity.supervisor_id})

    identity_key =
      {:coordination, identity.assignment_id, identity.claim_token, identity.supervisor_id,
       identity.local_task_id}

    assert generation.identities[identity_key].down == nil

    send(task_pid, :finish)
    assert_receive {:DOWN, ref, :process, ^task_pid, :normal} when ref == task.ref, 2_000
  end

  test "cancelled reserved work remains canonical never_activated across supervisor DOWN" do
    owner = start_isolated_authority()
    identity = reserve(owner)

    assert {:unknown, :termination_proof_persistence_failed} =
             GenServer.call(owner, {:terminate_exact, identity})

    physical_supervisor = :sys.get_state(owner).supervisor_pid
    supervisor_ref = Process.monitor(physical_supervisor)
    Process.exit(physical_supervisor, :kill)

    assert_receive {:DOWN, ^supervisor_ref, :process, ^physical_supervisor, _reason}, 2_000
    _ = :sys.get_state(TaskGuardian)

    assert {:unknown, :termination_proof_persistence_failed} =
             GenServer.call(owner, {:terminate_exact, identity})
  end

  defp start_bound_task(authority, identity, fun) when is_function(fun, 0) do
    gate = make_ref()

    task =
      Task.Supervisor.async_nolink(:sys.get_state(authority).supervisor_pid, fn ->
        receive do: ({:bound, ^gate} -> :ok)
        :ok = GenServer.call(authority, {:activate, identity})
        fun.()
      end)

    assert :ok = GenServer.call(authority, {:bind_task, identity, task.pid})
    send(task.pid, {:bound, gate})
    task
  end

  defp start_isolated_authority do
    physical_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    spec =
      Supervisor.child_spec(
        {TaskAuthority, name: nil, task_supervisor_pid: physical_supervisor},
        id: make_ref(),
        restart: :temporary
      )

    start_supervised!(spec)
  end

  defp reserve(authority) do
    base = %{
      work_kind: "effect",
      work_id: Ecto.UUID.generate(),
      claim_token: Ecto.UUID.generate(),
      assignment_id: Ecto.UUID.generate(),
      local_task_id: Ecto.UUID.generate()
    }

    assert {:ok, identity} = GenServer.call(authority, {:reserve, base})
    assert byte_size(identity.termination_capability_digest) == 32
    refute Map.has_key?(identity, :termination_capability)
    refute Map.has_key?(identity, :termination_capability_secret)
    identity
  end

  defp collect_32_byte_binaries(term) when is_binary(term) do
    if byte_size(term) == 32, do: [term], else: []
  end

  defp collect_32_byte_binaries(term) when is_map(term) do
    term |> Map.to_list() |> Enum.flat_map(&collect_32_byte_binaries/1)
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
end
