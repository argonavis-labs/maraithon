defmodule Maraithon.Runtime.AgentRecoveryTest do
  @moduledoc """
  End-to-end verification of the OTP self-healing bet:

    * a crashed agent is restarted by its supervisor (the `:transient`
      contract from Gap 1), and
    * the restarted agent recovers its `behavior_state` from the latest
      checkpoint snapshot (Gap 4) instead of starting blank.

  Uses the real `Runtime.AgentSupervisor` (`DynamicSupervisor`) so we are
  exercising the actual supervision tree, not a stub.
  """

  use Maraithon.DataCase, async: false

  alias Maraithon.Agents
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.Scheduler
  alias Maraithon.Runtime.Snapshot

  setup do
    # Crashing an agent and waiting for a supervisor-spawned replacement means
    # we can't pre-`allow` the replacement's pid before its `:recovering` event
    # runs. `DataCase, async: false` starts the SQL sandbox owner in shared mode.

    case Process.whereis(Scheduler) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    start_supervised!({Scheduler, []})

    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "recovery_test"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    on_exit(fn ->
      case Registry.lookup(AgentRegistry, agent.id) do
        [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        _ -> :ok
      end
    end)

    %{agent: agent}
  end

  test "a crashed agent is restarted by the supervisor and resumes from snapshot", %{
    agent: agent
  } do
    # 1. Start the agent under the real DynamicSupervisor.
    {:ok, original_pid} = AgentSupervisor.start_agent(agent)
    wait_for_idle(original_pid)

    # 2. Plant a distinctive marker in behavior_state so we can prove the
    #    restart actually reloaded it (not just started fresh).
    marker = %{verify_marker: :crash_recovery_test, counter: 42}

    :sys.replace_state(original_pid, fn {state, data} ->
      {state, %{data | behavior_state: marker}}
    end)

    # 3. Force a checkpoint to persist the snapshot.
    send(original_pid, {:wakeup, "checkpoint", Ecto.UUID.generate(), %{}})

    snapshot = wait_for_snapshot(agent.id, marker, 10_000)
    assert snapshot.behavior_state == marker
    wait_for_idle(original_pid)

    # 4. Crash it. `:kill` is an unstoppable abnormal exit — :transient
    #    must restart it.
    Process.monitor(original_pid)
    Process.exit(original_pid, :kill)
    assert_receive {:DOWN, _ref, :process, ^original_pid, :killed}, 1_000

    # 5. The supervisor restarts it under the same Registry name. Poll
    #    until a new pid claims that name.
    new_pid = wait_for_new_pid(agent.id, original_pid, 15_000)
    refute new_pid == original_pid
    wait_for_idle(new_pid)

    # 6. The restarted agent must have re-loaded behavior_state from the
    #    snapshot, not re-initialized to the behavior's default.
    {_state, data} = :sys.get_state(new_pid)
    assert data.behavior_state == marker
  end

  defp wait_for_idle(pid) do
    deadline = System.monotonic_time(:millisecond) + 3_000
    do_wait_for_idle(pid, deadline)
  end

  defp do_wait_for_idle(pid, deadline) do
    if Process.alive?(pid) do
      case :sys.get_state(pid) do
        {:idle, _data} -> :ok
        _ -> retry_until(deadline, fn -> do_wait_for_idle(pid, deadline) end)
      end
    else
      retry_until(deadline, fn -> do_wait_for_idle(pid, deadline) end)
    end
  end

  defp wait_for_new_pid(agent_id, old_pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_new_pid(agent_id, old_pid, deadline)
  end

  defp wait_for_snapshot(agent_id, marker, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_snapshot(agent_id, marker, deadline)
  end

  defp do_wait_for_snapshot(agent_id, marker, deadline) do
    case Snapshot.latest(agent_id) do
      snapshot when is_map(snapshot) ->
        if snapshot.behavior_state == marker do
          snapshot
        else
          retry_until(deadline, fn -> do_wait_for_snapshot(agent_id, marker, deadline) end)
        end

      _other ->
        retry_until(deadline, fn -> do_wait_for_snapshot(agent_id, marker, deadline) end)
    end
  end

  defp do_wait_for_new_pid(agent_id, old_pid, deadline) do
    case Registry.lookup(AgentRegistry, agent_id) do
      [{pid, _}] when pid != old_pid -> pid
      _ -> retry_until(deadline, fn -> do_wait_for_new_pid(agent_id, old_pid, deadline) end)
    end
  end

  defp retry_until(deadline, fun) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("timed out waiting for supervisor / state transition")
    else
      Process.sleep(50)
      fun.()
    end
  end
end
