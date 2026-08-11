defmodule Maraithon.Runtime.TaskGuardianLifecycleTest do
  use ExUnit.Case, async: false

  alias Maraithon.Runtime.TaskGuardian

  @completion_fallback_errors [
    :coordination_task_completion_not_durable,
    :task_termination_proof_conflict
  ]

  test "named Guardians ignore test persistence decisions" do
    name = Maraithon.Runtime.TaskGuardianLifecycleNamedGuardian

    guardian =
      start_supervised!(
        Supervisor.child_spec(
          {TaskGuardian,
           name: name,
           test_persistence: %{
             test_pid: self(),
             acknowledge_error: :injected_error,
             persist_error: :injected_error,
             delay_ms: 0
           }},
          id: {:named_task_guardian_lifecycle, make_ref()}
        )
      )

    assert is_nil(:sys.get_state(guardian).test_persistence)
  end

  test "retry queue is deduplicated FIFO, retains failures, and attempts at most 32 per tick" do
    guardian = start_guardian(max_identities: 64)
    physical_supervisor = start_physical_supervisor()
    {:ok, access} = TaskGuardian.open_generation(guardian, :effect, physical_supervisor)

    identities =
      for _index <- 1..33 do
        identity = guardian_effect_identity(access.supervisor_id)

        assert {:ok, %{termination_capability_digest: digest}} =
                 TaskGuardian.reserve_with_termination_capability(access, identity)

        assert byte_size(digest) == 32
        assert :ok = TaskGuardian.cancel_reserved(access, identity)
        assert :ok = TaskGuardian.cancel_reserved(access, identity)
        identity
      end

    locations = identity_locations(guardian, access, identities)
    initial = cancel_retry_timer(guardian)
    assert :queue.to_list(initial.pending_persistence) == locations
    assert MapSet.equal?(initial.pending_persistence_set, MapSet.new(locations))

    send(guardian, :retry_pending_task_terminations)
    retried = :sys.get_state(guardian, 5_000)

    attempted =
      for _index <- 1..32 do
        assert_receive {:guardian_persistence_attempt, ^guardian, :termination, :effect, identity,
                        "never_activated", evidence_id},
                       2_000

        assert evidence_id == "task-supervisor:never_activated:#{identity.task_id}"
        identity
      end

    assert Enum.map(attempted, & &1.task_id) ==
             identities |> Enum.take(32) |> Enum.map(& &1.task_id)

    refute_received {:guardian_persistence_attempt, ^guardian, :termination, :effect, _, _, _}

    assert :queue.to_list(retried.pending_persistence) ==
             Enum.drop(locations, 32) ++ Enum.take(locations, 32)

    assert MapSet.equal?(retried.pending_persistence_set, MapSet.new(locations))
    assert is_reference(retried.persistence_retry_timer)
    remaining = Process.read_timer(retried.persistence_retry_timer)
    assert is_integer(remaining)
    assert remaining in 1..1_000

    cancel_retry_timer(guardian)
  end

  test "aggregate retry deadline stops a slow batch and retains untouched FIFO entries" do
    guardian = start_guardian(max_identities: 8, delay_ms: 500)
    physical_supervisor = start_physical_supervisor()
    {:ok, access} = TaskGuardian.open_generation(guardian, :effect, physical_supervisor)

    identities =
      for _index <- 1..3 do
        identity = guardian_effect_identity(access.supervisor_id)

        assert {:ok, _capability} =
                 TaskGuardian.reserve_with_termination_capability(access, identity)

        assert :ok = TaskGuardian.cancel_reserved(access, identity)
        identity
      end

    locations = identity_locations(guardian, access, identities)
    cancel_retry_timer(guardian)
    send(guardian, :retry_pending_task_terminations)
    retried = :sys.get_state(guardian, 2_000)

    assert_receive {:guardian_persistence_attempt, ^guardian, :termination, :effect,
                    first_identity, "never_activated", _evidence_id},
                   2_000

    assert first_identity.task_id == hd(identities).task_id
    refute_received {:guardian_persistence_attempt, ^guardian, :termination, :effect, _, _, _}
    assert :queue.to_list(retried.pending_persistence) == tl(locations) ++ [hd(locations)]
    assert MapSet.equal?(retried.pending_persistence_set, MapSet.new(locations))

    cancel_retry_timer(guardian)
  end

  for completion_error <- @completion_fallback_errors do
    test "controller death falls back from #{completion_error} acknowledgement to physical proof" do
      completion_error = unquote(completion_error)

      guardian = start_guardian(acknowledge_error: completion_error)

      physical_supervisor = start_physical_supervisor()
      parent = self()

      controller =
        spawn(fn ->
          assert {:ok, access} =
                   TaskGuardian.open_generation(guardian, :effect, physical_supervisor)

          identity = guardian_effect_identity(access.supervisor_id)

          assert {:ok, _capability} =
                   TaskGuardian.reserve_with_termination_capability(access, identity)

          {:ok, task_pid} =
            Task.Supervisor.start_child(physical_supervisor, fn ->
              receive do
                :finish -> :ok
              end
            end)

          assert :ok = TaskGuardian.activate(access, identity, task_pid)
          assert :ok = TaskGuardian.expect_completion(access, identity)
          send(parent, {:controller_ready, self(), access.supervisor_id, identity, task_pid})

          receive do
            :stop -> :ok
          end
        end)

      controller_ref = Process.monitor(controller)

      assert_receive {:controller_ready, ^controller, supervisor_id, identity, task_pid}, 2_000
      task_ref = Process.monitor(task_pid)
      send(controller, :stop)
      assert_receive {:DOWN, ^controller_ref, :process, ^controller, :normal}, 2_000
      send(task_pid, :finish)
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :normal}, 2_000

      location = await_terminal_location(guardian, {:effect, supervisor_id}, identity, 100)
      cancel_retry_timer(guardian)
      send(guardian, :retry_pending_task_terminations)
      persisted = :sys.get_state(guardian, 5_000)

      assert_receive {:guardian_persistence_attempt, ^guardian, :completion, ^identity}, 2_000

      assert_receive {:guardian_persistence_attempt, ^guardian, :termination, :effect, ^identity,
                      "supervisor_down", evidence_id},
                     2_000

      assert evidence_id == "task-down:#{identity.task_id}"
      record = record_at!(persisted, location)
      assert record.completion_requested == false
      assert is_reference(record.termination_capability_id)
      assert is_nil(record.durable_disposition)
      assert MapSet.member?(persisted.pending_persistence_set, location)
      assert location in :queue.to_list(persisted.pending_persistence)
      assert location in persisted.terminal_identity_order

      assert_raise ArgumentError, fn ->
        :ets.tab2list(persisted.termination_capabilities)
      end
    end
  end

  test "capability-bearing terminal identities keep rotating without disappearing" do
    guardian = start_guardian(max_identities: 2)

    physical_supervisor = start_physical_supervisor()
    {:ok, access} = TaskGuardian.open_generation(guardian, :effect, physical_supervisor)

    retained = guardian_effect_identity(access.supervisor_id)
    evictable = guardian_effect_identity(access.supervisor_id)
    replacement = guardian_effect_identity(access.supervisor_id)
    final = guardian_effect_identity(access.supervisor_id)

    assert {:ok, _capability} =
             TaskGuardian.reserve_with_termination_capability(access, retained)

    assert :ok = TaskGuardian.cancel_reserved(access, retained)
    assert :ok = TaskGuardian.reserve(access, evictable)
    assert :ok = TaskGuardian.cancel_reserved(access, evictable)

    [retained_location, evictable_location] =
      identity_locations(guardian, access, [retained, evictable])

    cancel_retry_timer(guardian)
    assert :ok = TaskGuardian.reserve(access, replacement)
    skipped = :sys.get_state(guardian)

    assert {:ok, :activation_cancelled} = TaskGuardian.proof(access, retained)
    assert {:unknown, :task_identity_untracked} = TaskGuardian.proof(access, evictable)
    assert retained_location in skipped.terminal_identity_order
    refute evictable_location in skipped.terminal_identity_order
    assert skipped.identity_count == 2

    send(guardian, :retry_pending_task_terminations)
    retained_after_failure = :sys.get_state(guardian, 5_000)

    assert_receive {:guardian_persistence_attempt, ^guardian, :termination, :effect, ^retained,
                    "never_activated", _evidence_id},
                   2_000

    assert is_reference(
             record_at!(retained_after_failure, retained_location).termination_capability_id
           )

    assert retained_location in retained_after_failure.terminal_identity_order

    assert :ok = TaskGuardian.cancel_reserved(access, replacement)
    assert :ok = TaskGuardian.reserve(access, final)
    assert {:ok, :activation_cancelled} = TaskGuardian.proof(access, retained)
    assert {:pending, :supervisor_down_not_proven} = TaskGuardian.proof(access, final)

    final_state = :sys.get_state(guardian)
    assert retained_location in final_state.terminal_identity_order
    assert final_state.identity_count == 2
    cancel_retry_timer(guardian)
  end

  test "more than one batch of synchronous completion ACKs cannot starve the next live proof" do
    guardian = start_guardian(max_identities: 64)

    physical_supervisor = start_physical_supervisor()
    {:ok, access} = TaskGuardian.open_generation(guardian, :effect, physical_supervisor)

    identities =
      for index <- 1..34 do
        identity = guardian_effect_identity(access.supervisor_id)

        if index <= 33 do
          assert :ok = TaskGuardian.reserve(access, identity)
        else
          assert {:ok, _capability} =
                   TaskGuardian.reserve_with_termination_capability(access, identity)
        end

        identity
      end

    locations = mark_down_and_seed_pending(guardian, access, identities)
    {acknowledged, [live_identity]} = Enum.split(identities, 33)
    {_acknowledged_locations, [live_location]} = Enum.split(locations, 33)

    Enum.each(acknowledged, fn identity ->
      assert :ok = TaskGuardian.expect_completion(access, identity)
      assert :ok = TaskGuardian.acknowledge_completion(access, identity)
    end)

    compacted = :sys.get_state(guardian)
    assert :queue.to_list(compacted.pending_persistence) == [live_location]
    assert MapSet.equal?(compacted.pending_persistence_set, MapSet.new([live_location]))

    send(guardian, :retry_pending_task_terminations)
    retried = :sys.get_state(guardian, 5_000)

    assert_receive {:guardian_persistence_attempt, ^guardian, :termination, :effect,
                    ^live_identity, "supervisor_down", _evidence_id},
                   2_000

    assert :queue.to_list(retried.pending_persistence) == [live_location]
    assert MapSet.equal?(retried.pending_persistence_set, MapSet.new([live_location]))
    cancel_retry_timer(guardian)
  end

  defp start_guardian(opts) do
    {test_opts, guardian_opts} =
      Keyword.split(opts, [:acknowledge_error, :persist_error, :delay_ms])

    test_persistence = %{
      test_pid: self(),
      acknowledge_error:
        Keyword.get(test_opts, :acknowledge_error, :task_termination_persistence_failed),
      persist_error: Keyword.get(test_opts, :persist_error, :task_termination_persistence_failed),
      delay_ms: Keyword.get(test_opts, :delay_ms, 0)
    }

    start_supervised!(
      Supervisor.child_spec(
        {TaskGuardian,
         Keyword.merge(
           [name: nil, test_persistence: test_persistence],
           guardian_opts
         )},
        id: {:task_guardian_lifecycle, make_ref()}
      )
    )
  end

  defp start_physical_supervisor do
    start_supervised!(
      Supervisor.child_spec(
        {Task.Supervisor, []},
        id: {:task_guardian_physical_supervisor, make_ref()}
      )
    )
  end

  defp cancel_retry_timer(guardian) do
    :sys.replace_state(guardian, fn state ->
      if is_reference(state.persistence_retry_timer),
        do: Process.cancel_timer(state.persistence_retry_timer)

      %{state | persistence_retry_timer: nil}
    end)
  end

  defp identity_locations(guardian, access, identities) do
    state = :sys.get_state(guardian)
    generation_key = {:effect, access.supervisor_id}
    generation = Map.fetch!(state.generations, generation_key)

    Enum.map(identities, fn identity ->
      {identity_key, _record} =
        Enum.find(generation.identities, fn {_identity_key, record} ->
          record.identity == identity
        end)

      {generation_key, identity_key}
    end)
  end

  defp mark_down_and_seed_pending(guardian, access, identities) do
    locations = identity_locations(guardian, access, identities)
    generation_key = {:effect, access.supervisor_id}

    :sys.replace_state(guardian, fn state ->
      generation = Map.fetch!(state.generations, generation_key)

      generation =
        Enum.reduce(locations, generation, fn {_generation_key, identity_key}, generation ->
          record = Map.fetch!(generation.identities, identity_key)

          record = %{
            record
            | phase: :active,
              down: %{
                evidence_id: "task-down:#{record.identity.task_id}",
                reason: "normal"
              }
          }

          put_in(generation.identities[identity_key], record)
        end)

      %{
        state
        | generations: Map.put(state.generations, generation_key, generation),
          pending_persistence: :queue.from_list(locations),
          pending_persistence_set: MapSet.new(locations),
          persistence_retry_timer: nil
      }
    end)

    locations
  end

  defp await_terminal_location(_guardian, _generation_key, _identity, 0),
    do: flunk("Guardian did not observe exact task DOWN")

  defp await_terminal_location(guardian, generation_key, identity, attempts) do
    state = :sys.get_state(guardian)
    generation = Map.fetch!(state.generations, generation_key)

    case Enum.find(generation.identities, fn {_identity_key, record} ->
           record.identity == identity and is_map(record.down)
         end) do
      {identity_key, _record} ->
        {generation_key, identity_key}

      nil ->
        :erlang.yield()
        await_terminal_location(guardian, generation_key, identity, attempts - 1)
    end
  end

  defp record_at!(state, {generation_key, identity_key}) do
    state.generations
    |> Map.fetch!(generation_key)
    |> Map.fetch!(:identities)
    |> Map.fetch!(identity_key)
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
end
