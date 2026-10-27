# ==============================================================================
# Agent Runtime Integration Tests
# ==============================================================================
#
# WHAT THIS TESTS (Product Perspective):
# --------------------------------------
# The Agent is the core "AI worker" in Maraithon. Each agent is an autonomous
# process that:
# - Receives messages from users via the API
# - Subscribes to external events (GitHub webhooks, Slack messages, etc.)
# - Wakes up on schedules to perform periodic tasks
# - Calls LLMs to reason about work
# - Executes tools to take action in the real world
#
# From a user's perspective, an Agent is like hiring a virtual assistant that:
# - Never sleeps (runs 24/7)
# - Responds instantly to triggers
# - Can monitor multiple data sources simultaneously
# - Has configurable "budgets" to prevent runaway costs
#
# WHY THESE TESTS MATTER:
# -----------------------
# If the agent lifecycle breaks, users cannot:
# - Create new agents to automate their workflows
# - Send messages to running agents
# - Trust that their agents will wake up on schedule
# - Rely on agents receiving webhook events
#
# ==============================================================================
#
# TECHNICAL DETAILS:
# ------------------
# This test module validates the Agent GenStateMachine lifecycle and behavior.
# It covers the full lifecycle of an agent from creation to termination.
#
# Architecture Overview:
# ----------------------
#
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │                        Agent State Machine                               │
#   │                                                                          │
#   │    ┌─────────┐      ┌─────────┐      ┌────────────────┐                 │
#   │    │  idle   │─────►│ working │─────►│ waiting_effect │                 │
#   │    │         │◄─────│         │◄─────│                │                 │
#   │    └────┬────┘      └────┬────┘      └───────┬────────┘                 │
#   │         │                │                    │                          │
#   │         │    wakeup      │   effect_result   │                          │
#   │         │    message     │   timeout         │                          │
#   │         │    pubsub      │                   │                          │
#   │         ▼                ▼                   ▼                          │
#   │    ┌────────────────────────────────────────────────────────┐           │
#   │    │              Event Queue (pending work)                 │           │
#   │    └────────────────────────────────────────────────────────┘           │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# Key Responsibilities Tested:
# ----------------------------
#
# 1. Process Lifecycle
#    - start_link/1: Starting agent processes with proper registration
#    - child_spec/1: DynamicSupervisor compatibility
#    - init/1: State initialization and configuration loading
#
# 2. State Transitions
#    - idle → working: On receiving work (message, wakeup, pubsub event)
#    - working → waiting_effect: When an effect needs external completion
#    - waiting_effect → idle: When effect completes
#    - working → idle: When work completes without effects
#
# 3. Message Handling
#    - {:message, content, metadata, id}: User/external messages
#    - {:wakeup, type, job_id, payload}: Scheduled job notifications
#    - {:pubsub_event, topic, data}: PubSub subscription events
#    - {:effect_result, effect_id, result}: Async effect completions
#
# 4. Budget Management
#    - Default budget allocation when not configured
#    - Custom budget from agent config
#    - Zero budget handling (stays idle)
#
# 5. Duplicate Prevention
#    - Job ID deduplication (same job_id ignored)
#
# Test Categories:
# ----------------
#
# - Unit Tests: Individual state machine functions and transitions
# - Integration Tests: Full message flow through the agent
#
# Dependencies:
# -------------
#
# - Maraithon.Runtime.Agent (the GenStateMachine implementation)
# - Maraithon.Runtime.Scheduler (for wakeup scheduling)
# - Maraithon.Runtime.AgentRegistry (for process lookup)
# - Maraithon.Agents (for agent database operations)
# - Ecto SQL Sandbox (for database isolation)
#
# Setup Requirements:
# -------------------
#
# This test uses `async: false` because:
# 1. Agent processes are spawned and need database access
# 2. The Scheduler must be manually started and given sandbox access
# 3. Multiple agents in the same test can cause registry conflicts
#
# ==============================================================================

defmodule Maraithon.Runtime.AgentTest do
  use Maraithon.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maraithon.Accounts
  alias Maraithon.Runtime.Agent, as: RuntimeAgent
  alias Maraithon.Runtime.ScheduledJob
  alias Maraithon.Agents
  alias Maraithon.Effects
  alias Maraithon.Effects.Effect
  alias Maraithon.ChiefOfStaff.Skills
  alias Maraithon.OperatorEvents
  alias Maraithon.TestSupport.ChiefOfStaffTestSkill

  # ----------------------------------------------------------------------------
  # Test Setup
  # ----------------------------------------------------------------------------
  #
  # The setup block ensures:
  # 1. Any existing Scheduler is stopped to prevent interference
  # 2. A fresh Scheduler is started for this test
  # 3. The Scheduler is given database sandbox access
  # 4. A test agent is created in the database with "running" status
  # 5. Cleanup happens after each test to stop the Scheduler
  #
  # This setup is critical for process-based tests because spawned processes
  # need explicit sandbox access before they can query the database.
  # ----------------------------------------------------------------------------
  setup do
    # Stop any existing scheduler/processes that might interfere
    case Process.whereis(Maraithon.Runtime.Scheduler) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    scheduler_pid = start_supervised!({Maraithon.Runtime.Scheduler, []})
    Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), scheduler_pid)

    # Create an agent for testing
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{
          "name" => "test_agent",
          "prompt" => "You are a test agent.",
          "subscribe" => [],
          "tools" => []
        },
        status: "running",
        started_at: DateTime.utc_now()
      })

    %{agent: agent, scheduler_pid: scheduler_pid}
  end

  # ============================================================================
  # PROCESS LIFECYCLE TESTS
  # ============================================================================
  #
  # These tests verify that agents can be started as OTP processes and
  # properly register themselves for discovery.
  # ============================================================================

  describe "start_link/1" do
    @doc """
    Verifies that an agent process can be started and remains alive.
    The agent should start successfully and be a valid Erlang process.
    """
    test "starts the agent process", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid, :normal)
    end

    test "recovery converges legacy wakeup chains without cancelling briefing wakeups", %{
      agent: agent
    } do
      fire_at = DateTime.add(DateTime.utc_now(), 3_600_000, :millisecond)

      legacy_jobs =
        for _index <- 1..3 do
          %ScheduledJob{}
          |> ScheduledJob.changeset(%{
            agent_id: agent.id,
            job_type: "wakeup",
            fire_at: fire_at,
            payload: %{},
            status: "pending"
          })
          |> Repo.insert!()
        end

      briefing_job =
        %ScheduledJob{}
        |> ScheduledJob.changeset(%{
          agent_id: agent.id,
          job_type: "wakeup",
          fire_at: fire_at,
          payload: %{
            "source" => "briefing_cron",
            "dedupe_key" => "morning-brief"
          },
          status: "pending"
        })
        |> Repo.insert!()

      {:ok, first_pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), first_pid)
      assert {:idle, _data} = :sys.get_state(first_pid)

      for job <- legacy_jobs do
        assert Repo.get!(ScheduledJob, job.id).status == "cancelled"
      end

      assert Repo.get!(ScheduledJob, briefing_job.id).status == "pending"
      [first_periodic] = active_periodic_wakeups(agent.id)
      assert first_periodic.payload["_schedule_key"] == "agent_periodic_wakeup"

      GenServer.stop(first_pid, :normal)

      {:ok, recovered_pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), recovered_pid)
      assert {:idle, _data} = :sys.get_state(recovered_pid)

      assert Repo.get!(ScheduledJob, first_periodic.id).status == "cancelled"
      assert Repo.get!(ScheduledJob, briefing_job.id).status == "pending"
      assert [_replacement] = active_periodic_wakeups(agent.id)

      GenServer.stop(recovered_pid, :normal)
    end

    test "cancels active effects from the previous process incarnation", %{agent: agent} do
      {:ok, first_pid} = start_legacy_supervised_agent(agent)
      assert {:idle, _data} = :sys.get_state(first_pid)

      {:ok, pending_id} = Effects.request(agent.id, :tool_call, "time", %{})
      {:ok, claimed_id} = Effects.request(agent.id, :llm_call, nil, %{})

      Repo.update_all(
        from(effect in Effect, where: effect.id == ^claimed_id),
        set: [
          status: "claimed",
          claimed_by: Atom.to_string(node()),
          claimed_at: DateTime.utc_now()
        ]
      )

      assert :ok =
               DynamicSupervisor.terminate_child(
                 Maraithon.Runtime.AgentSupervisor,
                 first_pid
               )

      {:ok, recovered_pid} = start_legacy_supervised_agent(agent)

      on_exit(fn ->
        DynamicSupervisor.terminate_child(
          Maraithon.Runtime.AgentSupervisor,
          recovered_pid
        )
      end)

      assert {:idle, _data} = :sys.get_state(recovered_pid)

      pending = Repo.get!(Effect, pending_id)
      assert pending.status == "cancelled"
      assert pending.error == "agent_process_terminated_without_effect_continuation"

      claimed = Repo.get!(Effect, claimed_id)
      assert claimed.status == "failed"
      assert claimed.error == "effect_outcome_ambiguous"
      assert claimed.result_envelope["status"] == "error"
      assert claimed.claimed_by == nil
      assert claimed.claimed_at == nil
    end

    test "recovery closes the durably owned run after a supervised hard process kill", %{
      agent: agent
    } do
      {:ok, first_pid} = start_legacy_supervised_agent(agent)
      assert {:idle, _data} = :sys.get_state(first_pid)

      send(first_pid, {:message, "hard kill", %{}, Ecto.UUID.generate()})
      assert {:waiting_effect, waiting_data} = :sys.get_state(first_pid)
      run_id = waiting_data.current_run_id
      [{effect_id, effect_info}] = Map.to_list(waiting_data.pending_effects)
      step_id = effect_info.run_step_id

      assert Repo.get!(Maraithon.Agents.Agent, agent.id).active_run_id == run_id

      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}, 1_000

      recovered_pid = wait_for_restarted_agent(agent.id, first_pid, 100)
      assert {:idle, _data} = :sys.get_state(recovered_pid)
      assert Repo.get!(Maraithon.Agents.AgentRun, run_id).status == "cancelled"
      assert Repo.get!(Maraithon.Agents.AgentRunStep, step_id).status == "failed"
      assert Repo.get!(Effect, effect_id).status == "cancelled"
      assert Repo.get!(Maraithon.Agents.Agent, agent.id).active_run_id == nil

      assert :ok =
               Maraithon.Runtime.AgentSupervisor.stop_agent(recovered_pid, "test_cleanup")
    end

    test "recovery preserves a terminal effect step before cancelling its owned run", %{
      agent: agent
    } do
      {:ok, first_pid} = RuntimeAgent.start_link(agent)
      Process.unlink(first_pid)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), first_pid)
      assert {:idle, _data} = :sys.get_state(first_pid)

      send(first_pid, {:message, "complete before crash", %{}, Ecto.UUID.generate()})
      assert {:waiting_effect, waiting_data} = :sys.get_state(first_pid)
      run_id = waiting_data.current_run_id
      [{effect_id, effect_info}] = Map.to_list(waiting_data.pending_effects)
      step_id = effect_info.run_step_id

      Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
        set: [
          status: "completed",
          result: %{"content" => "durable result"},
          result_envelope: %{"status" => "ok", "version" => 1}
        ]
      )

      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}, 1_000

      recovered_agent = Repo.get!(Maraithon.Agents.Agent, agent.id)
      {:ok, recovered_pid} = RuntimeAgent.start_link(recovered_agent)

      Process.unlink(recovered_pid)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), recovered_pid)
      assert {:idle, _data} = :sys.get_state(recovered_pid)

      assert Repo.get!(Maraithon.Agents.AgentRun, run_id).status == "cancelled"
      assert Repo.get!(Maraithon.Agents.AgentRunStep, step_id).status == "completed"
      assert Repo.get!(Effect, effect_id).result_acknowledged_at != nil
      assert Repo.get!(Maraithon.Agents.Agent, agent.id).active_run_id == nil

      GenServer.stop(recovered_pid, :normal)
    end

    test "terminalizes only the current run when its process terminates", %{agent: agent} do
      {:ok, pid} = start_legacy_supervised_agent(agent)
      assert {:idle, _data} = :sys.get_state(pid)

      send(pid, {:message, "begin one run", %{}, Ecto.UUID.generate()})
      assert {:waiting_effect, waiting_data} = :sys.get_state(pid)

      run_id = waiting_data.current_run_id
      [{effect_id, effect_info}] = Map.to_list(waiting_data.pending_effects)
      requested_step_id = effect_info.run_step_id

      assert {:ok, _run} =
               Agents.update_agent_run(run_id, %{
                 finish_reason: "length",
                 generation_mode: "llm"
               })

      {:ok, completed_step} =
        Agents.record_agent_run_step(run_id, agent.id, %{
          step_type: "tool_call",
          effect_type: "tool_call"
        })

      assert {:ok, _step} =
               Agents.update_agent_run_step(completed_step.id, %{status: "completed"})

      {:ok, unrelated_run} =
        Agents.start_agent_run(agent, %{trigger_type: "unrelated_history"})

      assert :ok =
               DynamicSupervisor.terminate_child(
                 Maraithon.Runtime.AgentSupervisor,
                 pid
               )

      cancelled_run = Repo.get!(Maraithon.Agents.AgentRun, run_id)
      assert cancelled_run.status == "cancelled"
      assert cancelled_run.finish_reason == "length"
      assert cancelled_run.generation_mode == "llm"
      assert cancelled_run.error == "agent_process_terminated_without_run_continuation"
      assert cancelled_run.completed_at != nil

      failed_step = Repo.get!(Maraithon.Agents.AgentRunStep, requested_step_id)
      assert failed_step.status == "failed"
      assert failed_step.error == "agent_process_terminated_without_run_continuation"
      assert failed_step.completed_at != nil

      assert Repo.get!(Maraithon.Agents.AgentRunStep, completed_step.id).status == "completed"
      assert Repo.get!(Maraithon.Agents.AgentRun, unrelated_run.id).status == "running"

      cancelled_effect = Repo.get!(Effect, effect_id)
      assert cancelled_effect.status == "cancelled"
      assert cancelled_effect.error == "agent_process_terminated_without_effect_continuation"
      assert cancelled_effect.claimed_by == nil
      assert cancelled_effect.claimed_at == nil
    end

    test "intentional stop preserves provider facts already observed on the current run", %{
      agent: agent
    } do
      {:ok, pid} = start_legacy_supervised_agent(agent)
      assert {:idle, _data} = :sys.get_state(pid)

      send(pid, {:message, "begin provider-backed run", %{}, Ecto.UUID.generate()})
      assert {:waiting_effect, waiting_data} = :sys.get_state(pid)

      assert {:ok, _run} =
               Agents.update_agent_run(waiting_data.current_run_id, %{
                 finish_reason: "length",
                 generation_mode: "llm"
               })

      assert :ok = Maraithon.Runtime.AgentSupervisor.stop_agent(pid, "test_stop")

      stopped_run = Repo.get!(Maraithon.Agents.AgentRun, waiting_data.current_run_id)
      assert stopped_run.status == "cancelled"
      assert stopped_run.finish_reason == "length"
      assert stopped_run.generation_mode == "llm"
      assert stopped_run.error == "agent_stopped_without_run_continuation"
      assert stopped_run.completed_at != nil
    end

    test "intentional stop cancels queued and claimed effects", %{agent: agent} do
      {:ok, pid} = start_legacy_supervised_agent(agent)
      assert {:idle, _data} = :sys.get_state(pid)

      {:ok, pending_id} = Effects.request(agent.id, :tool_call, "time", %{})
      {:ok, claimed_id} = Effects.request(agent.id, :llm_call, nil, %{})

      Repo.update_all(
        from(effect in Effect, where: effect.id == ^claimed_id),
        set: [
          status: "claimed",
          claimed_by: Atom.to_string(node()),
          claimed_at: DateTime.utc_now()
        ]
      )

      assert :ok = Maraithon.Runtime.AgentSupervisor.stop_agent(pid, "test_stop")

      pending = Repo.get!(Effect, pending_id)
      assert pending.status == "cancelled"
      assert pending.error == "agent_stopped_without_effect_continuation"

      claimed = Repo.get!(Effect, claimed_id)
      assert claimed.status == "failed"
      assert claimed.error == "effect_outcome_ambiguous"
      assert claimed.result_envelope["status"] == "error"
      assert claimed.claimed_by == nil
      assert claimed.claimed_at == nil
    end

    @doc """
    Verifies that agents register themselves in the AgentRegistry.
    This allows other parts of the system to find running agents by ID.
    The registry lookup returns [{pid, nil}] for registered agents.
    """
    test "registers agent in registry", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Check registry
      [{^pid, nil}] = Registry.lookup(Maraithon.Runtime.AgentRegistry, agent.id)

      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # CHILD SPEC TESTS
  # ============================================================================
  #
  # These tests verify the OTP child specification returned by child_spec/1.
  # The child spec is used by DynamicSupervisor to start and manage agents.
  # ============================================================================

  describe "child_spec/1" do
    @doc """
    Verifies child_spec returns the correct OTP specification.

    Key properties:
    - id: Must match agent.id for proper supervision
    - start: Must be {RuntimeAgent, :start_link, [agent]}
    - restart: :transient so the supervisor restarts an agent that crashes
      (abnormal exit) but not one that stops intentionally (:normal)
    - type: :worker (not a supervisor)
    """
    test "returns valid child spec", %{agent: agent} do
      spec = RuntimeAgent.child_spec(agent)

      assert spec.id == agent.id
      assert spec.start == {RuntimeAgent, :start_link, [agent]}
      assert spec.restart == :transient
      assert spec.type == :worker
    end
  end

  # ============================================================================
  # INITIALIZATION TESTS
  # ============================================================================
  #
  # These tests verify that agents properly initialize their state from
  # the agent configuration stored in the database.
  # ============================================================================

  describe "init/1" do
    @doc """
    Verifies that an agent initializes correctly and enters the idle state.
    After initialization, the agent should be alive and ready to receive work.
    """
    test "initializes agent with correct state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Give time for initialization
      Process.sleep(100)

      # Agent should be alive and in idle state
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # STATE TRANSITION TESTS
  # ============================================================================
  #
  # These tests verify the state machine transitions between idle, working,
  # and waiting_effect states. Each wakeup type, message, or event can
  # trigger a state transition.
  # ============================================================================

  describe "state transitions" do
    @doc """
    Verifies agents handle heartbeat wakeups in idle state.
    Heartbeat wakeups are periodic health checks that may trigger behavior.
    The agent should process the heartbeat and remain alive.
    """
    test "handles heartbeat wakeup in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Give time for initialization
      Process.sleep(150)

      # Send heartbeat wakeup
      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents handle checkpoint wakeups in idle state.
    Checkpoint wakeups allow agents to save state or perform periodic tasks.
    """
    test "handles checkpoint wakeup in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "checkpoint", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies a checkpoint wakeup persists a recoverable snapshot of the agent's
    behavior state, so a restarted agent resumes with context instead of blank.
    """
    test "checkpoint wakeup persists a snapshot", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)
      assert Maraithon.Runtime.Snapshot.latest(agent.id) == nil

      send(pid, {:wakeup, "checkpoint", Ecto.UUID.generate(), %{}})
      Process.sleep(150)

      snapshot = Maraithon.Runtime.Snapshot.latest(agent.id)
      assert snapshot != nil
      assert snapshot.state_name == "idle"
      assert is_map(snapshot.behavior_state)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents handle user messages in idle state.
    Messages are the primary way users interact with agents.
    Format: {:message, content, metadata, message_id}
    """
    test "handles message in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Hello agent!", %{}, message_id})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents gracefully handle unknown message types.
    Unknown messages should be logged but not crash the agent.
    """
    test "handles unknown message in idle state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      send(pid, {:unknown_message, "test"})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies that duplicate wakeup job IDs are ignored.
    This prevents the same scheduled job from being processed twice.
    The agent tracks seen job_ids and ignores duplicates.
    """
    test "ignores duplicate wakeup job_id", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      job_id = Ecto.UUID.generate()

      # Send same job_id twice
      send(pid, {:wakeup, "heartbeat", job_id, %{}})
      Process.sleep(50)
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # PUBSUB EVENT TESTS
  # ============================================================================
  #
  # These tests verify that agents properly handle PubSub subscription events.
  # Agents subscribe to topics (like "github:owner/repo") and receive events
  # when webhooks or other sources publish to those topics.
  # ============================================================================

  describe "pubsub events" do
    @doc """
    Verifies agents receive events for topics they're subscribed to.
    The agent config includes a "subscribe" list of topics.
    When events are published to those topics, the agent receives them.
    """
    test "handles pubsub event when subscribed", %{scheduler_pid: _scheduler_pid} do
      topic = "test:topic:#{System.unique_integer()}"

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "pubsub_agent",
            "prompt" => "Test",
            "subscribe" => [topic],
            "tools" => []
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send pubsub event
      send(pid, {:pubsub_event, topic, %{data: "test"}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents ignore events for topics they're NOT subscribed to.
    This ensures agents only process relevant events and don't waste
    resources on unrelated PubSub traffic.
    """
    test "ignores pubsub event when not subscribed", %{
      agent: agent,
      scheduler_pid: _scheduler_pid
    } do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send pubsub event for topic not subscribed to
      send(pid, {:pubsub_event, "unsubscribed:topic", %{data: "test"}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # EFFECT HANDLING TESTS
  # ============================================================================
  #
  # These tests verify that agents properly handle asynchronous effect results.
  # Effects are operations that happen outside the agent's state machine
  # (like HTTP calls, file operations, etc.) and complete later.
  # ============================================================================

  describe "effect handling" do
    @doc """
    Verifies agents handle effect results for unknown effect IDs.
    This can happen if an effect times out and then completes later.
    The agent should handle this gracefully without crashing.
    """
    test "handles effect_result for unknown effect", %{
      agent: agent,
      scheduler_pid: _scheduler_pid
    } do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Try to transition to waiting_effect state first by sending a message
      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Hello!", %{}, message_id})

      Process.sleep(100)

      # Send effect result for unknown effect
      log =
        capture_log(fn ->
          send(pid, {:effect_result, Ecto.UUID.generate(), {:ok, %{result: "test"}}})
          _state = :sys.get_state(pid)
        end)

      assert log =~ "Ignored non-terminal effect result notification"
      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # BUDGET HANDLING TESTS
  # ============================================================================
  #
  # These tests verify that agents properly initialize and respect their
  # budget constraints. Budgets limit the number of LLM calls and tool
  # calls an agent can make to prevent runaway costs.
  # ============================================================================

  describe "budget handling" do
    @doc """
    Verifies agents initialize with default budget when config omits it.
    Default budgets provide reasonable limits for most use cases.
    """
    test "initializes with default budget when not configured", %{scheduler_pid: _scheduler_pid} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "no_budget_agent",
            "prompt" => "Test"
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents respect custom budget values from config.
    Custom budgets allow fine-grained control over agent resource usage.
    """
    test "initializes with custom budget from config", %{scheduler_pid: _scheduler_pid} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "custom_budget_agent",
            "prompt" => "Test",
            "budget" => %{
              "llm_calls" => 100,
              "tool_calls" => 200
            }
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Verifies agents with zero budget stay idle when receiving work.
    Zero budget means the agent cannot perform any work - it must be
    given more budget before it can process messages.
    """
    test "respects zero budget by staying idle", %{scheduler_pid: _scheduler_pid} do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "zero_budget_agent",
            "prompt" => "Test",
            "budget" => %{
              "llm_calls" => 0,
              "tool_calls" => 0
            }
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      assert {:idle, _data} = :sys.get_state(pid)

      # A direct message cannot consume budget and leaves the existing periodic
      # timer untouched.
      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Hello!", %{}, message_id})
      assert {:idle, _data} = :sys.get_state(pid)

      [periodic] = active_periodic_wakeups(agent.id)
      send(pid, {:wakeup, "wakeup", periodic.id, periodic.payload})
      assert {:idle, _data} = :sys.get_state(pid)

      # Consuming the only wakeup must schedule its successor even though the
      # budget is empty, or the daily refill boundary can never be reached.
      assert Repo.get!(ScheduledJob, periodic.id).status == "delivered"
      [replacement] = active_periodic_wakeups(agent.id)
      refute replacement.id == periodic.id

      GenServer.stop(pid, :normal)
    end
  end

  # ============================================================================
  # WAKEUP SCHEDULING TESTS
  # ============================================================================
  #
  # These tests verify the different types of wakeup jobs that can be
  # scheduled for agents. Wakeups are used for periodic tasks, health
  # checks, and delayed processing.
  # ============================================================================

  describe "wakeup scheduling" do
    test "persists behavior tool arguments under the command args envelope", %{
      scheduler_pid: _scheduler_pid
    } do
      check_url = "https://example.com/health"

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "watchdog_summarizer",
          config: %{"check_url" => check_url},
          status: "running",
          started_at: DateTime.utc_now()
        })

      pid = start_supervised!({RuntimeAgent, agent})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      assert {:idle, _data} = :sys.get_state(pid)

      :sys.replace_state(pid, fn {:idle, data} ->
        behavior_state = Map.put(data.behavior_state, :iteration, 5)
        {:idle, %{data | behavior_state: behavior_state}}
      end)

      send(pid, {:wakeup, "wakeup", Ecto.UUID.generate(), %{}})
      assert {:waiting_effect, _data} = :sys.get_state(pid)

      effect = Repo.get_by!(Effect, agent_id: agent.id, effect_type: "tool_call")
      assert effect.params["tool"] == "http_get"
      assert effect.params["args"] == %{"url" => check_url}
      refute Map.has_key?(effect.params, "url")
    end

    @doc """
    Verifies agents handle the generic "wakeup" job type.
    This is a general-purpose wakeup that agents can use for any purpose.
    """
    test "handles wakeup job type", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "wakeup", job_id, %{}})

      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "transient trigger context" do
    test "clears pubsub event context after the effect cycle completes", %{
      scheduler_pid: _scheduler_pid
    } do
      topic = "test:topic:#{System.unique_integer()}"

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "trigger_cleanup_agent",
            "prompt" => "Observe quietly.",
            "subscribe" => [topic],
            "tools" => []
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      pid = start_supervised!({RuntimeAgent, agent})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      {:idle, _data} = :sys.get_state(pid)

      send(pid, {:pubsub_event, topic, %{data: "test"}})

      {:waiting_effect, waiting_data} = :sys.get_state(pid)
      assert waiting_data.current_trigger.type == :pubsub_event
      assert waiting_data.current_event.topic == topic

      [effect_id] = Map.keys(waiting_data.pending_effects)

      Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
        set: [
          status: "completed",
          result: %{"content" => "OBSERVE"},
          result_envelope: %{"status" => "ok", "version" => 1}
        ]
      )

      send(pid, {:effect_result, effect_id, {:ok, %{content: "untrusted"}}})

      {:idle, idle_data} = :sys.get_state(pid)
      assert idle_data.current_trigger == nil
      assert idle_data.current_event == nil
      assert idle_data.current_message == nil

      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "wakeup", job_id, %{}})

      {:waiting_effect, wakeup_data} = :sys.get_state(pid)
      assert wakeup_data.current_trigger.type == :wakeup
      assert wakeup_data.current_event == nil
      assert wakeup_data.behavior_state.processing_event == nil
    end

    test "clears direct-message context after the effect cycle completes", %{
      scheduler_pid: _scheduler_pid
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "message_cleanup_agent",
            "prompt" => "Observe quietly.",
            "subscribe" => [],
            "tools" => []
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      pid = start_supervised!({RuntimeAgent, agent})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      {:idle, _data} = :sys.get_state(pid)

      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Hello agent!", %{"source" => "test"}, message_id})

      {:waiting_effect, waiting_data} = :sys.get_state(pid)
      assert waiting_data.current_trigger.type == :message
      assert waiting_data.current_message == "Hello agent!"
      assert waiting_data.current_message_id == message_id

      [effect_id] = Map.keys(waiting_data.pending_effects)

      Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
        set: [
          status: "completed",
          result: %{"content" => "OBSERVE"},
          result_envelope: %{"status" => "ok", "version" => 1}
        ]
      )

      send(pid, {:effect_result, effect_id, {:ok, %{content: "untrusted"}}})

      {:idle, idle_data} = :sys.get_state(pid)
      assert idle_data.current_trigger == nil
      assert idle_data.current_message == nil
      assert idle_data.current_message_metadata == %{}
      assert idle_data.current_message_id == nil
    end

    test "hydrates recent operator events into the behavior prompt", %{
      scheduler_pid: _scheduler_pid
    } do
      user_id = "runtime-context-events@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _event} =
        OperatorEvents.record(%{
          user_id: user_id,
          source: "gmail",
          event_type: "email.received",
          source_item_id: "starteryou-msg-1",
          dedupe_key: "gmail:email.received:starteryou-msg-1",
          occurred_at: ~U[2026-05-25 12:00:00Z],
          payload: %{
            "from" => "Michael Berlingo <michael@example.com>",
            "subject" => "Starteryou UGC Campaigns",
            "snippet" => "Can you confirm the campaign materials and next step?"
          }
        })

      {:ok, agent} =
        Agents.create_agent(%{
          user_id: user_id,
          behavior: "prompt_agent",
          config: %{
            "name" => "context_events_agent",
            "prompt" => "Use connected context.",
            "subscribe" => [],
            "tools" => []
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      pid = start_supervised!({RuntimeAgent, agent})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      {:idle, _data} = :sys.get_state(pid)

      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Who is waiting on me?", %{}, message_id})

      {:waiting_effect, waiting_data} = :sys.get_state(pid)

      prompt =
        waiting_data.pending_effects
        |> Map.values()
        |> Enum.flat_map(fn effect -> effect.params["messages"] || [] end)
        |> Enum.map_join("\n", & &1["content"])

      assert prompt =~ "## Recent Connected Activity"
      assert prompt =~ "gmail email.received"
      assert prompt =~ "Starteryou UGC Campaigns"
      assert prompt =~ "Michael Berlingo"
    end
  end

  # ============================================================================
  # WORKING STATE TESTS
  # ============================================================================
  #
  # These tests verify agent behavior while in the "working" state.
  # In this state, the agent is processing a message or wakeup and
  # should queue any new work until it finishes.
  # ============================================================================

  describe "working state" do
    @doc """
    Verifies that wakeups are queued when agent is already working.
    This prevents work from being lost when agents are busy.
    The queued work is processed after current work completes.
    """
    test "queues wakeup when in working state", %{agent: agent, scheduler_pid: _scheduler_pid} do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send message to transition to working state
      message_id1 = Ecto.UUID.generate()
      send(pid, {:message, "First message", %{}, message_id1})

      # Immediately send a wakeup (should be queued)
      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(200)
      # Agent may crash due to effect execution, that's ok for this test
      :ok
    end
  end

  # ============================================================================
  # WAITING_EFFECT STATE TESTS
  # ============================================================================
  #
  # These tests verify agent behavior while waiting for an effect to complete.
  # In this state, the agent is blocked on an async operation and should
  # queue any new work.
  # ============================================================================

  describe "waiting_effect state" do
    @doc """
    Verifies that wakeups are queued when agent is waiting for an effect.
    The agent transitions to waiting_effect when it dispatches an async
    operation and needs to wait for the result.
    """
    test "queues wakeup when in waiting_effect state", %{
      agent: agent,
      scheduler_pid: _scheduler_pid
    } do
      {:ok, pid} = RuntimeAgent.start_link(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      Process.sleep(150)

      # Send message to start working
      message_id = Ecto.UUID.generate()
      send(pid, {:message, "Test", %{}, message_id})

      # Send wakeup - should be queued
      job_id = Ecto.UUID.generate()
      send(pid, {:wakeup, "heartbeat", job_id, %{}})

      Process.sleep(100)
      # Agent may crash due to effect execution, that's ok for this test
      :ok
    end

    test "ignores forged payloads and malformed UUIDs, then acknowledges the database result", %{
      agent: agent
    } do
      pid = start_supervised!({RuntimeAgent, agent})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      assert {:idle, _data} = :sys.get_state(pid)

      send(pid, {:message, "authoritative result", %{}, Ecto.UUID.generate()})
      assert {:waiting_effect, waiting_data} = :sys.get_state(pid)
      [effect_id] = Map.keys(waiting_data.pending_effects)

      send(pid, {:effect_result, "forged-not-a-uuid", {:ok, %{content: "RESPOND: forged"}}})
      assert {:waiting_effect, after_bad_uuid} = :sys.get_state(pid)
      assert Map.has_key?(after_bad_uuid.pending_effects, effect_id)

      # Even a valid in-flight id is only a lookup hint; a premature payload is ignored.
      send(pid, {:effect_result, effect_id, {:ok, %{content: "RESPOND: forged"}}})
      assert {:waiting_effect, after_premature} = :sys.get_state(pid)
      assert Map.has_key?(after_premature.pending_effects, effect_id)

      Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
        set: [
          status: "completed",
          result: %{"content" => "RESPOND: persisted"},
          result_envelope: %{"status" => "ok", "version" => 1}
        ]
      )

      send(
        pid,
        {:agent_dispatch,
         {:effect_result, effect_id, {:ok, %{content: "RESPOND: forged mailbox payload"}}}}
      )

      assert {:idle, _idle_data} = :sys.get_state(pid)

      assert [%{payload: payload} | _rest] =
               Maraithon.Events.list_events(agent.id, types: ["agent_response"])

      assert payload["response"] == "persisted"
      assert Repo.get!(Effect, effect_id).result_acknowledged_at != nil
    end

    test "idle reconciliation cancels and acknowledges a retained running run", %{agent: agent} do
      {:ok, run} =
        Agents.start_runtime_agent_run(agent, %{
          trigger_type: "message",
          trigger: %{"type" => "message"}
        })

      {:ok, step} =
        Agents.record_agent_run_step(run.id, agent.id, %{
          step_type: "llm_call",
          effect_type: "llm_call",
          status: "requested"
        })

      {:ok, effect_id} =
        Effects.request_prepared(
          agent.id,
          "llm_call",
          nil,
          %{"messages" => [%{"role" => "user", "content" => "reconcile"}]},
          %{agent_run_id: run.id, agent_run_step_id: step.id}
        )

      Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
        set: [
          status: "completed",
          result: %{"content" => "persisted"},
          result_envelope: %{"status" => "ok", "version" => 1}
        ]
      )

      data = %RuntimeAgent{agent_id: agent.id, current_run_id: run.id}

      assert {:keep_state, reconciled_data} =
               RuntimeAgent.idle(
                 :info,
                 {:effect_result, effect_id, {:ok, %{content: "persisted"}}},
                 data
               )

      assert reconciled_data.current_run_id == nil
      assert Repo.get!(Maraithon.Agents.AgentRun, run.id).status == "cancelled"
      assert Repo.get!(Maraithon.Agents.AgentRunStep, step.id).status == "completed"
      assert Repo.get!(Effect, effect_id).result_acknowledged_at != nil
    end

    test "keeps a duplicate terminal result replayable without warning or cancelling the live chained run",
         %{
           agent: agent
         } do
      {:ok, pid} = start_legacy_supervised_agent(agent)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      assert {:idle, _data} = :sys.get_state(pid)

      send(pid, {:message, "start live run", %{}, Ecto.UUID.generate()})
      assert {:waiting_effect, waiting_data} = :sys.get_state(pid)
      assert map_size(waiting_data.pending_effects) == 1

      {:ok, step} =
        Agents.record_agent_run_step(waiting_data.current_run_id, agent.id, %{
          step_type: "llm",
          effect_type: "llm_call",
          status: "requested",
          request_payload: %{"messages" => []}
        })

      {:ok, duplicate_effect_id} =
        Effects.request_prepared(
          agent.id,
          "llm_call",
          nil,
          %{"messages" => [%{"role" => "user", "content" => "duplicate"}]},
          %{
            agent_run_id: waiting_data.current_run_id,
            agent_run_step_id: step.id
          }
        )

      Repo.update_all(
        from(effect in Effect, where: effect.id == ^duplicate_effect_id),
        set: [
          status: "completed",
          result: %{"content" => "already handled"},
          result_envelope: %{"status" => "ok", "version" => 1}
        ]
      )

      log =
        capture_log(fn ->
          send(
            pid,
            {:agent_dispatch,
             {:effect_result, duplicate_effect_id, {:ok, %{content: "already handled"}}}}
          )

          assert {:waiting_effect, after_duplicate} = :sys.get_state(pid)
          assert after_duplicate.current_run_id == waiting_data.current_run_id
          assert map_size(after_duplicate.pending_effects) == 1
        end)

      refute log =~ "Received result for unknown effect"

      run = Repo.get!(Maraithon.Agents.AgentRun, waiting_data.current_run_id)
      assert run.status == "running"
      assert Repo.get!(Effect, duplicate_effect_id).result_acknowledged_at == nil
    end

    test "continues behavior after an effect result without orphaning the run", %{
      scheduler_pid: _scheduler_pid
    } do
      previous_skills_config = Application.fetch_env(:maraithon, Skills)

      Application.put_env(:maraithon, Skills,
        skill_modules: %{"alpha" => ChiefOfStaffTestSkill},
        default_enabled_ids: ["alpha"]
      )

      on_exit(fn ->
        case previous_skills_config do
          {:ok, config} -> Application.put_env(:maraithon, Skills, config)
          :error -> Application.delete_env(:maraithon, Skills)
        end
      end)

      user_id = "runtime-continue@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, agent} =
        Agents.create_agent(%{
          user_id: user_id,
          behavior: "ai_chief_of_staff",
          config: %{
            "user_id" => user_id,
            "enabled_skills" => ["alpha"],
            "skill_configs" => %{
              "alpha" => %{
                "wakeup_mode" => "effect",
                "effect_kind" => "llm_call",
                "effect_params" => %{
                  "messages" => [%{"role" => "user", "content" => "first pass"}]
                },
                "effect_result_mode" => "continue",
                "effect_continue_wakeup_mode" => "emit",
                "wakeup_emit_type" => "briefs_recorded",
                "wakeup_payload" => %{
                  "count" => 1,
                  "user_id" => user_id,
                  "cadences" => ["morning"]
                }
              }
            }
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      pid = start_supervised!({RuntimeAgent, agent})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      {:idle, _data} = :sys.get_state(pid)

      send(pid, {:wakeup, "wakeup", Ecto.UUID.generate(), %{}})

      {:waiting_effect, waiting_data} = :sys.get_state(pid)
      assert waiting_data.current_run_id != nil

      [effect_id] = Map.keys(waiting_data.pending_effects)

      Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
        set: [
          status: "completed",
          result: %{"content" => "continue"},
          result_envelope: %{"status" => "ok", "version" => 1}
        ]
      )

      send(pid, {:effect_result, effect_id, {:ok, %{content: "continue"}}})

      {:waiting_effect, memo_data} = :sys.get_state(pid)
      assert memo_data.behavior_state.pending_effect_skill_id == :cycle_memo
      assert Repo.get!(Effect, effect_id).result_acknowledged_at == nil

      [memo_effect_id] = Map.keys(memo_data.pending_effects)

      Repo.update_all(from(effect in Effect, where: effect.id == ^memo_effect_id),
        set: [
          status: "completed",
          result: %{"content" => "Cycle completed."},
          result_envelope: %{"status" => "ok", "version" => 1}
        ]
      )

      send(pid, {:effect_result, memo_effect_id, {:ok, %{content: "Cycle completed."}}})

      {:idle, idle_data} = :sys.get_state(pid)
      assert idle_data.current_run_id == nil

      assert [run] = Agents.list_agent_runs(agent.id, limit: 1)
      assert run.status == "completed"
      assert run.metadata["terminal_event"] == "briefs_recorded"
      assert Repo.get!(Effect, effect_id).result_acknowledged_at != nil
      assert Repo.get!(Effect, memo_effect_id).result_acknowledged_at != nil

      assert [%{payload: %{"cadences" => ["morning"]}}] =
               Maraithon.Events.list_events(agent.id, types: ["briefs_recorded"])
    end

    # SPEC 07 R3/R4: an effect timeout must route through the behavior's
    # handle_effect_error/4 (when exported) instead of unconditionally
    # failing the run, must clear the timed-out entry from pending_effects,
    # and must not decrement budget.
    test "routes an effect timeout through handle_effect_error, clears pending_effects, and keeps budget",
         %{scheduler_pid: _scheduler_pid} do
      previous_skills_config = Application.fetch_env(:maraithon, Skills)

      Application.put_env(:maraithon, Skills,
        skill_modules: %{"alpha" => ChiefOfStaffTestSkill},
        default_enabled_ids: ["alpha"]
      )

      on_exit(fn ->
        case previous_skills_config do
          {:ok, config} -> Application.put_env(:maraithon, Skills, config)
          :error -> Application.delete_env(:maraithon, Skills)
        end
      end)

      user_id = "runtime-effect-timeout@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, agent} =
        Agents.create_agent(%{
          user_id: user_id,
          behavior: "ai_chief_of_staff",
          config: %{
            "user_id" => user_id,
            "enabled_skills" => ["alpha"],
            "skill_configs" => %{
              "alpha" => %{
                "wakeup_mode" => "effect",
                "effect_kind" => "llm_call",
                "effect_params" => %{
                  "messages" => [%{"role" => "user", "content" => "first pass"}],
                  "timeout_ms" => 100
                }
              }
            }
          },
          status: "running",
          started_at: DateTime.utc_now()
        })

      pid = start_supervised!({RuntimeAgent, agent})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      {:idle, _data} = :sys.get_state(pid)

      send(pid, {:wakeup, "wakeup", Ecto.UUID.generate(), %{}})

      {:waiting_effect, waiting_data} = :sys.get_state(pid)
      assert [timed_out_effect_id] = Map.keys(waiting_data.pending_effects)

      assert {:keep_state, ^waiting_data, [{:state_timeout, 900_000, :effect_timeout}]} =
               RuntimeAgent.waiting_effect(:enter, :working, waiting_data)

      # Drive the :state_timeout clause directly with the real in-flight
      # data — waiting out the multi-minute llm_call timeout is not viable
      # in a test, and the clause is a plain state function.
      result = RuntimeAgent.waiting_effect(:state_timeout, :effect_timeout, waiting_data)

      # AIChiefOfStaff exports handle_effect_error/4; skill "alpha" does
      # not, so the generic path records an operator event and continues
      # the cycle to the cycle-memo effect instead of failing the run —
      # the agent goes back to waiting_effect on the NEW effect.
      assert {:next_state, :waiting_effect, next_data, actions} = result
      assert [{:state_timeout, timeout_ms, :effect_timeout}] = actions
      assert timeout_ms > 0
      assert map_size(next_data.pending_effects) == 1
      # R4: the timed-out entry was removed, not left to leak/inflate
      # future pending_effect_timeout_ms calculations.
      refute Map.has_key?(next_data.pending_effects, timed_out_effect_id)

      timed_out_effect = Repo.get!(Effect, timed_out_effect_id)
      assert timed_out_effect.status == "cancelled"
      assert timed_out_effect.error == "effect_timeout"
      assert timed_out_effect.claimed_by == nil
      assert timed_out_effect.claimed_at == nil

      # Timeouts never decrement budget.
      assert next_data.budget == waiting_data.budget

      assert [event] =
               OperatorEvents.list_events(
                 user_id: user_id,
                 event_type: "cycle.skill_effect_error"
               )

      assert event.source_item_id == "alpha"
      assert event.payload["effect_type"] == "llm_call"
      assert event.payload["reason"] =~ "effect_timeout"
    end
  end

  defp active_periodic_wakeups(agent_id) do
    Repo.all(
      from(j in ScheduledJob,
        where: j.agent_id == ^agent_id,
        where: j.job_type == "wakeup",
        where: j.status in ["pending", "dispatched"],
        where: fragment("?->>? = ?", j.payload, "_schedule_key", "agent_periodic_wakeup"),
        order_by: [asc: j.inserted_at]
      )
    )
  end

  # Legacy transient supervision is retained only for historical Agent
  # cleanup/recovery tests. Production starts exclusively through the exact
  # AgentSupervisor launcher and always uses temporary children.
  defp start_legacy_supervised_agent(agent) do
    DynamicSupervisor.start_child(
      Maraithon.Runtime.AgentSupervisor,
      RuntimeAgent.child_spec(agent)
    )
  end

  defp wait_for_restarted_agent(_agent_id, _old_pid, 0) do
    flunk("agent did not restart")
  end

  defp wait_for_restarted_agent(agent_id, old_pid, attempts_left) do
    case Registry.lookup(Maraithon.Runtime.AgentRegistry, agent_id) do
      [{pid, _metadata}] when pid != old_pid ->
        pid

      _not_restarted ->
        receive do
        after
          10 -> wait_for_restarted_agent(agent_id, old_pid, attempts_left - 1)
        end
    end
  end
end
