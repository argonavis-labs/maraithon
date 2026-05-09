defmodule Maraithon.Runtime.BackgroundJobRunnerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobRunner
  alias Maraithon.Runtime.BackgroundJobs

  setup do
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
    assert failed.last_error =~ "execute/1 is undefined"

    GenServer.stop(pid, :normal)
  end
end
