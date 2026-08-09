defmodule Maraithon.Runtime.RetryAfterTestHandler do
  @moduledoc false
  # Stands in for a real handler (e.g. the Gmail/Calendar incremental sync
  # clauses) that hit a 429 and want a provider-specified backoff instead of
  # burning a job attempt.
  def execute(%Maraithon.Runtime.BackgroundJob{}) do
    {:error, {:retry_after, 5, {:rate_limited, "provider-account-secret"}}}
  end
end

defmodule Maraithon.Runtime.HugeRetryAfterTestHandler do
  @moduledoc false
  # Stands in for a provider sending an absurd (or malicious) Retry-After
  # header — the runner must clamp this rather than parking the job for
  # that long.
  def execute(%Maraithon.Runtime.BackgroundJob{}) do
    {:error, {:retry_after, 100_000, {:rate_limited, "way too long"}}}
  end
end

defmodule Maraithon.Runtime.BlockingClaimTestHandler do
  @moduledoc false

  def execute(%Maraithon.Runtime.BackgroundJob{} = job) do
    claim_token = job.claim_token
    observer = Process.whereis(:background_job_claim_test_observer)
    send(observer, {:background_job_claim_started, self(), job.id, claim_token})

    receive do
      {:release_background_job_claim, ^claim_token, result} ->
        result

      {:crash_background_job_claim, ^claim_token, reason} ->
        exit(reason)

      {:enter_background_job_finishing, ^claim_token, runner, result} ->
        :ok =
          GenServer.call(
            runner,
            {:background_job_finishing, job.id, claim_token},
            :infinity
          )

        send(observer, {:background_job_finishing, self(), job.id, claim_token})

        receive do
          {:release_background_job_finishing, ^claim_token} -> result
        after
          10_000 -> {:error, :claim_test_timeout}
        end
    after
      10_000 -> {:error, :claim_test_timeout}
    end
  end
end

defmodule Maraithon.Runtime.BackgroundJobRunnerTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Crm.Ingest
  alias Maraithon.Crm.Ingest.Window
  alias Maraithon.Crm.Observation
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobRunner
  alias Maraithon.Runtime.BackgroundJobs

  setup do
    Repo.delete_all(from job in BackgroundJob, where: job.status in ["pending", "running"])

    user_id = "background-runner-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  test "drain_once claims and completes pending jobs without request-path execution", %{
    user_id: user_id
  } do
    {:ok, job} =
      BackgroundJobs.enqueue("open_loop_check", %{
        user_id: user_id,
        queue: "open_loops",
        payload: %{"query" => "Charlie", "limit" => 5}
      })

    job_id = job.id

    {:ok, pid} =
      BackgroundJobRunner.start_link(
        name: :background_job_runner_completion_test,
        poll_interval_ms: 60_000,
        batch_size: 5
      )

    assert {:ok, [{^job_id, {:ok, %{source: "background_open_loop_check"}}}]} =
             BackgroundJobRunner.drain_once(pid)

    stored = Repo.get!(BackgroundJob, job.id)
    assert stored.status == "completed"
    assert stored.completed_at
    assert stored.claimed_by == nil
    assert stored.claim_token == nil
    assert stored.result["source"] == "background_open_loop_check"

    GenServer.stop(pid, :normal)
  end

  test "failed jobs retry with backoff before being marked failed", %{user_id: user_id} do
    {:ok, job} =
      BackgroundJobs.enqueue("test_job", %{
        user_id: user_id,
        queue: "test",
        payload: %{"fail" => true},
        max_attempts: 2
      })

    job_id = job.id

    {:ok, pid} =
      BackgroundJobRunner.start_link(
        name: :background_job_runner_retry_test,
        poll_interval_ms: 60_000,
        batch_size: 5
      )

    assert {:ok, [{^job_id, {:error, {:unknown_background_job, "test_job"}}}]} =
             BackgroundJobRunner.drain_once(pid)

    stored = Repo.get!(BackgroundJob, job.id)
    assert stored.status == "pending"
    assert stored.attempts == 1
    assert stored.claim_token == nil
    assert DateTime.compare(stored.scheduled_at, job.scheduled_at) == :gt
    assert stored.last_error =~ "unknown_background_job"

    {:ok, due_job} =
      stored
      |> Ecto.Changeset.change(%{scheduled_at: DateTime.utc_now()})
      |> Repo.update()

    assert {:ok, [{^job_id, {:error, {:unknown_background_job, "test_job"}}}]} =
             BackgroundJobRunner.drain_once(pid)

    failed = Repo.get!(BackgroundJob, due_job.id)
    assert failed.status == "failed"
    assert failed.attempts == 2
    assert failed.claim_token == nil
    assert failed.failed_at

    GenServer.stop(pid, :normal)
  end

  test "a {:retry_after, seconds, reason} error reschedules without burning an attempt", %{
    user_id: user_id
  } do
    {:ok, job} =
      BackgroundJobs.enqueue("retry_after_probe", %{
        user_id: user_id,
        queue: "test",
        max_attempts: 3
      })

    job_id = job.id

    {:ok, pid} =
      BackgroundJobRunner.start_link(
        name: :background_job_runner_retry_after_test,
        handler: Maraithon.Runtime.RetryAfterTestHandler,
        poll_interval_ms: 60_000,
        batch_size: 5
      )

    before_call = DateTime.utc_now()

    assert {:ok,
            [{^job_id, {:error, {:retry_after, 5, {:rate_limited, "provider-account-secret"}}}}]} =
             BackgroundJobRunner.drain_once(pid)

    stored = Repo.get!(BackgroundJob, job.id)
    assert stored.status == "pending"
    assert stored.attempts == 0
    assert stored.claimed_by == nil
    assert stored.claim_token == nil
    assert stored.last_error =~ "rate_limited"
    refute stored.last_error =~ "provider-account-secret"
    assert DateTime.diff(stored.scheduled_at, before_call, :second) in 3..7

    GenServer.stop(pid, :normal)
  end

  test "clamps an absurd Retry-After delay instead of parking the job that long", %{
    user_id: user_id
  } do
    {:ok, job} =
      BackgroundJobs.enqueue("huge_retry_after_probe", %{
        user_id: user_id,
        queue: "test",
        max_attempts: 3
      })

    job_id = job.id

    {:ok, pid} =
      BackgroundJobRunner.start_link(
        name: :background_job_runner_huge_retry_after_test,
        handler: Maraithon.Runtime.HugeRetryAfterTestHandler,
        poll_interval_ms: 60_000,
        batch_size: 5
      )

    before_call = DateTime.utc_now()

    assert {:ok,
            [
              {^job_id, {:error, {:retry_after, 100_000, {:rate_limited, "way too long"}}}}
            ]} = BackgroundJobRunner.drain_once(pid)

    stored = Repo.get!(BackgroundJob, job.id)
    assert stored.status == "pending"
    assert stored.attempts == 0
    # Clamped to the runner's ceiling (3600s) rather than the requested
    # 100_000s delay.
    assert DateTime.diff(stored.scheduled_at, before_call, :second) <= 3_605

    GenServer.stop(pid, :normal)
  end

  test "hands a job off to ordinary attempt/backoff machinery after too many rate-limit reschedules",
       %{user_id: user_id} do
    {:ok, job} =
      BackgroundJobs.enqueue("retry_after_cap_probe", %{
        user_id: user_id,
        queue: "test",
        max_attempts: 3
      })

    # Simulate 20 prior rate-limit reschedules that (correctly) never burned
    # an attempt, the way the normal `:retry_after` path behaves.
    Repo.update_all(from(j in BackgroundJob, where: j.id == ^job.id),
      set: [result: %{"retry_after_count" => 20}]
    )

    job_id = job.id

    {:ok, pid} =
      BackgroundJobRunner.start_link(
        name: :background_job_runner_retry_after_cap_test,
        handler: Maraithon.Runtime.RetryAfterTestHandler,
        poll_interval_ms: 60_000,
        batch_size: 5
      )

    assert {:ok,
            [{^job_id, {:error, {:retry_after, 5, {:rate_limited, "provider-account-secret"}}}}]} =
             BackgroundJobRunner.drain_once(pid)

    stored = Repo.get!(BackgroundJob, job.id)
    # The 21st rate-limited reschedule burns an attempt instead of
    # rescheduling forever.
    assert stored.status == "pending"
    assert stored.attempts == 1
    assert DateTime.compare(stored.scheduled_at, job.scheduled_at) == :gt

    GenServer.stop(pid, :normal)
  end

  test "handler exceptions are recorded as job failures", %{user_id: user_id} do
    {:ok, job} =
      BackgroundJobs.enqueue("raising_job", %{
        user_id: user_id,
        queue: "test",
        max_attempts: 1
      })

    job_id = job.id

    {:ok, pid} =
      BackgroundJobRunner.start_link(
        name: :background_job_runner_raise_test,
        handler: Maraithon.Runtime.MissingBackgroundJobHandler,
        poll_interval_ms: 60_000,
        batch_size: 5
      )

    assert {:ok, [{^job_id, {:error, error}}]} = BackgroundJobRunner.drain_once(pid)
    assert error =~ "execute/1 is undefined"

    failed = Repo.get!(BackgroundJob, job.id)
    assert failed.status == "failed"
    assert failed.attempts == 1
    assert failed.claim_token == nil
    assert failed.failed_at
    assert failed.last_error == "background_job_error"

    GenServer.stop(pid, :normal)
  end

  test "a blocked drain stays responsive, renews its claim, and replies after ownership loss", %{
    user_id: user_id
  } do
    register_claim_observer!()

    {:ok, job} =
      BackgroundJobs.enqueue("drain_claim_probe", %{
        user_id: user_id,
        queue: "test"
      })

    legacy_token = Ecto.UUID.generate()

    {1, _rows} =
      BackgroundJob
      |> where([candidate], candidate.id == ^job.id)
      |> where([candidate], candidate.status == "pending")
      |> Repo.update_all(set: [claim_token: legacy_token])

    runner = start_claim_runner(:background_job_drain_claim_runner)
    drain_call = Task.async(fn -> BackgroundJobRunner.drain_once(runner) end)
    job_id = job.id

    assert_receive {:background_job_claim_started, task, ^job_id, claim_token}, 1_000
    assert claim_token != legacy_token

    state = :sys.get_state(runner)
    assert state.poll_interval_ms >= state.claim_timeout_ms
    assert state.renew_interval_ms < state.claim_timeout_ms
    assert is_integer(Process.read_timer(state.renew_timer))
    assert Map.has_key?(state.running, {job.id, claim_token})
    assert {job.id, claim_token} in Map.values(state.monitors)
    assert map_size(state.drains) == 1

    # A second call proves that the first deferred call is not blocking the
    # GenServer, and also covers the empty-batch return shape.
    assert {:ok, []} = BackgroundJobRunner.drain_once(runner)

    claimed = Repo.get!(BackgroundJob, job.id)
    assert claimed.status == "running"
    assert claimed.claim_token == claim_token

    backdated_heartbeat = DateTime.add(claimed.claimed_at, -5, :second)

    {1, _rows} =
      BackgroundJob
      |> where([candidate], candidate.id == ^job.id)
      |> where([candidate], candidate.claim_token == ^claim_token)
      |> Repo.update_all(set: [claimed_at: backdated_heartbeat])

    send(runner, :renew_claims)
    _state = :sys.get_state(runner)

    renewed = Repo.get!(BackgroundJob, job.id)
    assert renewed.claim_token == claim_token
    assert DateTime.compare(renewed.claimed_at, backdated_heartbeat) == :gt

    replacement_token = Ecto.UUID.generate()

    {1, _rows} =
      BackgroundJob
      |> where([candidate], candidate.id == ^job.id)
      |> where([candidate], candidate.claim_token == ^claim_token)
      |> Repo.update_all(set: [claim_token: replacement_token])

    task_ref = Process.monitor(task)
    send(runner, :renew_claims)
    _state = :sys.get_state(runner)

    assert_receive {:DOWN, ^task_ref, :process, ^task, :killed}, 1_000

    assert {:ok, [{^job_id, {:error, :claim_lost}}]} =
             Task.await(drain_call, 1_000)

    final_state = :sys.get_state(runner)
    refute Map.has_key?(final_state.running, {job.id, claim_token})
    assert final_state.drains == %{}

    current = Repo.get!(BackgroundJob, job.id)
    assert current.status == "running"
    assert current.claim_token == replacement_token
    assert current.attempts == 0
    assert current.last_error == nil
  end

  test "a crashed drain task releases its exact generation and replies", %{user_id: user_id} do
    register_claim_observer!()

    {:ok, job} =
      BackgroundJobs.enqueue("drain_crash_probe", %{
        user_id: user_id,
        queue: "test"
      })

    runner = start_claim_runner(:background_job_drain_crash_runner)
    drain_call = Task.async(fn -> BackgroundJobRunner.drain_once(runner) end)
    job_id = job.id

    assert_receive {:background_job_claim_started, task, ^job_id, claim_token}, 1_000
    task_ref = Process.monitor(task)
    Process.exit(task, :kill)

    assert_receive {:DOWN, ^task_ref, :process, ^task, :killed}, 1_000

    assert {:ok, [{^job_id, {:error, {:job_task_crashed, :killed}}}]} =
             Task.await(drain_call, 1_000)

    retried = Repo.get!(BackgroundJob, job.id)
    assert retried.status == "pending"
    assert retried.attempts == 1
    assert retried.claim_token == nil
    assert retried.claimed_by == nil
    assert retried.claimed_at == nil
    assert retried.last_error == "job_task_crashed"
    refute Map.has_key?(:sys.get_state(runner).running, {job.id, claim_token})
  end

  test "drain reports claim loss when its terminal CAS loses after finishing", %{
    user_id: user_id
  } do
    register_claim_observer!()

    {:ok, job} =
      BackgroundJobs.enqueue("drain_finishing_loss_probe", %{
        user_id: user_id,
        queue: "test"
      })

    runner = start_claim_runner(:background_job_drain_finishing_loss_runner)
    drain_call = Task.async(fn -> BackgroundJobRunner.drain_once(runner) end)
    job_id = job.id

    assert_receive {:background_job_claim_started, task, ^job_id, claim_token}, 1_000

    send(
      task,
      {:enter_background_job_finishing, claim_token, runner, {:ok, %{late: true}}}
    )

    assert_receive {:background_job_finishing, ^task, ^job_id, ^claim_token}, 1_000

    replacement_token = Ecto.UUID.generate()

    {1, _rows} =
      BackgroundJob
      |> where([candidate], candidate.id == ^job.id)
      |> where([candidate], candidate.claim_token == ^claim_token)
      |> Repo.update_all(set: [claim_token: replacement_token])

    task_ref = Process.monitor(task)
    send(task, {:release_background_job_finishing, claim_token})

    assert_receive {:DOWN, ^task_ref, :process, ^task, :normal}, 1_000

    assert {:ok, [{^job_id, {:error, :claim_lost}}]} =
             Task.await(drain_call, 1_000)

    current = Repo.get!(BackgroundJob, job.id)
    assert current.status == "running"
    assert current.claim_token == replacement_token
    assert current.completed_at == nil
    assert current.result == %{}
    assert :sys.get_state(runner).drains == %{}
  end

  test "drain classifies a database transition failure as persistence deferred", %{
    user_id: user_id
  } do
    register_claim_observer!()

    Repo.query!("""
    CREATE FUNCTION maraithon_test_fail_background_job_transition()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.job_type = 'drain_persistence_failure_probe'
         AND OLD.status = 'running'
         AND NEW.status <> 'running' THEN
        RAISE EXCEPTION 'injected background job transition failure';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER maraithon_test_fail_background_job_transition
    BEFORE UPDATE ON background_jobs
    FOR EACH ROW
    EXECUTE FUNCTION maraithon_test_fail_background_job_transition()
    """)

    {:ok, job} =
      BackgroundJobs.enqueue("drain_persistence_failure_probe", %{
        user_id: user_id,
        queue: "test"
      })

    runner = start_claim_runner(:background_job_drain_persistence_failure_runner)
    drain_call = Task.async(fn -> BackgroundJobRunner.drain_once(runner) end)
    job_id = job.id

    assert_receive {:background_job_claim_started, task, ^job_id, claim_token}, 1_000
    task_ref = Process.monitor(task)

    send(task, {:release_background_job_claim, claim_token, {:ok, %{ignored: true}}})
    assert_receive {:DOWN, ^task_ref, :process, ^task, :normal}, 1_000

    assert {:ok, [{^job_id, {:error, :persistence_deferred}}]} =
             Task.await(drain_call, 1_000)
  end

  test "supervisor shutdown kills a blocked drain task and resolves its caller", %{
    user_id: user_id
  } do
    register_claim_observer!()

    {:ok, job} =
      BackgroundJobs.enqueue("drain_stop_probe", %{
        user_id: user_id,
        queue: "test"
      })

    runner = start_claim_runner(:background_job_drain_stop_runner)
    drain_call = Task.async(fn -> BackgroundJobRunner.drain_once(runner) end)
    job_id = job.id

    assert_receive {:background_job_claim_started, task, ^job_id, claim_token}, 1_000

    assert {:trap_exit, true} = Process.info(runner, :trap_exit)

    task_ref = Process.monitor(task)
    runner_ref = Process.monitor(runner)
    assert :ok = stop_supervised(:background_job_drain_stop_runner)

    assert_receive {:DOWN, ^task_ref, :process, ^task, :killed}, 1_000
    assert_receive {:DOWN, ^runner_ref, :process, ^runner, :shutdown}, 1_000
    assert {:error, :runner_stopped} = Task.await(drain_call, 1_000)

    # Termination cannot make already-started handler side effects exactly
    # once. The fenced row remains recoverable by the stale-claim sweep.
    current = Repo.get!(BackgroundJob, job.id)
    assert current.status == "running"
    assert current.claim_token == claim_token
  end

  test "drain caps a batch larger than max beside pre-existing work and concurrent calls", %{
    user_id: user_id
  } do
    register_claim_observer!()

    {:ok, existing_job} =
      BackgroundJobs.enqueue("preexisting_claim_probe", %{
        user_id: user_id,
        queue: "test"
      })

    runner =
      start_claim_runner(:background_job_drain_concurrency_runner,
        batch_size: 5,
        max_concurrency: 2
      )

    send(runner, :poll)
    existing_id = existing_job.id

    assert_receive {:background_job_claim_started, existing_task, ^existing_id, existing_token},
                   1_000

    {:ok, first_drain_job} =
      BackgroundJobs.enqueue("first_bounded_drain_probe", %{
        user_id: user_id,
        queue: "test"
      })

    {:ok, second_drain_job} =
      BackgroundJobs.enqueue("second_bounded_drain_probe", %{
        user_id: user_id,
        queue: "test"
      })

    drain_call = Task.async(fn -> BackgroundJobRunner.drain_once(runner) end)

    assert_receive {:background_job_claim_started, drain_task, drain_job_id, drain_token}, 1_000
    assert drain_job_id in [first_drain_job.id, second_drain_job.id]

    state = :sys.get_state(runner)
    assert state.batch_size > state.max_concurrency
    assert map_size(state.running) == state.max_concurrency

    # A concurrent drain observes no remaining slot and cannot exceed the
    # ceiling while the first deferred drain is still blocked.
    assert {:ok, []} = BackgroundJobRunner.drain_once(runner)
    assert map_size(:sys.get_state(runner).running) == 2

    bounded_jobs =
      Repo.all(
        from candidate in BackgroundJob,
          where: candidate.id in ^[first_drain_job.id, second_drain_job.id]
      )

    assert Enum.count(bounded_jobs, &(&1.status == "running")) == 1
    assert Enum.count(bounded_jobs, &(&1.status == "pending")) == 1

    drain_ref = Process.monitor(drain_task)
    send(drain_task, {:release_background_job_claim, drain_token, {:ok, %{drained: true}}})
    assert_receive {:DOWN, ^drain_ref, :process, ^drain_task, :normal}, 1_000

    assert {:ok, [{^drain_job_id, {:ok, %{drained: true}}}]} =
             Task.await(drain_call, 1_000)

    existing_ref = Process.monitor(existing_task)

    send(
      existing_task,
      {:release_background_job_claim, existing_token, {:ok, %{preexisting: true}}}
    )

    assert_receive {:DOWN, ^existing_ref, :process, ^existing_task, :normal}, 1_000
    await_claim_removed(runner, {existing_job.id, existing_token})
  end

  test "claim renewal preserves the generation and ownership loss stops the stale task", %{
    user_id: user_id
  } do
    register_claim_observer!()

    {:ok, job} =
      BackgroundJobs.enqueue("claim_renewal_probe", %{
        user_id: user_id,
        queue: "test"
      })

    runner = start_claim_runner(:background_job_claim_renewal_runner)
    send(runner, :poll)

    assert_receive {:background_job_claim_started, task, job_id, claim_token}, 1_000
    assert job_id == job.id
    assert {:ok, ^claim_token} = Ecto.UUID.cast(claim_token)

    claimed = Repo.get!(BackgroundJob, job.id)
    assert claimed.claim_token == claim_token
    assert claimed.claimed_by == to_string(node())
    assert claimed.claim_token != claimed.claimed_by

    backdated_heartbeat = DateTime.add(claimed.claimed_at, -5, :second)

    {1, _rows} =
      BackgroundJob
      |> where([candidate], candidate.id == ^job.id)
      |> where([candidate], candidate.claim_token == ^claim_token)
      |> Repo.update_all(set: [claimed_at: backdated_heartbeat])

    send(runner, :renew_claims)
    _state = :sys.get_state(runner)

    renewed = Repo.get!(BackgroundJob, job.id)
    assert renewed.claim_token == claim_token
    assert renewed.claimed_by == claimed.claimed_by
    assert DateTime.compare(renewed.claimed_at, backdated_heartbeat) == :gt

    replacement_token = Ecto.UUID.generate()

    {1, _rows} =
      BackgroundJob
      |> where([candidate], candidate.id == ^job.id)
      |> where([candidate], candidate.claim_token == ^claim_token)
      |> Repo.update_all(set: [claim_token: replacement_token])

    task_ref = Process.monitor(task)
    send(runner, :renew_claims)
    _state = :sys.get_state(runner)

    assert_receive {:DOWN, ^task_ref, :process, ^task, :killed}, 1_000
    await_claim_removed(runner, {job.id, claim_token})

    current = Repo.get!(BackgroundJob, job.id)
    assert current.status == "running"
    assert current.claim_token == replacement_token
    assert current.attempts == 0
    assert current.last_error == nil
  end

  test "cancellation CAS clears the claim and late completion cannot overwrite it", %{
    user_id: user_id
  } do
    register_claim_observer!()

    {:ok, job} =
      BackgroundJobs.enqueue("claim_cancel_probe", %{
        user_id: user_id,
        queue: "test"
      })

    runner = start_claim_runner(:background_job_claim_cancel_runner)
    send(runner, :poll)

    assert_receive {:background_job_claim_started, task, job_id, claim_token}, 1_000
    assert job_id == job.id
    task_ref = Process.monitor(task)

    assert {:ok, :cancelled} = BackgroundJobs.cancel(job.id)

    cancelled = Repo.get!(BackgroundJob, job.id)
    assert cancelled.status == "cancelled"
    assert cancelled.claimed_by == nil
    assert cancelled.claimed_at == nil
    assert cancelled.claim_token == nil

    send(task, {:release_background_job_claim, claim_token, {:ok, %{late: true}}})
    assert_receive {:DOWN, ^task_ref, :process, ^task, :normal}, 1_000
    await_claim_removed(runner, {job.id, claim_token})

    unchanged = Repo.get!(BackgroundJob, job.id)
    assert unchanged.status == "cancelled"
    assert unchanged.completed_at == nil
    assert unchanged.claim_token == nil
    assert unchanged.result == %{}
  end

  test "stale generations cannot complete, retry, fail, or rate-limit a reclaimed job", %{
    user_id: user_id
  } do
    register_claim_observer!()

    [
      %{
        suffix: "complete",
        first_runner: :background_job_stale_complete_first_runner,
        second_runner: :background_job_stale_complete_second_runner,
        max_attempts: 3,
        stale_result: {:ok, %{late: true}}
      },
      %{
        suffix: "retry",
        first_runner: :background_job_stale_retry_first_runner,
        second_runner: :background_job_stale_retry_second_runner,
        max_attempts: 3,
        stale_result: {:error, :late_retry}
      },
      %{
        suffix: "fail",
        first_runner: :background_job_stale_fail_first_runner,
        second_runner: :background_job_stale_fail_second_runner,
        max_attempts: 1,
        stale_result: {:error, :late_failure}
      },
      %{
        suffix: "retry_after",
        first_runner: :background_job_stale_retry_after_first_runner,
        second_runner: :background_job_stale_retry_after_second_runner,
        max_attempts: 3,
        stale_result: {:error, {:retry_after, 60, :late_rate_limit}}
      }
    ]
    |> Enum.each(&assert_stale_generation_fenced(user_id, &1))
  end

  test "drain_once force-flushes stale CRM ingest windows", %{user_id: user_id} do
    {:ok, :buffered, _id} =
      Ingest.observe(
        user_id,
        Observation.new(%{
          "user_id" => user_id,
          "source" => "gmail",
          "source_account" => "primary",
          "source_item_id" => "stale-#{System.unique_integer([:positive])}",
          "occurred_at" => DateTime.utc_now(),
          "direction" => "inbound",
          "participants" => [
            %{"role" => "from", "identifier" => %{"email" => "stale@example.com"}}
          ]
        })
      )

    window =
      Repo.one(
        from w in Window,
          where: w.user_id == ^user_id and w.source == "gmail" and w.status == "open"
      )

    old_opened_at =
      DateTime.add(DateTime.utc_now(), -(Ingest.stale_window_minutes() + 5) * 60, :second)

    Repo.update_all(from(w in Window, where: w.id == ^window.id),
      set: [opened_at: old_opened_at]
    )

    {:ok, pid} =
      BackgroundJobRunner.start_link(
        name: :background_job_runner_window_sweep_test,
        poll_interval_ms: 60_000,
        batch_size: 1
      )

    assert {:ok, _} = BackgroundJobRunner.drain_once(pid)

    reloaded = Repo.get!(Window, window.id)

    # Sweep moved the window out of `open` (the resulting job may then
    # complete or fail depending on whether downstream LLM stubs are wired,
    # but we only care that the runner triggered the flush here).
    assert reloaded.status in ["flushed", "completed", "failed"]

    assert Repo.exists?(
             from j in BackgroundJob,
               where: j.dedupe_key == ^"crm_ingest:flush:#{window.id}"
           )

    GenServer.stop(pid, :normal)
  end

  defp assert_stale_generation_fenced(user_id, spec) do
    {:ok, job} =
      BackgroundJobs.enqueue("claim_#{spec.suffix}_probe", %{
        user_id: user_id,
        queue: "test",
        max_attempts: spec.max_attempts
      })

    first_runner = start_claim_runner(spec.first_runner)
    send(first_runner, :poll)

    job_id = job.id

    assert_receive {:background_job_claim_started, first_task, ^job_id, first_token}, 1_000

    stale_heartbeat = DateTime.add(DateTime.utc_now(), -5, :second)

    {1, _rows} =
      BackgroundJob
      |> where([candidate], candidate.id == ^job.id)
      |> where([candidate], candidate.claim_token == ^first_token)
      |> Repo.update_all(set: [claimed_at: stale_heartbeat])

    second_runner = start_claim_runner(spec.second_runner, claim_timeout_ms: 100)
    send(second_runner, :poll)

    assert_receive {:background_job_claim_started, second_task, ^job_id, second_token}, 1_000
    assert second_token != first_token

    first_ref = Process.monitor(first_task)
    send(first_task, {:release_background_job_claim, first_token, spec.stale_result})
    assert_receive {:DOWN, ^first_ref, :process, ^first_task, :normal}, 1_000
    await_claim_removed(first_runner, {job.id, first_token})

    current = Repo.get!(BackgroundJob, job.id)
    assert current.status == "running"
    assert current.claim_token == second_token
    assert current.attempts == 0
    assert current.completed_at == nil
    assert current.failed_at == nil
    assert current.last_error == nil
    assert current.result == %{}

    second_ref = Process.monitor(second_task)

    send(
      second_task,
      {:release_background_job_claim, second_token, {:ok, %{winner: spec.suffix}}}
    )

    assert_receive {:DOWN, ^second_ref, :process, ^second_task, :normal}, 1_000
    await_claim_removed(second_runner, {job.id, second_token})

    completed = Repo.get!(BackgroundJob, job.id)
    assert completed.status == "completed"
    assert completed.claim_token == nil
    assert completed.result == %{"winner" => spec.suffix}
  end

  defp start_claim_runner(name, overrides \\ []) do
    opts =
      Keyword.merge(
        [
          name: name,
          handler: Maraithon.Runtime.BlockingClaimTestHandler,
          poll_interval_ms: 60_000,
          claim_timeout_ms: 60_000,
          batch_size: 1,
          max_concurrency: 1
        ],
        overrides
      )

    start_supervised!(%{
      id: name,
      start: {BackgroundJobRunner, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    })
  end

  defp register_claim_observer! do
    assert Process.whereis(:background_job_claim_test_observer) == nil
    assert Process.register(self(), :background_job_claim_test_observer)
  end

  defp await_claim_removed(runner, key, attempts \\ 50)

  defp await_claim_removed(runner, key, attempts) when attempts > 0 do
    state = :sys.get_state(runner)

    if Map.has_key?(state.running, key) do
      await_claim_removed(runner, key, attempts - 1)
    else
      :ok
    end
  end

  defp await_claim_removed(_runner, key, 0) do
    flunk("runner did not release claim bookkeeping for #{inspect(key)}")
  end
end
