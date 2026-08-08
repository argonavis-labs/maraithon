# ==============================================================================
# Effect Runner Integration Tests
# ==============================================================================
#
# This test module provides comprehensive integration testing for the EffectRunner
# GenServer, which is responsible for executing side effects (LLM calls, tool calls)
# on behalf of agent processes.
#
# ## Architecture Overview
#
# The EffectRunner implements an "outbox pattern" for reliable effect execution:
#
#   ┌─────────────┐     ┌─────────────────┐     ┌─────────────────┐
#   │   Agent     │────►│  Effects Table  │────►│  EffectRunner   │
#   │  (request)  │     │    (outbox)     │     │   (executor)    │
#   └─────────────┘     └─────────────────┘     └─────────────────┘
#                                                       │
#                                                       ▼
#                                               ┌─────────────────┐
#                                               │  LLM/Tool APIs  │
#                                               └─────────────────┘
#
# ## Key Responsibilities Tested
#
# 1. **Polling**: Periodically fetches pending effects from the database
# 2. **Claiming**: Atomically claims effects to prevent duplicate execution
# 3. **Execution**: Runs LLM calls and tool calls asynchronously
# 4. **Retry Logic**: Implements exponential backoff for failed effects
# 5. **Stale Recovery**: Reclaims effects stuck in "claimed" state too long
# 6. **Result Delivery**: Notifies agent processes of effect completion
#
# ## Test Categories
#
# - **Unit Tests**: Test individual GenServer callbacks in isolation
# - **Integration Tests**: Test the full effect lifecycle with real database
#
# ## Dependencies
#
# - Requires PostgreSQL database (via Ecto Sandbox)
# - Uses MockProvider for LLM calls to avoid real API calls
# - Requires Task.Supervisor for async effect execution
#
# ==============================================================================

defmodule Maraithon.Runtime.EffectRunnerTest do
  use Maraithon.DataCase, async: false

  # ---------------------------------------------------------------------------
  # Why async: false?
  # ---------------------------------------------------------------------------
  # The EffectRunner is a singleton GenServer that polls the database for
  # pending effects. Running tests in parallel would cause race conditions
  # where multiple test instances compete for the same effects.
  # ---------------------------------------------------------------------------

  alias Maraithon.Runtime.EffectRunner
  alias Maraithon.Runtime.Effects.LLMRateLimiter
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Agents
  alias Maraithon.Effects
  alias Maraithon.Effects.Effect

  defmodule RateLimitedProvider do
    @moduledoc false

    def complete(_params), do: {:error, {:rate_limited, 60_000}}
  end

  defmodule SideEffectThenRaiseProvider do
    @moduledoc false

    def complete(_params) do
      test_pid = Application.fetch_env!(:maraithon, :effect_runner_test_pid)
      send(test_pid, {:side_effect_then_raise_called, self()})
      raise "raised after provider side effect"
    end
  end

  defmodule InsufficientQuotaProvider do
    @moduledoc false

    def complete(params) do
      test_pid = Application.fetch_env!(:maraithon, :effect_runner_test_pid)
      send(test_pid, {:insufficient_quota_provider_called, self(), params})

      {:error, {:insufficient_quota, "OpenAI quota exceeded"}}
    end
  end

  defmodule OversizedResultProvider do
    @moduledoc false

    def complete(_params) do
      {:ok,
       %{
         content: String.duplicate("x", 256_001),
         model: "oversized-result-v1",
         tokens_in: 1,
         tokens_out: 1,
         finish_reason: "stop",
         usage: %{
           input_tokens: 1,
           output_tokens: 1,
           total_tokens: 2,
           total_cost: 0.0
         }
       }}
    end
  end

  defmodule ConfiguredErrorProvider do
    @moduledoc false

    def complete(_params) do
      test_pid = Application.fetch_env!(:maraithon, :effect_runner_test_pid)
      reason = Application.fetch_env!(:maraithon, :effect_runner_provider_error)
      send(test_pid, {:configured_error_provider_called, self(), reason})
      {:error, reason}
    end
  end

  defmodule CountingSuccessProvider do
    @moduledoc false

    def complete(_params) do
      counter = Application.fetch_env!(:maraithon, :effect_runner_command_counter)
      :counters.add(counter, 1, 1)

      {:ok,
       %{
         content: "ok",
         model: "counting-success-v1",
         tokens_in: 1,
         tokens_out: 1,
         finish_reason: "stop",
         usage: %{}
       }}
    end
  end

  defmodule BlockingProvider do
    @moduledoc false

    def complete(params) do
      test_pid = Application.fetch_env!(:maraithon, :effect_runner_test_pid)
      send(test_pid, {:blocking_provider_called, self(), params})

      receive do
        :release_blocking_provider ->
          {:ok,
           %{
             content: "ok",
             model: "blocking-v1",
             tokens_in: 1,
             tokens_out: 1,
             finish_reason: "stop",
             usage: %{}
           }}
      after
        5_000 -> {:error, :timeout}
      end
    end
  end

  # ===========================================================================
  # Test Setup
  # ===========================================================================
  #
  # Each test requires an agent record because effects are associated with
  # agents via foreign key. We create a minimal agent with "running" status.
  # ===========================================================================

  setup do
    LLMRateLimiter.reset()

    on_exit(fn -> LLMRateLimiter.reset() end)

    # Create a test agent that effects will be associated with.
    # The agent doesn't need to be actually running - we just need a valid
    # agent_id for the foreign key constraint on the effects table.
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "watchdog_summarizer",
        config: %{},
        status: "running",
        started_at: DateTime.utc_now()
      })

    %{agent: agent}
  end

  # ===========================================================================
  # Unit Tests: GenServer Lifecycle
  # ===========================================================================
  #
  # These tests verify that the EffectRunner GenServer starts correctly and
  # handles its basic callbacks without crashing. They don't test the full
  # effect execution pipeline - that's covered in integration tests below.
  # ===========================================================================

  describe "start_link/1" do
    @doc """
    Tests that the EffectRunner GenServer starts successfully.

    The EffectRunner is a named GenServer (__MODULE__), so only one instance
    can run at a time. We stop any existing instance before starting fresh.
    """
    test "starts the effect runner" do
      # Clean up any existing instance from previous tests or application startup
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Start a fresh instance and verify it's alive
      assert {:ok, pid} = EffectRunner.start_link([])
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Clean up to avoid interfering with other tests
      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_info :poll" do
    @doc """
    Tests that the EffectRunner handles the :poll message correctly.

    The :poll message is sent periodically (default: every 1 second) to trigger
    the effect processing loop. This test verifies:
    1. The GenServer doesn't crash when processing a poll
    2. Database queries work correctly (via sandbox)
    """
    test "handles poll message" do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = EffectRunner.start_link([])

      # Allow the GenServer process to access our test's database connection.
      # This is required because we're using Ecto's sandbox mode.
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Manually trigger a poll cycle
      send(pid, :poll)
      Process.sleep(100)

      # The GenServer should remain alive after processing
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    @doc """
    Tests that poll correctly queries for pending effects.

    Even with no pending effects, the poll should:
    1. Query the effects table without errors
    2. Handle the empty result set gracefully
    3. Schedule the next poll
    """
    test "fetches pending effects during poll" do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Note: We can't easily test full effect execution because it requires
      # the Task.Supervisor to be properly initialized which happens in the
      # application startup. We test that the GenServer handles the poll
      # message without crashing (when there are no pending effects).

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Send poll message (with no pending effects in the database)
      send(pid, :poll)
      Process.sleep(100)

      # Should remain alive - no crash from empty result set
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_info {:effect_done, effect_id, result}" do
    @doc """
    Tests that completed effect results are handled correctly.

    When a Task completes executing an effect, it sends {:effect_done, effect_id, result}
    back to the EffectRunner. This test verifies the message is processed without
    crashing (the actual effect tracking is tested in integration tests).
    """
    test "removes effect from running state" do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = EffectRunner.start_link([])

      # Simulate an effect completion message
      effect_id = Ecto.UUID.generate()
      send(pid, {:effect_done, effect_id, {:ok, %{result: "test"}}})
      Process.sleep(50)

      # GenServer should handle the message gracefully
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  describe "handle_call :clear_running" do
    @doc """
    Tests the :clear_running call for debugging/testing purposes.

    This call clears the internal map of running effects, useful for:
    1. Testing scenarios where you need a clean slate
    2. Debugging stuck effects
    """
    test "clears the running state" do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, pid} = EffectRunner.start_link([])

      # The :clear_running call should succeed
      :ok = GenServer.call(pid, :clear_running)

      # GenServer should remain operational
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ===========================================================================
  # Integration Tests: Full Effect Lifecycle
  # ===========================================================================
  #
  # These tests exercise the complete effect execution pipeline:
  #
  #   1. Effect created in database (pending status)
  #   2. EffectRunner polls and claims the effect
  #   3. Effect is executed asynchronously (LLM call or tool call)
  #   4. Result is written back to database
  #   5. Agent is notified (if running)
  #
  # ## Test Environment Setup
  #
  # - Task.Supervisor must be started for async execution
  # - MockProvider is configured to avoid real LLM API calls
  # - Database sandbox allows effect records to be created/updated
  #
  # ===========================================================================

  describe "integration: effect execution" do
    setup do
      # -----------------------------------------------------------------------
      # Ensure the Task.Supervisor for effects is running
      # -----------------------------------------------------------------------
      # Effects are executed asynchronously in supervised tasks. In production,
      # this is started by the application supervisor. In tests, we start it
      # manually if not already running.
      # -----------------------------------------------------------------------
      case Process.whereis(Maraithon.Runtime.EffectSupervisor) do
        nil ->
          Task.Supervisor.start_link(name: Maraithon.Runtime.EffectSupervisor)

        _ ->
          :ok
      end

      # -----------------------------------------------------------------------
      # Configure the MockProvider for LLM calls
      # -----------------------------------------------------------------------
      # We don't want to make real API calls to Anthropic during tests.
      # The MockProvider returns realistic responses without network calls.
      # -----------------------------------------------------------------------
      original_config = Application.get_env(:maraithon, Maraithon.Runtime)

      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLM.MockProvider,
        anthropic_api_key: "test_key"
      )

      # Restore original config after test completes
      on_exit(fn ->
        if original_config do
          Application.put_env(:maraithon, Maraithon.Runtime, original_config)
        end
      end)

      :ok
    end

    test "requires the current Agent continuation before a linked command executes", %{
      agent: agent
    } do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      counter = :counters.new(1, [])
      Application.put_env(:maraithon, :effect_runner_command_counter, counter)

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, CountingSuccessProvider)
      )

      on_exit(fn ->
        Application.delete_env(:maraithon, :effect_runner_command_counter)
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
      end)

      {:ok, run} = Agents.start_runtime_agent_run(agent, %{trigger_type: "message"})

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
          %{"messages" => [%{"role" => "user", "content" => "Do not execute"}]},
          %{agent_run_id: run.id, agent_run_step_id: step.id}
        )

      :ok = Dispatch.subscribe(agent.id)
      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      assert_receive {:agent_dispatch,
                      {:effect_result, ^effect_id, {:error, :stale_effect_context}}},
                     1_000

      assert :counters.get(counter, 1) == 0
      assert Repo.get!(Effect, effect_id).status == "failed"
    end

    # -------------------------------------------------------------------------
    # Test: LLM Call Execution
    # -------------------------------------------------------------------------
    # This is the primary use case - agents request LLM completions which are
    # executed asynchronously by the EffectRunner.
    #
    # Flow:
    #   Agent → Effects.request("llm_call", params) → EffectRunner → MockProvider
    # -------------------------------------------------------------------------

    @doc """
    Tests successful execution of an LLM call effect.

    This tests the happy path where:
    1. An llm_call effect is created with valid parameters
    2. EffectRunner polls and picks it up
    3. MockProvider returns a successful response
    4. Effect status transitions: pending → claimed → completed
    """
    test "executes llm_call effect successfully", %{agent: agent} do
      # Stop any existing runner to ensure clean state
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create a pending LLM effect in the database
      # This simulates what an agent would do when it needs an LLM completion
      {:ok, effect_id} =
        Maraithon.Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 100
        })

      # Start the EffectRunner
      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Trigger the poll cycle to process pending effects
      send(pid, :poll)

      # Wait for async execution to complete
      # In production, this happens within milliseconds, but tests need time
      Process.sleep(200)

      # Verify the effect was processed
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      # Status should be "claimed" (still processing) or "completed" (finished)
      assert updated_effect.status in ["claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Tool Call Execution
    # -------------------------------------------------------------------------
    # Agents can also execute tools (file operations, HTTP requests, etc.)
    # through the EffectRunner.
    # -------------------------------------------------------------------------

    @doc """
    Tests successful execution of a tool call effect.

    The "time" tool is a simple tool that returns the current time.
    It's used here because it has no side effects and always succeeds.
    """
    test "executes tool_call effect successfully", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create a tool call effect for the "time" tool
      {:ok, effect_id} =
        Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      Repo.update_all(
        from(effect in Maraithon.Effects.Effect, where: effect.id == ^effect_id),
        set: [
          error: "transient_failure",
          retry_after: DateTime.add(database_now(), -1, :second)
        ]
      )

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(200)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status == "completed"
      assert updated_effect.error == nil
      assert updated_effect.retry_after == nil

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Unknown Effect Type Handling
    # -------------------------------------------------------------------------
    # Tests error handling when an effect has an unrecognized type.
    # This should fail gracefully and trigger retry logic.
    # -------------------------------------------------------------------------

    @doc """
    Tests that unknown effect types are handled gracefully.

    When the EffectRunner encounters an effect type it doesn't recognize,
    it should:
    1. Return an error result
    2. Trigger retry logic (if attempts remain)
    3. Eventually mark as failed (if max attempts reached)
    """
    test "handles unknown effect type", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create an effect with an invalid type
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "unknown_type", nil, %{})

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(200)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      assert updated_effect.status == "failed"
      assert updated_effect.attempts == 1
      assert updated_effect.retry_after == nil

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Effect Claiming (Concurrency Safety)
    # -------------------------------------------------------------------------
    # Multiple effects should be claimed atomically to prevent duplicate
    # execution in a distributed environment.
    # -------------------------------------------------------------------------

    @doc """
    Tests that multiple pending effects are claimed correctly.

    The claiming mechanism uses atomic database updates to ensure:
    1. Each effect is claimed by exactly one runner
    2. No effects are skipped
    3. No effects are executed twice
    """
    test "claims effects correctly", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create multiple pending effects
      {:ok, effect_id1} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})
      {:ok, effect_id2} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(200)

      # Both effects should have been processed
      e1 = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id1)
      e2 = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id2)

      assert e1.status in ["claimed", "completed"]
      assert e2.status in ["claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Stale Effect Recovery
    # -------------------------------------------------------------------------
    # Effects can become "stuck" in claimed status if the runner crashes.
    # The EffectRunner periodically reclaims stale effects.
    # -------------------------------------------------------------------------

    @doc """
    Tests conservative fencing of effects whose command outcome is unknown.

    Elapsed time is not worker-death proof, so a stale claim remains
    non-dispatchable until its exact worker generation is terminated.
    """
    test "fences stale claimed effects without publishing a result", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      :ok = Dispatch.subscribe(agent.id)
      {:ok, effect_id} = Effects.request(agent.id, "tool_call", "time", %{})
      old_time = DateTime.add(database_now(), -1_600_000, :millisecond)

      Maraithon.Repo.update_all(
        from(effect in Effect, where: effect.id == ^effect_id),
        set: [status: "claimed", claimed_at: old_time, claimed_by: "old_node"]
      )

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)

      _ = :sys.get_state(pid)
      refute_receive {:agent_dispatch, {:effect_result, ^effect_id, _result}}, 25

      effect = Maraithon.Repo.get!(Effect, effect_id)
      assert effect.status == "cancelling"
      assert effect.error == nil
      assert effect.result == nil
      assert effect.claimed_by == "old_node"
      assert effect.claimed_at == old_time
      assert effect.attempts == 0

      send(pid, :poll)
      _ = :sys.get_state(pid)
      assert Maraithon.Repo.get!(Effect, effect_id).status == "cancelling"

      GenServer.stop(pid, :normal)
    end

    test "fences malformed claimed effects without publishing a result", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      :ok = Dispatch.subscribe(agent.id)
      {:ok, effect_id} = Effects.request(agent.id, "tool_call", "time", %{})

      Repo.update_all(
        from(effect in Effect, where: effect.id == ^effect_id),
        set: [status: "claimed", claimed_at: nil, claimed_by: nil]
      )

      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      _ = :sys.get_state(pid)
      refute_receive {:agent_dispatch, {:effect_result, ^effect_id, _result}}, 25
      effect = Repo.get!(Effect, effect_id)
      assert effect.status == "cancelling"
      assert effect.error == nil
      assert effect.claimed_by == nil
      assert effect.claimed_at == nil
      assert effect.attempts == 0
    end

    # -------------------------------------------------------------------------
    # Test: Retry Scheduling (Future retry_after)
    # -------------------------------------------------------------------------
    # Effects waiting for retry should NOT be processed until retry_after time
    # -------------------------------------------------------------------------

    @doc """
    Tests that effects with future retry_after are not processed.

    After a failed attempt, effects are scheduled for retry using exponential
    backoff. The retry_after timestamp indicates when the effect should be
    retried. Effects with retry_after in the future should be skipped.
    """
    test "processes effects with retry_after in the future", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      # Set retry_after to 1 minute in the future
      future_time = DateTime.add(database_now(), 60_000, :millisecond)

      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [retry_after: future_time]
      )

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(100)

      # Effect should still be pending (not yet time to retry)
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status == "pending"

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Retry Scheduling (Past retry_after)
    # -------------------------------------------------------------------------
    # Effects with retry_after in the past SHOULD be processed
    # -------------------------------------------------------------------------

    @doc """
    Tests that effects with past retry_after ARE processed.

    Once the retry_after time has passed, the effect should be picked up
    on the next poll cycle and re-executed.
    """
    test "processes effects with retry_after in the past", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "tool_call", "time", %{})

      # Set retry_after to 1 second in the past
      past_time = DateTime.add(database_now(), -1000, :millisecond)

      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [retry_after: past_time]
      )

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      # Effect with past retry_after should be processed
      send(pid, :poll)
      Process.sleep(200)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status in ["claimed", "completed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Max Attempts Exhaustion
    # -------------------------------------------------------------------------
    # Effects that fail repeatedly should eventually be marked as "failed"
    # -------------------------------------------------------------------------

    @doc """
    Tests that effects are marked failed after exhausting max_attempts.

    The retry logic uses exponential backoff, but has a maximum number of
    attempts. Once max_attempts is reached:

    1. Effect is marked as "failed"
    2. Agent is notified of the failure
    3. No more retries are scheduled
    """
    test "marks effect as failed after max_attempts", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      # Create an effect that will always fail (unknown type)
      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "unknown_type", nil, %{})

      # Set attempts to max - 1, so the next failure is final
      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [attempts: 2, max_attempts: 3]
      )

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(300)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      # Should be marked as failed (or still being processed)
      assert updated_effect.status in ["failed", "claimed"]

      GenServer.stop(pid, :normal)
    end

    # -------------------------------------------------------------------------
    # Test: Retry Logic (Before Max Attempts)
    # -------------------------------------------------------------------------
    # Failed effects should be scheduled for retry with exponential backoff
    # -------------------------------------------------------------------------

    @doc """
    Tests that failed effects are retried when attempts < max_attempts.

    On failure, the EffectRunner should:
    1. Increment the attempts counter
    2. Calculate backoff delay: base * 2^attempt + jitter
    3. Set retry_after timestamp
    4. Reset status to "pending"
    """
    test "fails an unknown effect type after one deterministic attempt", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, effect_id} = Maraithon.Effects.request(agent.id, "unknown_type", nil, %{})

      # Ensure we have retries remaining
      Maraithon.Repo.update_all(
        from(e in Maraithon.Effects.Effect, where: e.id == ^effect_id),
        set: [attempts: 0, max_attempts: 3]
      )

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(300)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      assert updated_effect.status == "failed"
      assert updated_effect.attempts == 1
      assert updated_effect.retry_after == nil

      GenServer.stop(pid, :normal)
    end

    test "retries rate-limited llm effects with provider backoff and consumes attempts", %{
      agent: agent
    } do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, RateLimitedProvider)
      )

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
      end)

      {:ok, effect_id} =
        Maraithon.Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 100
        })

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      Process.sleep(300)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      assert updated_effect.status == "pending"
      assert updated_effect.attempts == 1
      assert updated_effect.retry_after != nil
      assert DateTime.diff(updated_effect.retry_after, DateTime.utc_now(), :second) >= 50

      GenServer.stop(pid, :normal)
    end

    test "fails insufficient quota llm effects without scheduling retries", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, InsufficientQuotaProvider)
      )

      Application.put_env(:maraithon, :effect_runner_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_test_pid)
      end)

      {:ok, effect_id} =
        Maraithon.Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 100
        })

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      assert_receive {:insufficient_quota_provider_called, provider_pid, _params}, 1_000

      ref = Process.monitor(provider_pid)
      assert_receive {:DOWN, ^ref, :process, ^provider_pid, :normal}, 1_000

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      assert updated_effect.status == "failed"
      assert updated_effect.attempts == 1
      assert updated_effect.retry_after == nil
      assert updated_effect.error =~ "insufficient_quota"

      GenServer.stop(pid, :normal)
    end

    test "does not repeat a provider call that raises after crossing its side-effect boundary", %{
      agent: agent
    } do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, SideEffectThenRaiseProvider)
      )

      Application.put_env(:maraithon, :effect_runner_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_test_pid)
      end)

      :ok = Dispatch.subscribe(agent.id)
      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      {:ok, effect_id} =
        Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Execute once"}],
          "max_tokens" => 100
        })

      send(pid, :poll)
      assert_receive {:side_effect_then_raise_called, provider_pid}, 1_000

      assert_receive {:agent_dispatch,
                      {:effect_result, ^effect_id, {:error, :effect_outcome_ambiguous}}},
                     1_000

      provider_ref = Process.monitor(provider_pid)
      assert_receive {:DOWN, ^provider_ref, :process, ^provider_pid, _reason}, 1_000
      _ = :sys.get_state(pid)

      send(pid, :poll)
      _ = :sys.get_state(pid)
      refute_received {:side_effect_then_raise_called, _other_pid}

      effect = Maraithon.Repo.get!(Effect, effect_id)
      assert effect.status == "failed"
      assert effect.attempts == 1
      assert effect.error == "effect_outcome_ambiguous"
    end

    test "does not retry deterministic provider terminal failures", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, ConfiguredErrorProvider)
      )

      Application.put_env(:maraithon, :effect_runner_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_test_pid)
        Application.delete_env(:maraithon, :effect_runner_provider_error)
      end)

      :ok = Dispatch.subscribe(agent.id)
      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      for reason <- [
            {:incomplete_response, %{reason: "provider_incomplete"}},
            {:provider_refusal, :redacted},
            {:content_filtered, :redacted},
            {:invalid_response, %{reason: "closed_validation"}},
            :invalid_json_response,
            {:api_error, 400, :redacted}
          ] do
        Application.put_env(:maraithon, :effect_runner_provider_error, reason)

        {:ok, effect_id} =
          Effects.request(agent.id, "llm_call", nil, %{
            "messages" => [%{"role" => "user", "content" => "Fail once"}],
            "max_tokens" => 100
          })

        send(pid, :poll)
        assert_receive {:configured_error_provider_called, provider_pid, ^reason}, 1_000
        assert_receive {:agent_dispatch, {:effect_result, ^effect_id, {:error, ^reason}}}, 1_000

        provider_ref = Process.monitor(provider_pid)
        assert_receive {:DOWN, ^provider_ref, :process, ^provider_pid, _task_reason}, 1_000
        _ = :sys.get_state(pid)

        effect = Maraithon.Repo.get!(Effect, effect_id)
        assert effect.status == "failed"
        assert effect.attempts == 1
        assert effect.retry_after == nil
        assert effect.claimed_by == nil
        assert effect.claimed_at == nil

        send(pid, :poll)
        _ = :sys.get_state(pid)
        refute_receive {:configured_error_provider_called, _provider_pid, ^reason}, 50
      end

      for retryable_reason <- [
            {:api_error, 429, :redacted},
            {:api_error, 501, :redacted}
          ] do
        Application.put_env(:maraithon, :effect_runner_provider_error, retryable_reason)

        {:ok, retryable_effect_id} =
          Effects.request(agent.id, "llm_call", nil, %{
            "messages" => [%{"role" => "user", "content" => "Retry later"}],
            "max_tokens" => 100
          })

        send(pid, :poll)

        assert_receive {:configured_error_provider_called, retryable_provider_pid,
                        ^retryable_reason},
                       1_000

        retryable_provider_ref = Process.monitor(retryable_provider_pid)

        assert_receive {:DOWN, ^retryable_provider_ref, :process, ^retryable_provider_pid,
                        _reason},
                       1_000

        _ = :sys.get_state(pid)

        retryable_effect = Maraithon.Repo.get!(Effect, retryable_effect_id)
        assert retryable_effect.status == "pending"
        assert retryable_effect.attempts == 1
        assert retryable_effect.retry_after != nil
        refute_received {:agent_dispatch, {:effect_result, ^retryable_effect_id, _result}}
      end
    end

    test "fails deterministic invalid llm requests after one attempt", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      :ok = Dispatch.subscribe(agent.id)

      {:ok, effect_id} =
        Maraithon.Effects.request(agent.id, "llm_call", nil, %{
          "messages" =>
            for(index <- 1..65, do: %{"role" => "user", "content" => "message #{index}"}),
          "max_tokens" => 100
        })

      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)

      assert_receive {:agent_dispatch,
                      {:effect_result, ^effect_id, {:error, {:invalid_request, _summary}}}},
                     1_000

      _ = :sys.get_state(pid)
      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)
      assert updated_effect.status == "failed"
      assert updated_effect.attempts == 1
      assert updated_effect.retry_after == nil
      assert updated_effect.error == "invalid_request"
    end

    test "fails oversized successful results without retrying the effect", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, OversizedResultProvider)
      )

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
      end)

      :ok = Dispatch.subscribe(agent.id)

      {:ok, effect_id} =
        Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 100
        })

      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      assert_receive {:agent_dispatch,
                      {:effect_result, ^effect_id, {:error, :invalid_effect_result}}},
                     1_000

      _ = :sys.get_state(pid)
      updated_effect = Repo.get!(Effect, effect_id)
      assert updated_effect.status == "failed"
      assert updated_effect.attempts == 1
      assert updated_effect.retry_after == nil
      assert updated_effect.result == nil
      assert updated_effect.error == "invalid_effect_result"
    end

    test "does not claim llm effects while provider cooldown is active", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      {:ok, effect_id} =
        Maraithon.Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 100
        })

      LLMRateLimiter.record_rate_limit(60_000)

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      _ = :sys.get_state(pid)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      assert updated_effect.status == "pending"
      assert updated_effect.attempts == 0
      assert updated_effect.claimed_by == nil
      assert updated_effect.claimed_at == nil
      assert updated_effect.retry_after == nil

      GenServer.stop(pid, :normal)
    end

    test "does not claim beyond one LLM lane's configured capacity", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      reasoning_limit =
        LLMRateLimiter.status()
        |> get_in([:buckets, :reasoning, :max_concurrency])

      assert is_integer(reasoning_limit) and reasoning_limit > 0

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      test_runtime_config =
        original_runtime_config
        |> Keyword.put(:llm_provider, BlockingProvider)
        |> Keyword.put(:llm_model, "reasoning-test-model")
        |> Keyword.put(:llm_chat_model, "chat-test-model")
        |> Keyword.put(:llm_routing_model, "chat-test-model")
        |> Keyword.put(:effect_batch_size, reasoning_limit + 1)
        |> Keyword.put(:effect_poll_interval_ms, 60_000)

      Application.put_env(:maraithon, Maraithon.Runtime, test_runtime_config)
      Application.put_env(:maraithon, :effect_runner_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_test_pid)
      end)

      effect_ids =
        Enum.map(1..(reasoning_limit + 1), fn index ->
          {:ok, effect_id} =
            Effects.request(agent.id, "llm_call", nil, %{
              "messages" => [%{"role" => "user", "content" => "Reasoning #{index}"}],
              "model" => "reasoning-test-model",
              "max_tokens" => 100
            })

          effect_id
        end)

      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      provider_pids =
        Enum.map(1..reasoning_limit, fn _index ->
          assert_receive {:blocking_provider_called, provider_pid, _params}, 1_000
          provider_pid
        end)

      _ = :sys.get_state(pid)
      {claimed_ids, [waiting_id]} = Enum.split(effect_ids, reasoning_limit)
      assert Enum.all?(claimed_ids, &(Repo.get!(Effect, &1).status == "claimed"))

      waiting_effect = Repo.get!(Effect, waiting_id)
      assert waiting_effect.status == "pending"
      assert waiting_effect.attempts == 0
      assert waiting_effect.claimed_by == nil
      assert waiting_effect.claimed_at == nil

      monitored = Enum.map(provider_pids, &{&1, Process.monitor(&1)})
      Enum.each(provider_pids, &send(&1, :release_blocking_provider))

      Enum.each(monitored, fn {provider_pid, ref} ->
        assert_receive {:DOWN, ^ref, :process, ^provider_pid, :normal}, 1_000
      end)

      _ = :sys.get_state(pid)
    end

    test "rotates constrained LLM admission so busy chat cannot starve reasoning", %{
      agent: agent
    } do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      test_runtime_config =
        original_runtime_config
        |> Keyword.put(:llm_provider, BlockingProvider)
        |> Keyword.put(:llm_model, "reasoning-test-model")
        |> Keyword.put(:llm_chat_model, "chat-test-model")
        |> Keyword.put(:llm_routing_model, "chat-test-model")
        |> Keyword.put(:effect_batch_size, 1)
        |> Keyword.put(:effect_poll_interval_ms, 60_000)

      Application.put_env(:maraithon, Maraithon.Runtime, test_runtime_config)
      Application.put_env(:maraithon, :effect_runner_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_test_pid)
      end)

      for content <- ["Chat one", "Chat two"] do
        assert {:ok, _effect_id} =
                 Effects.request(agent.id, "llm_call", nil, %{
                   "messages" => [%{"role" => "user", "content" => content}],
                   "model" => "chat-test-model",
                   "max_tokens" => 100
                 })
      end

      assert {:ok, reasoning_effect_id} =
               Effects.request(agent.id, "llm_call", nil, %{
                 "messages" => [%{"role" => "user", "content" => "Reason now"}],
                 "model" => "reasoning-test-model",
                 "max_tokens" => 100
               })

      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      assert_receive {:blocking_provider_called, chat_pid,
                      %{"messages" => [%{"content" => "Chat one"}]}},
                     1_000

      chat_ref = Process.monitor(chat_pid)
      send(chat_pid, :release_blocking_provider)
      assert_receive {:DOWN, ^chat_ref, :process, ^chat_pid, :normal}, 1_000
      _ = :sys.get_state(pid)

      send(pid, :poll)

      assert_receive {:blocking_provider_called, reasoning_pid,
                      %{"messages" => [%{"content" => "Reason now"}]}},
                     1_000

      assert Repo.get!(Effect, reasoning_effect_id).status == "claimed"
      reasoning_ref = Process.monitor(reasoning_pid)
      send(reasoning_pid, :release_blocking_provider)
      assert_receive {:DOWN, ^reasoning_ref, :process, ^reasoning_pid, :normal}, 1_000
      _ = :sys.get_state(pid)
    end

    test "advances the legacy LLM window so chat beyond 200 rows is admitted", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      test_runtime_config =
        original_runtime_config
        |> Keyword.put(:llm_provider, BlockingProvider)
        |> Keyword.put(:llm_model, "reasoning-test-model")
        |> Keyword.put(:llm_chat_model, "chat-test-model")
        |> Keyword.put(:llm_routing_model, "chat-test-model")
        |> Keyword.put(:effect_batch_size, 1)
        |> Keyword.put(:effect_poll_interval_ms, 60_000)

      Application.put_env(:maraithon, Maraithon.Runtime, test_runtime_config)
      Application.put_env(:maraithon, :effect_runner_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_test_pid)
      end)

      inserted_at = DateTime.utc_now()

      reasoning_rows =
        Enum.map(0..199, fn offset ->
          timestamp = DateTime.add(inserted_at, offset, :microsecond)

          %{
            id: Ecto.UUID.generate(),
            agent_id: agent.id,
            idempotency_key: Ecto.UUID.generate(),
            effect_type: "llm_call",
            params: %{
              "__maraithon_effect_protocol" => 2,
              "messages" => [%{"role" => "user", "content" => "Legacy reasoning"}],
              "model" => "reasoning-test-model",
              "max_tokens" => 100
            },
            status: "pending",
            inserted_at: timestamp,
            updated_at: timestamp
          }
        end)

      {200, _rows} = Repo.insert_all(Effect, reasoning_rows)
      target_timestamp = DateTime.add(inserted_at, 200, :microsecond)
      target_id = Ecto.UUID.generate()

      {1, _rows} =
        Repo.insert_all(Effect, [
          %{
            id: target_id,
            agent_id: agent.id,
            idempotency_key: Ecto.UUID.generate(),
            effect_type: "llm_call",
            params: %{
              "__maraithon_effect_protocol" => 2,
              "messages" => [%{"role" => "user", "content" => "Legacy chat target"}],
              "model" => "chat-test-model",
              "max_tokens" => 100
            },
            status: "pending",
            inserted_at: target_timestamp,
            updated_at: target_timestamp
          }
        ])

      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      assert_receive {:blocking_provider_called, reasoning_pid, _params}, 1_000
      reasoning_ref = Process.monitor(reasoning_pid)
      send(reasoning_pid, :release_blocking_provider)
      assert_receive {:DOWN, ^reasoning_ref, :process, ^reasoning_pid, :normal}, 1_000
      _ = :sys.get_state(pid)

      send(pid, :poll)

      assert_receive {:blocking_provider_called, chat_pid,
                      %{"messages" => [%{"content" => "Legacy chat target"}]}},
                     1_000

      assert Repo.get!(Effect, target_id).status == "claimed"
      chat_ref = Process.monitor(chat_pid)
      send(chat_pid, :release_blocking_provider)
      assert_receive {:DOWN, ^chat_ref, :process, ^chat_pid, :normal}, 1_000
      _ = :sys.get_state(pid)
    end

    test "does not let a late worker overwrite or notify after cancellation", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, BlockingProvider)
      )

      Application.put_env(:maraithon, :effect_runner_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_test_pid)
      end)

      :ok = Dispatch.subscribe(agent.id)

      {:ok, effect_id} =
        Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Block"}],
          "max_tokens" => 100
        })

      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      assert_receive {:blocking_provider_called, worker_pid, _params}, 1_000

      claimed = Maraithon.Repo.get!(Effect, effect_id)
      assert claimed.status == "claimed"
      assert is_binary(claimed.claimed_by)
      assert %DateTime{} = claimed.claimed_at

      assert {:ok, 1} =
               Effects.cancel_active_for_agent(
                 agent.id,
                 "agent_recovered_without_effect_continuation"
               )

      cancelled = Maraithon.Repo.get!(Effect, effect_id)
      assert cancelled.status == "failed"
      assert cancelled.error == "effect_outcome_ambiguous"

      ref = Process.monitor(worker_pid)
      send(worker_pid, :release_blocking_provider)
      assert_receive {:DOWN, ^ref, :process, ^worker_pid, :normal}, 1_000
      _ = :sys.get_state(pid)

      after_worker = Maraithon.Repo.get!(Effect, effect_id)
      assert after_worker.status == "failed"
      assert after_worker.error == "effect_outcome_ambiguous"
      assert after_worker.updated_at == cancelled.updated_at
      assert after_worker.claimed_by == nil
      assert after_worker.claimed_at == nil
      assert after_worker.result == nil
      assert after_worker.attempts == 0

      refute_received {:agent_dispatch, {:effect_result, ^effect_id, _result}}
    end

    test "cancellation fences the claim and terminates the supervised command task", %{
      agent: agent
    } do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, BlockingProvider)
      )

      Application.put_env(:maraithon, :effect_runner_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_test_pid)
      end)

      :ok = Dispatch.subscribe(agent.id)

      {:ok, effect_id} =
        Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Cancel"}],
          "max_tokens" => 100
        })

      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      assert_receive {:blocking_provider_called, worker_pid, _params}, 1_000
      ref = Process.monitor(worker_pid)

      assert {:ok, 1} =
               EffectRunner.cancel_active_for_agent(
                 agent.id,
                 "agent_stopped_without_effect_continuation"
               )

      assert_receive {:DOWN, ^ref, :process, ^worker_pid, _reason}, 1_000
      _ = :sys.get_state(pid)

      effect = Maraithon.Repo.get!(Effect, effect_id)
      assert effect.status == "failed"
      assert effect.error == "effect_outcome_ambiguous"
      assert effect.result == nil
      assert effect.retry_after == nil
      assert effect.claimed_by == nil
      assert effect.claimed_at == nil
      assert effect.attempts == 0
      refute_received {:agent_dispatch, {:effect_result, ^effect_id, _result}}
    end

    test "graceful runner shutdown stops workers before publishing ambiguous results", %{
      agent: agent
    } do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, BlockingProvider)
      )

      Application.put_env(:maraithon, :effect_runner_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_test_pid)
      end)

      {:ok, effect_id} =
        Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Shutdown"}],
          "max_tokens" => 100
        })

      {:ok, pid} = EffectRunner.start_link([])
      Process.unlink(pid)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      assert_receive {:blocking_provider_called, worker_pid, _params}, 1_000
      worker_ref = Process.monitor(worker_pid)
      GenServer.stop(pid, :normal, 15_000)

      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 1_000
      effect = Repo.get!(Effect, effect_id)
      assert effect.status == "failed"
      assert effect.error == "effect_outcome_ambiguous"
      assert effect.result_envelope["status"] == "error"
      assert effect.claimed_by == nil
      assert effect.claimed_at == nil
    end

    test "cancellation discovers an orphaned task after the runner restarts", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, BlockingProvider)
      )

      Application.put_env(:maraithon, :effect_runner_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_test_pid)

        case Process.whereis(EffectRunner) do
          nil -> :ok
          pid -> GenServer.stop(pid, :normal)
        end
      end)

      {:ok, effect_id} =
        Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Orphan then cancel"}],
          "max_tokens" => 100
        })

      {:ok, first_runner} = EffectRunner.start_link([])
      Process.unlink(first_runner)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), first_runner)
      send(first_runner, :poll)

      assert_receive {:blocking_provider_called, worker_pid, _params}, 1_000
      worker_ref = Process.monitor(worker_pid)
      claimed = Repo.get!(Effect, effect_id)
      registry_key = {effect_id, claimed.claimed_by, claimed.claimed_at}

      assert [{^worker_pid, %{agent_id: agent_id}}] =
               Registry.lookup(Maraithon.Runtime.EffectTaskRegistry, registry_key)

      assert agent_id == agent.id
      runner_ref = Process.monitor(first_runner)
      Process.exit(first_runner, :kill)
      assert_receive {:DOWN, ^runner_ref, :process, ^first_runner, :killed}, 1_000

      assert [{^worker_pid, _metadata}] =
               Registry.lookup(Maraithon.Runtime.EffectTaskRegistry, registry_key)

      {:ok, second_runner} = EffectRunner.start_link([])
      Process.unlink(second_runner)
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), second_runner)

      assert {:ok, 1} =
               EffectRunner.cancel_active_for_agent(
                 agent.id,
                 "agent_stopped_without_effect_continuation"
               )

      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 1_000
      assert Registry.lookup(Maraithon.Runtime.EffectTaskRegistry, registry_key) == []
      orphaned = Repo.get!(Effect, effect_id)
      assert orphaned.status == "failed"
      assert orphaned.error == "effect_outcome_ambiguous"
    end

    test "terminalizes a claim when command supervision is unavailable", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      :ok = Dispatch.subscribe(agent.id)
      task_starter = fn _effect, _writer, _sleeper -> {:error, :supervisor_unavailable} end
      {:ok, effect_id} = Effects.request(agent.id, "tool_call", "time", %{})

      pid = start_supervised!({EffectRunner, task_starter: task_starter})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      assert_receive {:agent_dispatch,
                      {:effect_result, ^effect_id, {:error, :effect_outcome_ambiguous}}},
                     1_000

      _ = :sys.get_state(pid)
      effect = Repo.get!(Effect, effect_id)
      assert effect.status == "failed"
      assert effect.error == "effect_outcome_ambiguous"
      assert effect.result == nil
      assert effect.attempts == 0
      assert effect.claimed_by == nil
      assert effect.claimed_at == nil
      assert effect.retry_after == nil
    end

    test "terminalizes a killed command task as an ambiguous outcome", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, BlockingProvider)
      )

      Application.put_env(:maraithon, :effect_runner_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_test_pid)
      end)

      :ok = Dispatch.subscribe(agent.id)

      {:ok, effect_id} =
        Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Block then crash"}],
          "max_tokens" => 100
        })

      pid = start_supervised!({EffectRunner, []})
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      assert_receive {:blocking_provider_called, worker_pid, _params}, 1_000

      ref = Process.monitor(worker_pid)
      Process.exit(worker_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker_pid, :killed}, 1_000

      assert_receive {:agent_dispatch,
                      {:effect_result, ^effect_id, {:error, :effect_outcome_ambiguous}}},
                     1_000

      _ = :sys.get_state(pid)
      effect = Maraithon.Repo.get!(Effect, effect_id)
      assert effect.status == "failed"
      assert effect.error == "effect_outcome_ambiguous"
      assert effect.result == nil
      assert effect.retry_after == nil
      assert effect.claimed_by == nil
      assert effect.claimed_at == nil
      assert effect.attempts == 0

      send(pid, :poll)
      _ = :sys.get_state(pid)
      refute_receive {:blocking_provider_called, _worker_pid, _params}, 100
    end

    test "recovers a committed completion whose database acknowledgement was lost", %{
      agent: agent
    } do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])
      command_calls = :counters.new(1, [])
      writes = :counters.new(1, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, CountingSuccessProvider)
      )

      Application.put_env(:maraithon, :effect_runner_command_counter, command_calls)

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_command_counter)
      end)

      :ok = Dispatch.subscribe(agent.id)

      completion_writer = fn effect, result ->
        :counters.add(writes, 1, 1)

        if :counters.get(writes, 1) == 1 do
          :ok = EffectRunner.persist_completed_once(effect, result)
          {:error, :completion_ack_lost}
        else
          EffectRunner.persist_completed_once(effect, result)
        end
      end

      {:ok, effect_id} =
        Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Commit once"}],
          "max_tokens" => 100
        })

      pid =
        start_supervised!(
          {EffectRunner,
           completion_writer: completion_writer, completion_sleeper: fn _delay_ms -> :ok end}
        )

      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      assert_receive {:agent_dispatch, {:effect_result, ^effect_id, {:ok, _result}}}, 1_000
      _ = :sys.get_state(pid)

      effect = Repo.get!(Effect, effect_id)
      assert :counters.get(writes, 1) == 2
      assert :counters.get(command_calls, 1) == 1
      assert effect.status == "completed"
      assert is_binary(effect.completion_claimed_by)
      assert %DateTime{} = effect.completion_claimed_at
      assert effect.claimed_by == nil
      assert effect.claimed_at == nil
    end

    test "retries only completion persistence without re-executing the command", %{
      agent: agent
    } do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])
      command_calls = :counters.new(1, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, CountingSuccessProvider)
      )

      Application.put_env(:maraithon, :effect_runner_command_counter, command_calls)

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_command_counter)
      end)

      :ok = Dispatch.subscribe(agent.id)
      writes = :counters.new(1, [])

      completion_writer = fn effect, result ->
        :counters.add(writes, 1, 1)

        if :counters.get(writes, 1) < 3 do
          {:error, :temporary_database_failure}
        else
          EffectRunner.persist_completed_once(effect, result)
        end
      end

      {:ok, effect_id} =
        Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Count once"}],
          "max_tokens" => 100
        })

      pid =
        start_supervised!(
          {EffectRunner,
           completion_writer: completion_writer, completion_sleeper: fn _delay_ms -> :ok end}
        )

      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      assert_receive {:agent_dispatch, {:effect_result, ^effect_id, {:ok, _result}}}, 1_000
      _ = :sys.get_state(pid)

      assert :counters.get(writes, 1) == 3
      assert :counters.get(command_calls, 1) == 1
      assert Maraithon.Repo.get!(Effect, effect_id).status == "completed"

      send(pid, :poll)
      _ = :sys.get_state(pid)
      assert :counters.get(writes, 1) == 3
      assert :counters.get(command_calls, 1) == 1
    end

    test "terminalizes a successful command when completion persistence stays unavailable", %{
      agent: agent
    } do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])
      command_calls = :counters.new(1, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(original_runtime_config, :llm_provider, CountingSuccessProvider)
      )

      Application.put_env(:maraithon, :effect_runner_command_counter, command_calls)

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
        Application.delete_env(:maraithon, :effect_runner_command_counter)
      end)

      :ok = Dispatch.subscribe(agent.id)
      writes = :counters.new(1, [])

      completion_writer = fn _effect, _result ->
        :counters.add(writes, 1, 1)
        {:error, :database_unavailable}
      end

      {:ok, effect_id} =
        Effects.request(agent.id, "llm_call", nil, %{
          "messages" => [%{"role" => "user", "content" => "Count once"}],
          "max_tokens" => 100
        })

      pid =
        start_supervised!(
          {EffectRunner,
           completion_writer: completion_writer, completion_sleeper: fn _delay_ms -> :ok end}
        )

      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)
      send(pid, :poll)

      assert_receive {:agent_dispatch,
                      {:effect_result, ^effect_id, {:error, :effect_outcome_ambiguous}}},
                     1_000

      _ = :sys.get_state(pid)
      effect = Maraithon.Repo.get!(Effect, effect_id)
      assert :counters.get(writes, 1) == 5
      assert :counters.get(command_calls, 1) == 1
      assert effect.status == "failed"
      assert effect.error == "effect_outcome_ambiguous"
      assert effect.result == nil
      assert effect.retry_after == nil
      assert effect.claimed_by == nil
      assert effect.claimed_at == nil
      assert effect.attempts == 0

      send(pid, :poll)
      _ = :sys.get_state(pid)
      assert :counters.get(writes, 1) == 5
      assert :counters.get(command_calls, 1) == 1
    end

    # -------------------------------------------------------------------------
    # Test: Invalid Tool Handling
    # -------------------------------------------------------------------------
    # Tool calls with non-existent tools should fail gracefully
    # -------------------------------------------------------------------------

    @doc """
    Tests error handling for tool calls with invalid tool names.

    When a tool_call effect references a tool that doesn't exist:
    1. The Tools.execute call returns {:error, :not_found}
    2. The effect enters retry logic
    3. Eventually fails after max attempts
    """
    test "handles tool call with invalid tool", %{agent: agent} do
      case Process.whereis(EffectRunner) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      :ok = Dispatch.subscribe(agent.id)

      # Create a tool call effect with a non-existent tool
      {:ok, effect_id} =
        Maraithon.Effects.request(agent.id, "tool_call", "nonexistent_tool", %{})

      {:ok, pid} = EffectRunner.start_link([])
      Ecto.Adapters.SQL.Sandbox.allow(Maraithon.Repo, self(), pid)

      send(pid, :poll)
      assert_receive {:agent_dispatch, {:effect_result, ^effect_id, {:error, _reason}}}, 1_000
      _ = :sys.get_state(pid)

      updated_effect = Maraithon.Repo.get!(Maraithon.Effects.Effect, effect_id)

      assert updated_effect.status == "failed"
      assert updated_effect.attempts == 1
      assert updated_effect.retry_after == nil

      GenServer.stop(pid, :normal)
    end
  end

  defp database_now do
    [[now]] = Maraithon.Repo.query!("SELECT NOW()").rows
    now
  end
end
