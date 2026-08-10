defmodule Maraithon.Runtime.FairBackgroundJobLanesTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobRunner
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.TestSupport.FairLaneTestHandler

  setup do
    Repo.delete_all(BackgroundJob)
    Repo.delete_all("background_job_partitions")
    Repo.delete_all("background_job_rate_limits")

    Process.register(self(), :fair_lane_test_observer)

    on_exit(fn ->
      if Process.whereis(:fair_lane_test_observer) == self() do
        Process.unregister(:fair_lane_test_observer)
      end
    end)

    :ok
  end

  test "fair lane takes one job per tenant and serves never-run tenants first" do
    a1 = enqueue!("a1", "tenant:a", -4)
    _a2 = enqueue!("a2", "tenant:a", -3)
    b = enqueue!("b", "tenant:b", -2)
    c = enqueue!("c", "tenant:c", -1)

    runner = start_fair_runner(:fair_rotation_runner, max_concurrency: 2, batch_size: 2)

    assert {:ok, first} = BackgroundJobRunner.drain_once(runner)
    assert Enum.map(first, &elem(&1, 0)) == [a1.id, b.id]

    assert {:ok, second} = BackgroundJobRunner.drain_once(runner)
    assert Enum.map(second, &elem(&1, 0)) |> hd() == c.id

    assert Enum.map(second, fn {_id, {:ok, result}} -> result.partition end) == [
             "tenant:c",
             "tenant:a"
           ]
  end

  test "provider selection interleaves rate families before taking a second hot account" do
    google_first = enqueue!("google-hot-1", "account:hot-1", -3, "google")
    google_second = enqueue!("google-hot-2", "account:hot-2", -2, "google")
    slack = enqueue!("slack-peer", "account:peer", -1, "slack")

    runner =
      start_fair_runner(:fair_provider_interleave_runner,
        max_concurrency: 2,
        batch_size: 2,
        max_rate_limit_concurrency: 1
      )

    assert {:ok, results} = BackgroundJobRunner.drain_once(runner)
    assert Enum.map(results, &elem(&1, 0)) == [google_first.id, slack.id]
    assert Repo.get!(BackgroundJob, google_second.id).status == "pending"
  end

  test "provider Retry-After durably cools its rate key without blocking another provider" do
    google_first = enqueue!("google-1", "account:1", -3, "google", "retry")
    google_second = enqueue!("google-2", "account:2", -2, "google")
    slack = enqueue!("slack-1", "account:3", -1, "slack")

    runner =
      start_fair_runner(:fair_rate_runner,
        max_concurrency: 1,
        batch_size: 1,
        max_rate_limit_concurrency: 1
      )

    assert {:ok, [{first_id, {:error, {:retry_after, 60, :provider_rate_limited}}}]} =
             BackgroundJobRunner.drain_once(runner)

    assert first_id == google_first.id

    assert [[blocked_until]] =
             Repo.query!(
               "SELECT blocked_until FROM background_job_rate_limits WHERE queue = $1 AND rate_limit_key = $2",
               ["runtime_model_user", "google"]
             ).rows

    blocked_until =
      case blocked_until do
        %DateTime{} = value -> value
        %NaiveDateTime{} = value -> DateTime.from_naive!(value, "Etc/UTC")
      end

    assert DateTime.compare(blocked_until, DateTime.utc_now()) == :gt

    assert {:ok, [{next_id, {:ok, _result}}]} = BackgroundJobRunner.drain_once(runner)
    assert next_id == slack.id
    assert Repo.get!(BackgroundJob, google_second.id).status == "pending"
  end

  test "a killed lane runner leaves a fenced claim that a new runner reclaims" do
    job = enqueue!("crash", "tenant:crash", -1, nil, "block")

    {:ok, first_runner} =
      BackgroundJobRunner.start_link(
        name: :crashed_fair_lane_runner,
        queues: ["runtime_model_user"],
        fair?: true,
        poll_interval_ms: :timer.hours(1),
        claim_timeout_ms: 1_000,
        batch_size: 1,
        max_concurrency: 1,
        reconcile_recurring_jobs?: false,
        handler: FairLaneTestHandler
      )

    Process.unlink(first_runner)
    test_pid = self()

    spawn(fn ->
      result =
        try do
          BackgroundJobRunner.drain_once(first_runner)
        catch
          :exit, reason -> {:runner_exit, reason}
        end

      send(test_pid, {:first_drain_finished, result})
    end)

    assert_receive {:fair_lane_started, first_handler, %BackgroundJob{id: job_id}}, 2_000
    assert job_id == job.id

    first_runner_ref = Process.monitor(first_runner)
    Process.exit(first_runner, :kill)
    assert_receive {:DOWN, ^first_runner_ref, :process, ^first_runner, :killed}, 2_000
    assert_receive {:first_drain_finished, {:runner_exit, _reason}}, 2_000

    stale_at = DateTime.add(DateTime.utc_now(), -2, :second)

    Repo.update_all(from(candidate in BackgroundJob, where: candidate.id == ^job.id),
      set: [claimed_at: stale_at]
    )

    second_runner = start_fair_runner(:replacement_fair_lane_runner, claim_timeout_ms: 1_000)
    second_drain = Task.async(fn -> BackgroundJobRunner.drain_once(second_runner) end)

    assert_receive {:fair_lane_started, second_handler, %BackgroundJob{id: ^job_id}}, 2_000
    assert second_handler != first_handler

    send(second_handler, {:release_fair_lane_job, job.id})
    assert {:ok, [{^job_id, {:ok, _result}}]} = Task.await(second_drain)

    first_handler_ref = Process.monitor(first_handler)
    Process.exit(first_handler, :kill)
    assert_receive {:DOWN, ^first_handler_ref, :process, ^first_handler, :killed}, 2_000

    completed = Repo.get!(BackgroundJob, job.id)
    assert completed.status == "completed"
    assert completed.claim_token == nil
  end

  defp enqueue!(name, partition_key, seconds_ago, rate_limit_key \\ nil, mode \\ "ok") do
    {:ok, job} =
      BackgroundJobs.enqueue("fair_test:#{name}", %{
        queue: "runtime_model_user",
        dedupe_key: "fair-test:#{name}",
        partition_key: partition_key,
        rate_limit_key: rate_limit_key,
        scheduled_at: DateTime.add(DateTime.utc_now(), seconds_ago, :second),
        payload: %{"mode" => mode}
      })

    job
  end

  defp start_fair_runner(name, overrides) do
    opts =
      [
        name: name,
        queues: ["runtime_model_user"],
        fair?: true,
        poll_interval_ms: :timer.hours(1),
        claim_timeout_ms: :timer.minutes(5),
        batch_size: 1,
        max_concurrency: 1,
        max_partition_concurrency: 1,
        max_rate_limit_concurrency: 4,
        reconcile_recurring_jobs?: false,
        handler: FairLaneTestHandler
      ]
      |> Keyword.merge(overrides)

    start_supervised!({BackgroundJobRunner, opts})
  end
end
