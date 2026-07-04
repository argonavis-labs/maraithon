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
  alias Maraithon.Runtime.Agent, as: RuntimeAgent
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.Scheduler
  alias Maraithon.Runtime.Snapshot

  # ---------------------------------------------------------------------------
  # Probe behaviors for exercising SPEC 08 restore semantics directly.
  # ---------------------------------------------------------------------------

  defmodule ProbeBehavior do
    @moduledoc false
    @behaviour Maraithon.Behaviors.Behavior

    @impl true
    def init(_config) do
      %{
        stable: :default,
        new_key: :fresh_default,
        cycle_skill_ids: nil,
        resume_index: 0,
        pending_effect_skill_id: nil
      }
    end

    @impl true
    def handle_wakeup(state, _context), do: {:idle, state}

    @impl true
    def handle_effect_result(_result, state, _context), do: {:idle, state}

    @impl true
    def next_wakeup(_state), do: :none
  end

  defmodule MigratingProbeBehavior do
    @moduledoc false
    @behaviour Maraithon.Behaviors.Behavior

    @impl true
    def init(_config), do: %{renamed_key: :fresh_default, other: :default}

    @impl true
    def schema_version, do: 2

    @impl true
    def migrate_state(_stored_version, state, _config) do
      case Map.pop(state, :old_key) do
        {nil, state} -> state
        {value, state} -> Map.put(state, :renamed_key, value)
      end
    end

    @impl true
    def handle_wakeup(state, _context), do: {:idle, state}

    @impl true
    def handle_effect_result(_result, state, _context), do: {:idle, state}

    @impl true
    def next_wakeup(_state), do: :none
  end

  defmodule RaisingMigrateProbeBehavior do
    @moduledoc false
    @behaviour Maraithon.Behaviors.Behavior

    @impl true
    def init(_config), do: %{stable: :default, new_key: :fresh_default}

    @impl true
    def schema_version, do: 1

    @impl true
    def migrate_state(_stored_version, _state, _config), do: raise("broken migration")

    @impl true
    def handle_wakeup(state, _context), do: {:idle, state}

    @impl true
    def handle_effect_result(_result, state, _context), do: {:idle, state}

    @impl true
    def next_wakeup(_state), do: :none
  end

  defmodule RaisingReconcileProbeBehavior do
    @moduledoc false
    @behaviour Maraithon.Behaviors.Behavior

    @impl true
    def init(_config), do: %{stable: :default, new_key: :fresh_default}

    @impl true
    def reconcile_restored_state(_state, _config), do: raise("broken reconciliation")

    @impl true
    def handle_wakeup(state, _context), do: {:idle, state}

    @impl true
    def handle_effect_result(_result, state, _context), do: {:idle, state}

    @impl true
    def next_wakeup(_state), do: :none
  end

  defmodule ReconcilingProbeBehavior do
    @moduledoc false
    @behaviour Maraithon.Behaviors.Behavior

    @impl true
    def init(_config), do: %{stable: :default, reconciled: false}

    @impl true
    def reconcile_restored_state(state, _config), do: %{state | reconciled: true}

    @impl true
    def handle_wakeup(state, _context), do: {:idle, state}

    @impl true
    def handle_effect_result(_result, state, _context), do: {:idle, state}

    @impl true
    def next_wakeup(_state), do: :none
  end

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
    #    snapshot, not re-initialized to the behavior's default. SPEC 08 R3:
    #    restore now merges the snapshot onto fresh init/1 defaults — every
    #    key the snapshot carries wins verbatim, and keys the (old) snapshot
    #    never had are backfilled from init/1 instead of left absent.
    {_state, data} = :sys.get_state(new_pid)
    assert data.behavior_state.verify_marker == :crash_recovery_test
    assert data.behavior_state.counter == 42
    # Backfilled from prompt_agent's init/1 defaults (the planted marker map
    # deliberately lacks every init key — pre-SPEC-08 this restored as-is).
    assert data.behavior_state.name == "recovery_test"
  end

  test "restores an old snapshot by merging onto fresh init defaults (SPEC 08 R3)", %{
    agent: agent
  } do
    # A snapshot written by an "older release": carries real accumulated
    # values for some keys, knows nothing about the rest of init/1's output.
    refilled_at = DateTime.to_iso8601(DateTime.utc_now())
    legacy_state = %{verify_marker: :legacy, name: "from_snapshot"}
    legacy_budget = %{llm_calls: 7, refilled_at: refilled_at}
    {:ok, _} = Snapshot.persist(agent.id, 1, :idle, legacy_state, legacy_budget, 0)

    {:ok, pid} = AgentSupervisor.start_agent(agent)
    wait_for_idle(pid)
    {_state, data} = :sys.get_state(pid)

    # Snapshot wins for every key it carries — including one whose init/1
    # default differs (config would say name: "recovery_test").
    assert data.behavior_state.verify_marker == :legacy
    assert data.behavior_state.name == "from_snapshot"
    # A key absent from the snapshot (new in this release) is backfilled from
    # init/1's defaults instead of crashing the first read of it.
    assert data.behavior_state.prompt == "You are a helpful assistant."

    # Budget restore (R3 step 7): present keys preserved from the snapshot,
    # missing keys populated from init_budget/1 defaults.
    assert data.budget.llm_calls == 7
    assert data.budget.refilled_at == refilled_at
    assert data.budget.tool_calls == 1000
  end

  # SPEC 08 R3: the layered restore algorithm, exercised directly against
  # probe behaviors so each boundary (default-merge, versioned migration,
  # reconciliation, and their independent rescue fallbacks) is pinned down
  # without a full supervision-tree round-trip per case.
  defp probe_snapshot(overrides) do
    Map.merge(
      %{
        sequence_num: 1,
        state_name: "idle",
        behavior_state: %{},
        budget: %{llm_calls: 3, tool_calls: 4},
        schema_version: 0
      },
      overrides
    )
  end

  describe "restore_from_snapshot/4 (SPEC 08)" do
    test "backfills keys missing from the snapshot with init/1 defaults, snapshot wins otherwise" do
      snapshot = probe_snapshot(%{behavior_state: %{stable: :accumulated}})

      {state, _budget} = RuntimeAgent.restore_from_snapshot(ProbeBehavior, %{}, snapshot, "a1")

      # Present in the snapshot: preserved verbatim (never reset to :default).
      assert state.stable == :accumulated
      # Absent from the snapshot (new in this release): init/1 default, so the
      # first `state.new_key` read cannot KeyError (prod 2026-07-03 class).
      assert state.new_key == :fresh_default
    end

    test "preserves in-flight mid-cycle keys exactly, unchanged" do
      behavior_state = %{
        stable: :accumulated,
        cycle_skill_ids: ["alpha", "beta"],
        resume_index: 1,
        pending_effect_skill_id: "beta"
      }

      snapshot = probe_snapshot(%{behavior_state: behavior_state})

      {state, _budget} = RuntimeAgent.restore_from_snapshot(ProbeBehavior, %{}, snapshot, "a1")

      assert state.cycle_skill_ids == ["alpha", "beta"]
      assert state.resume_index == 1
      assert state.pending_effect_skill_id == "beta"
    end

    test "runs migrate_state/3 when the stored version is older than schema_version/0" do
      snapshot = probe_snapshot(%{behavior_state: %{old_key: :accumulated}, schema_version: 0})

      {state, _budget} =
        RuntimeAgent.restore_from_snapshot(MigratingProbeBehavior, %{}, snapshot, "a1")

      assert state.renamed_key == :accumulated
      refute Map.has_key?(state, :old_key)
    end

    test "skips migrate_state/3 when the stored version is current" do
      snapshot =
        probe_snapshot(%{
          behavior_state: %{renamed_key: :accumulated, old_key: :untouched},
          schema_version: 2
        })

      {state, _budget} =
        RuntimeAgent.restore_from_snapshot(MigratingProbeBehavior, %{}, snapshot, "a1")

      assert state.renamed_key == :accumulated
      assert state.old_key == :untouched
    end

    test "a raising migrate_state/3 falls back to the raw snapshot state, restore still completes" do
      snapshot = probe_snapshot(%{behavior_state: %{stable: :accumulated}, schema_version: 0})

      {state, budget} =
        RuntimeAgent.restore_from_snapshot(RaisingMigrateProbeBehavior, %{}, snapshot, "a1")

      # Migration skipped, restore NOT abandoned: snapshot value preserved and
      # merge/backfill still applied.
      assert state.stable == :accumulated
      assert state.new_key == :fresh_default
      assert budget.llm_calls == 3
    end

    test "a raising reconcile_restored_state/2 falls back to the merged state, restore still completes" do
      snapshot = probe_snapshot(%{behavior_state: %{stable: :accumulated}})

      {state, budget} =
        RuntimeAgent.restore_from_snapshot(RaisingReconcileProbeBehavior, %{}, snapshot, "a1")

      assert state.stable == :accumulated
      assert state.new_key == :fresh_default
      assert budget.llm_calls == 3
    end

    test "reconcile_restored_state/2 runs on the merged state" do
      snapshot = probe_snapshot(%{behavior_state: %{stable: :accumulated}})

      {state, _budget} =
        RuntimeAgent.restore_from_snapshot(ReconcilingProbeBehavior, %{}, snapshot, "a1")

      assert state.stable == :accumulated
      assert state.reconciled == true
    end

    test "a snapshot with schema_version absent or nil restores without error, treated as 0" do
      absent =
        Map.delete(probe_snapshot(%{behavior_state: %{stable: :accumulated}}), :schema_version)

      {state, _budget} = RuntimeAgent.restore_from_snapshot(ProbeBehavior, %{}, absent, "a1")
      assert state.stable == :accumulated
      assert state.new_key == :fresh_default

      # nil (hand-edited row / future rollback) behaves identically, including
      # for a behavior that would migrate from version 0.
      explicit_nil =
        probe_snapshot(%{behavior_state: %{old_key: :accumulated}, schema_version: nil})

      {state, _budget} =
        RuntimeAgent.restore_from_snapshot(MigratingProbeBehavior, %{}, explicit_nil, "a1")

      assert state.renamed_key == :accumulated
    end

    test "budget merges over init_budget defaults: missing keys populated, present keys preserved" do
      snapshot =
        probe_snapshot(%{budget: %{llm_calls: 7, refilled_at: "2026-07-04T00:00:00Z"}})

      {_state, budget} = RuntimeAgent.restore_from_snapshot(ProbeBehavior, %{}, snapshot, "a1")

      assert budget.llm_calls == 7
      assert budget.refilled_at == "2026-07-04T00:00:00Z"
      # tool_calls was absent from the snapshot budget: backfilled.
      assert budget.tool_calls == 1000
    end

    test "a malformed snapshot map falls back to a fresh init and budget (outer boundary)" do
      # Missing :behavior_state / :budget entirely — nothing the inner
      # boundaries expect to handle. The outer rescue treats it like nil
      # (no snapshot) instead of wedging agent startup.
      {state, budget} =
        RuntimeAgent.restore_from_snapshot(ProbeBehavior, %{}, %{sequence_num: 1}, "a1")

      assert state == ProbeBehavior.init(%{})
      assert budget == %{llm_calls: 500, tool_calls: 1000}
    end
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
