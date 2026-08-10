defmodule Maraithon.Runtime.Coordination.TaskAuthorityGuardianTest do
  use ExUnit.Case, async: false

  alias Maraithon.Runtime.Coordination.{TaskAuthority, TaskSupervisor}
  alias Maraithon.Runtime.TaskGuardian

  setup do
    _ = :sys.get_state(Maraithon.Runtime.TaskSystemSupervisor)
    _ = :sys.get_state(Maraithon.Runtime.Coordination.TaskSupervisor)
    :ok
  end

  test "an exact task DOWN survives a database persistence outage and is retried" do
    store =
      start_supervised!(
        {Agent, fn -> %{available: false, persisted: []} end},
        id: :task_proof_outage_store
      )

    persist_down = fn identity, proof ->
      Agent.get_and_update(store, fn state ->
        if state.available do
          {:ok, %{state | persisted: [{identity, proof} | state.persisted]}}
        else
          {{:error, :database_unavailable}, state}
        end
      end)
    end

    authority = start_isolated_authority(persist_down: persist_down)
    identity = reserve(authority)
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(TaskSupervisor.task_supervisor(), fn ->
        :ok = GenServer.call(authority, {:activate, identity})
        send(test_pid, {:coordinated_task_registered, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:coordinated_task_registered, task_pid}, 2_000
    assert task.pid == task_pid

    assert {:unknown, :termination_proof_persistence_failed} =
             GenServer.call(authority, {:terminate_exact, identity}, 5_000)

    assert_receive {:DOWN, ref, :process, ^task_pid, _reason} when ref == task.ref, 2_000
    Agent.update(store, &%{&1 | available: true})

    assert {:ok, %{persisted: persisted, remaining: 0}} =
             TaskAuthority.retry_pending_proofs(authority)

    assert persisted in [0, 1]
    assert [{^identity, %{evidence_id: evidence_id}}] = Agent.get(store, & &1.persisted)
    assert evidence_id == "task-down:#{identity.local_task_id}"
  end

  test "one_for_all Authority restart retains exact task DOWN proof" do
    persist_down = fn _identity, _proof -> :ok end
    owner = start_isolated_authority(persist_down: persist_down)
    observer = start_isolated_authority(persist_down: persist_down)
    identity = reserve(owner)
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(TaskSupervisor.task_supervisor(), fn ->
        :ok = GenServer.call(owner, {:activate, identity})
        send(test_pid, {:restart_task_registered, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:restart_task_registered, task_pid}, 2_000
    authority = Process.whereis(TaskAuthority)
    physical_supervisor = Process.whereis(TaskSupervisor.task_supervisor())
    authority_ref = Process.monitor(authority)
    supervisor_ref = Process.monitor(physical_supervisor)
    Process.exit(authority, :kill)

    assert_receive {:DOWN, ^authority_ref, :process, ^authority, _reason}, 2_000
    assert_receive {:DOWN, ^supervisor_ref, :process, ^physical_supervisor, _reason}, 2_000
    assert_receive {:DOWN, ref, :process, ^task_pid, _reason} when ref == task.ref, 2_000
    _ = :sys.get_state(TaskGuardian)

    assert {:ok, :terminated} = GenServer.call(observer, {:terminate_exact, identity})
  end

  test "reserved/not_entered persistence requires the monitored supervisor barrier" do
    store =
      start_supervised!(
        {Agent,
         fn ->
           %{
             identity: nil,
             state: "reserved",
             provider_boundary: "not_entered",
             outcome: nil
           }
         end},
        id: :reserved_assignment_store
      )

    persist_never_activated = fn identity ->
      Agent.get_and_update(store, fn state ->
        if state.identity == identity and state.state == "reserved" and
             state.provider_boundary == "not_entered" do
          {:ok, %{state | state: "settled", outcome: "cancelled_before_provider"}}
        else
          {{:error, :assignment_not_canonical}, state}
        end
      end)
    end

    owner = start_isolated_authority(persist_never_activated: persist_never_activated)
    observer = start_isolated_authority(persist_never_activated: persist_never_activated)
    identity = reserve(owner)
    Agent.update(store, &%{&1 | identity: identity})

    assert {:unknown, :task_termination_unproven} =
             GenServer.call(observer, {:terminate_exact, identity})

    assert Agent.get(store, & &1.state) == "reserved"

    physical_supervisor = Process.whereis(TaskSupervisor.task_supervisor())
    supervisor_ref = Process.monitor(physical_supervisor)
    Process.exit(physical_supervisor, :kill)

    assert_receive {:DOWN, ^supervisor_ref, :process, ^physical_supervisor, _reason}, 2_000
    _ = :sys.get_state(TaskGuardian)

    assert {:ok, :never_activated} =
             GenServer.call(observer, {:terminate_exact, identity})

    assert %{
             state: "settled",
             provider_boundary: "not_entered",
             outcome: "cancelled_before_provider"
           } = Agent.get(store, &Map.take(&1, [:state, :provider_boundary, :outcome]))
  end

  defp start_isolated_authority(overrides) do
    opts = Keyword.merge([name: nil], overrides)

    spec =
      Supervisor.child_spec({TaskAuthority, opts},
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
    identity
  end
end
