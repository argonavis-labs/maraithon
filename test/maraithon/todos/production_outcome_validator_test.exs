defmodule Maraithon.Todos.ProductionOutcomeValidatorTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts.User
  alias Maraithon.Repo
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobRunner}
  alias Maraithon.Todos.ProductionOutcomeValidator

  test "validates the real durable model queue and removes synthetic data" do
    Repo.delete_all(
      from(job in BackgroundJob,
        where: job.queue == "runtime_model_user" and job.status in ["pending", "running"]
      )
    )

    validation_users_before = validation_user_count()

    start_supervised!(
      {BackgroundJobRunner,
       name: :todo_outcome_validation_test_runner,
       queues: ["runtime_model_user"],
       poll_interval_ms: 10,
       batch_size: 5,
       max_concurrency: 1,
       max_partition_concurrency: 1,
       max_rate_limit_concurrency: 1,
       reconcile_recurring_jobs?: false}
    )

    assert {:ok, report} = ProductionOutcomeValidator.run()
    assert report.isolated_user
    assert report.outcome == "bad"
    assert report.event_status == "processed"
    assert report.event_attempts == 1
    assert report.learning_operation == "noop"
    refute report.memory_written
    assert report.queue == "runtime_model_user"
    assert report.job_status == "completed"
    assert report.job_attempts == 0
    assert validation_user_count() == validation_users_before
  end

  defp validation_user_count do
    Repo.aggregate(
      from(user in User,
        where: like(user.id, "todo-outcome-validation-%@validation.maraithon.invalid")
      ),
      :count,
      :id
    )
  end
end
