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
    assert failed.failed_at
    assert failed.last_error == "background_job_error"

    GenServer.stop(pid, :normal)
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
end
