defmodule Maraithon.Runtime.EffectRunnerDownAuthenticationTest do
  use ExUnit.Case, async: false

  alias Maraithon.Runtime.EffectRunner

  setup do
    case Process.whereis(EffectRunner) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    :ok
  end

  test "authenticates the exact task DOWN before retiring runner state" do
    runner = start_supervised!({EffectRunner, []})
    test_pid = self()
    effect_id = "synthetic-effect"

    state =
      :sys.replace_state(runner, fn state ->
        task =
          Task.Supervisor.async_nolink(Maraithon.Runtime.EffectSupervisor, fn ->
            send(test_pid, {:synthetic_effect_task_started, self()})

            receive do
              :finish -> :finished
            end
          end)

        %{
          state
          | tasks: Map.put(state.tasks, effect_id, task),
            monitors: Map.put(state.monitors, task.ref, effect_id)
        }
      end)

    assert_receive {:synthetic_effect_task_started, worker}, 1_000
    on_exit(fn -> Process.exit(worker, :kill) end)

    assert %Task{pid: ^worker, ref: original_ref} = Map.fetch!(state.tasks, effect_id)
    assert state.monitors == %{original_ref => effect_id}

    send(runner, {:DOWN, original_ref, :process, self(), :forged})
    wrong_pid_state = :sys.get_state(runner)

    assert %Task{pid: ^worker, ref: ^original_ref} =
             Map.fetch!(wrong_pid_state.tasks, effect_id)

    assert wrong_pid_state.monitors == %{original_ref => effect_id}

    send(runner, {:DOWN, original_ref, :process, worker, :forged})
    forged_state = :sys.get_state(runner)

    assert %Task{pid: ^worker, ref: replacement_ref} =
             Map.fetch!(forged_state.tasks, effect_id)

    assert is_reference(replacement_ref)
    refute replacement_ref == original_ref
    refute Map.has_key?(forged_state.monitors, original_ref)
    assert forged_state.monitors == %{replacement_ref => effect_id}

    observer_ref = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^observer_ref, :process, ^worker, :normal}, 1_000

    # The Task reply still carries original_ref. It must not retire state; the
    # real DOWN for replacement_ref is the authenticated physical boundary.
    retired_state = await_task_retired(runner, effect_id, 100)
    refute Map.has_key?(retired_state.tasks, effect_id)
    refute Map.has_key?(retired_state.monitors, replacement_ref)
  end

  defp await_task_retired(_runner, effect_id, 0) do
    flunk("effect task #{inspect(effect_id)} was not retired after its real DOWN")
  end

  defp await_task_retired(runner, effect_id, attempts) do
    state = :sys.get_state(runner)

    if Map.has_key?(state.tasks, effect_id) do
      receive do
      after
        10 -> await_task_retired(runner, effect_id, attempts - 1)
      end
    else
      state
    end
  end
end
