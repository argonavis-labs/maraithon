defmodule Maraithon.Runtime.BackgroundJobsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobs

  setup do
    user_id = "background-jobs-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  test "enqueue persists a durable app-level job and dedupes active work", %{user_id: user_id} do
    assert {:ok, %BackgroundJob{} = job} =
             BackgroundJobs.enqueue("email_processing", %{
               user_id: user_id,
               payload: %{"reason" => "gmail_webhook"},
               dedupe_key: "background:test:email:#{user_id}"
             })

    assert job.queue == "email"
    assert job.job_type == "email_processing"
    assert job.status == "pending"
    assert job.payload == %{"reason" => "gmail_webhook"}

    assert {:ok, %BackgroundJob{id: duplicate_id}} =
             BackgroundJobs.enqueue("email_processing", %{
               user_id: user_id,
               payload: %{"reason" => "second_enqueue"},
               dedupe_key: "background:test:email:#{user_id}"
             })

    assert duplicate_id == job.id

    assert %{"pending" => 1} = BackgroundJobs.count_by_status(user_id: user_id)
  end

  test "typed helpers route common chief-of-staff work to separate queues", %{user_id: user_id} do
    scheduled_at = DateTime.add(DateTime.utc_now(), 15, :minute)

    assert {:ok, email_job} =
             BackgroundJobs.enqueue_email_processing(user_id, %{
               payload: %{"source_item_id" => "thread-1"},
               scheduled_at: scheduled_at
             })

    assert {:ok, relationship_job} =
             BackgroundJobs.enqueue_relationship_learning(user_id, [
               %{"source" => "gmail", "title" => "Charlie asked for the deck"}
             ])

    assert {:ok, open_loop_job} =
             BackgroundJobs.enqueue_open_loop_check(user_id, %{payload: %{"query" => "Charlie"}})

    assert email_job.queue == "email"
    assert relationship_job.queue == "relationships"
    assert open_loop_job.queue == "open_loops"
    assert email_job.dedupe_key == "background:email_processing:#{user_id}:thread-1"

    assert DateTime.compare(email_job.scheduled_at, DateTime.truncate(scheduled_at, :microsecond)) ==
             :eq

    jobs = BackgroundJobs.list(user_id: user_id, limit: 10)
    assert Enum.map(jobs, & &1.queue) |> Enum.sort() == ["email", "open_loops", "relationships"]
  end
end
