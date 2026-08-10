defmodule Maraithon.Runtime.RecurringJobsTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobRunner
  alias Maraithon.Runtime.RecurringJobs

  setup do
    runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, runtime_config)
    end)

    Repo.delete_all(
      from(job in BackgroundJob,
        where: job.status in ["pending", "running"]
      )
    )

    :ok
  end

  test "reconcile durably deduplicates every configured schedule" do
    assert {:ok, %{authority: true, jobs: first}} = RecurringJobs.reconcile()
    assert length(first) == length(RecurringJobs.specs())

    assert {:ok, %{authority: true, jobs: second}} = RecurringJobs.reconcile()

    assert Enum.map(first, &{&1.name, &1.id}) == Enum.map(second, &{&1.name, &1.id})

    active_jobs =
      Repo.all(
        from(job in BackgroundJob,
          where: job.queue == "runtime_recurring",
          where: job.status in ["pending", "running"],
          order_by: job.job_type
        )
      )

    assert length(active_jobs) == length(RecurringJobs.specs())
    assert Enum.uniq_by(active_jobs, & &1.dedupe_key) == active_jobs
    assert Enum.all?(active_jobs, &(&1.status == "pending"))
  end

  test "wall-clock digest persists its exact named-timezone next fire" do
    assert {:ok, %{authority: true}} = RecurringJobs.reconcile()

    job =
      Repo.get_by!(BackgroundJob,
        job_type: RecurringJobs.job_type("dogfood_digest"),
        dedupe_key: RecurringJobs.dedupe_key("dogfood_digest")
      )

    Repo.update_all(from(candidate in BackgroundJob, where: candidate.id == ^job.id),
      set: [scheduled_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    runner =
      start_supervised!(
        {BackgroundJobRunner,
         name: :dogfood_recurring_job_runner_test,
         poll_interval_ms: :timer.minutes(1),
         batch_size: 1,
         max_concurrency: 1,
         reconcile_recurring_jobs?: false}
      )

    assert {:ok,
            [
              {job_id,
               {:ok, %{outcome: "skipped", next_fire_at: next_fire}, {:reschedule_at, next_fire}}}
            ]} = BackgroundJobRunner.drain_once(runner)

    assert job_id == job.id
    rescheduled = Repo.get!(BackgroundJob, job.id)
    assert rescheduled.status == "pending"
    assert rescheduled.scheduled_at == next_fire
    assert rescheduled.claim_token == nil
  end

  test "invalid timezone repair cannot replace an existing validated wall-clock spec" do
    runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(runtime_config, :dogfood_digest_timezone, "America/Toronto")
    )

    assert {:ok, %{authority: true}} = RecurringJobs.reconcile()

    valid_job =
      Repo.get_by!(BackgroundJob,
        job_type: RecurringJobs.job_type("dogfood_digest"),
        dedupe_key: RecurringJobs.dedupe_key("dogfood_digest")
      )

    assert valid_job.payload["wall_clock"]["timezone"] == "America/Toronto"

    invalid_timezone = "invalid-sensitive-timezone"

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(runtime_config, :dogfood_digest_timezone, invalid_timezone)
    )

    log =
      capture_log(fn ->
        assert {:ok, %{authority: true, jobs: jobs}} = RecurringJobs.reconcile()

        assert %{id: id, repair: "rejected"} =
                 Enum.find(jobs, &(&1.name == "dogfood_digest"))

        assert id == valid_job.id
      end)

    assert log =~ "Dogfood digest schedule repair rejected: invalid timezone configuration"
    refute log =~ invalid_timezone

    unchanged = Repo.get!(BackgroundJob, valid_job.id)
    assert unchanged.payload == valid_job.payload
    assert {:ok, _result, {:reschedule_at, %DateTime{}}} = RecurringJobs.execute(unchanged)
  end

  test "a successful claimed cycle self-reschedules the same fenced row" do
    assert {:ok, %{authority: true}} = RecurringJobs.reconcile()

    job =
      Repo.get_by!(BackgroundJob,
        job_type: RecurringJobs.job_type("telegram_run_reaper"),
        dedupe_key: RecurringJobs.dedupe_key("telegram_run_reaper")
      )

    now = DateTime.utc_now()

    Repo.update_all(from(candidate in BackgroundJob, where: candidate.id == ^job.id),
      set: [scheduled_at: DateTime.add(now, -1, :second)]
    )

    runner =
      start_supervised!(
        {BackgroundJobRunner,
         name: :recurring_job_runner_test,
         poll_interval_ms: :timer.minutes(1),
         batch_size: 1,
         max_concurrency: 1,
         reconcile_recurring_jobs?: false}
      )

    assert {:ok,
            [
              {job_id, {:ok, %{reaped: 0}, {:reschedule_in, interval_ms}}}
            ]} = BackgroundJobRunner.drain_once(runner)

    assert job_id == job.id
    assert interval_ms > 0

    rescheduled = Repo.get!(BackgroundJob, job.id)
    assert rescheduled.status == "pending"
    assert rescheduled.claimed_by == nil
    assert rescheduled.claimed_at == nil
    assert rescheduled.claim_token == nil
    assert rescheduled.attempts == 0
    assert rescheduled.result == %{"reaped" => 0}
    assert DateTime.compare(rescheduled.scheduled_at, now) == :gt

    assert Repo.aggregate(
             from(candidate in BackgroundJob,
               where: candidate.dedupe_key == ^job.dedupe_key
             ),
             :count
           ) == 1
  end
end
