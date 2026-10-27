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

    assert {:ok, goal_people_job} =
             BackgroundJobs.enqueue_goal_people_discovery(user_id,
               payload: %{"people_limit" => 250, "goal_limit" => 10}
             )

    assert {:ok, person_dedupe_job} =
             BackgroundJobs.enqueue_person_dedupe(user_id,
               payload: %{"people_limit" => 250, "max_merges" => 10}
             )

    assert email_job.queue == "email"
    assert relationship_job.queue == "relationships"
    assert open_loop_job.queue == "open_loops"
    assert goal_people_job.queue == "relationships"
    assert person_dedupe_job.queue == "relationships"
    assert goal_people_job.job_type == "goal_people_discovery"
    assert person_dedupe_job.job_type == "person_dedupe"
    assert email_job.dedupe_key == "background:email_processing:#{user_id}:thread-1"
    assert goal_people_job.dedupe_key == "#{user_id}:goal_people_discovery"
    assert person_dedupe_job.dedupe_key == "#{user_id}:person_dedupe"

    assert DateTime.compare(email_job.scheduled_at, DateTime.truncate(scheduled_at, :microsecond)) ==
             :eq

    jobs = BackgroundJobs.list(user_id: user_id, limit: 10)

    assert Enum.map(jobs, & &1.queue) |> Enum.sort() == [
             "email",
             "open_loops",
             "relationships",
             "relationships",
             "relationships"
           ]
  end

  test "source-account activity headers can be loaded by their exact sealed IDs", %{
    user_id: user_id
  } do
    {:ok, first} =
      BackgroundJobs.enqueue("runtime_partition:source_account_discovery", %{
        user_id: user_id,
        dedupe_key: "activity-exact:first:1",
        result: %{"source_replay_reference" => "exact-reference"}
      })

    {:ok, distractor} =
      BackgroundJobs.enqueue("runtime_partition:source_account_discovery", %{
        user_id: user_id,
        dedupe_key: "activity-exact:distractor:1"
      })

    {:ok, last} =
      BackgroundJobs.enqueue("runtime_partition:source_account_closure_acquire", %{
        user_id: user_id,
        dedupe_key: "activity-exact:last:1",
        result: %{"source_replay_reference" => "exact-reference"}
      })

    headers = BackgroundJobs.list_source_account_runs_by_ids(user_id, [first.id, last.id])

    assert headers |> Enum.map(& &1.id) |> MapSet.new() == MapSet.new([first.id, last.id])
    refute Enum.any?(headers, &(&1.id == distractor.id))
    assert Enum.all?(headers, &(&1.result["source_replay_reference"] == "exact-reference"))
    assert [] == BackgroundJobs.list_source_account_runs_by_ids("another@example.com", [first.id])
  end

  test "generic enqueue cannot bypass the dedicated Telegram receipt boundary" do
    attrs = %{
      telegram_bot_id: "123456",
      telegram_update_id: 8_999,
      payload: %{
        "event" => %{
          "type" => "message",
          "source" => "telegram",
          "data" => %{"text" => "unsanitized generic attempt"}
        }
      }
    }

    for job_type <- ["telegram_webhook_event", " telegram_webhook_event "] do
      assert {:error, :telegram_webhook_event_requires_dedicated_enqueue} =
               BackgroundJobs.enqueue(job_type, attrs)
    end

    refute Repo.exists?(
             from(job in BackgroundJob, where: job.job_type == "telegram_webhook_event")
           )

    event = %{
      type: "message",
      source: "telegram",
      data: %{text: "dedicated receipt"}
    }

    assert {:ok, first} =
             BackgroundJobs.enqueue_telegram_webhook_event("123456", 8_999, event)

    assert {:ok, replay} =
             BackgroundJobs.enqueue_telegram_webhook_event("123456", 8_999, event)

    assert replay.id == first.id
    assert first.dedupe_key == "telegram-webhook:123456:8999"
    assert first.telegram_bot_id == "123456"
    assert first.telegram_update_id == 8_999

    assert Repo.aggregate(
             from(job in BackgroundJob, where: job.job_type == "telegram_webhook_event"),
             :count,
             :id
           ) == 1
  end

  test "Telegram webhook dedupe is permanent across pending and terminal states" do
    for status <- BackgroundJob.statuses() do
      update_id = System.unique_integer([:positive])
      bot_id = "123456"

      assert {:ok, first} =
               BackgroundJobs.enqueue_telegram_webhook_event(bot_id, update_id, %{
                 type: "message",
                 source: "telegram",
                 data: %{text: "first"}
               })

      if status != "pending" do
        timestamps =
          case status do
            "running" -> %{claimed_at: DateTime.utc_now(), claimed_by: "test"}
            "completed" -> %{completed_at: DateTime.utc_now()}
            "failed" -> %{failed_at: DateTime.utc_now()}
            "cancelled" -> %{cancelled_at: DateTime.utc_now()}
          end

        first
        |> Ecto.Changeset.change(Map.merge(%{status: status}, timestamps))
        |> Repo.update!()
      end

      assert {:ok, duplicate} =
               BackgroundJobs.enqueue_telegram_webhook_event(bot_id, update_id, %{
                 type: "message",
                 source: "telegram",
                 data: %{text: "replay"}
               })

      assert duplicate.id == first.id
      assert duplicate.telegram_bot_id == bot_id
      assert duplicate.telegram_update_id == update_id

      assert Repo.aggregate(
               from(job in BackgroundJob,
                 where:
                   job.job_type == "telegram_webhook_event" and
                     job.dedupe_key == ^"telegram-webhook:#{bot_id}:#{update_id}"
               ),
               :count
             ) == 1
    end
  end

  test "Telegram webhook payload is raw-free, normalized, and redacted" do
    assert {:ok, job} =
             BackgroundJobs.enqueue_telegram_webhook_event("123456", 9_001, %{
               type: "unknown",
               raw: %{"sentinel" => "never-store"},
               data: %{
                 "raw" => %{"nested_sentinel" => "never-store-nested"},
                 "safe" => [%{raw: "drop", value: "keep"}],
                 "authorization" => "Bearer abcdefghijklmnopqrstuvwxyz0123456789",
                 "note" => "token=abcdefghijklmnopqrstuvwxyz0123456789"
               }
             })

    assert job.payload["event"]["type"] == "unknown"
    assert job.payload["event"]["data"]["safe"] == [%{"value" => "keep"}]
    assert job.payload["event"]["data"]["authorization"] == "<redacted>"
    assert job.payload["event"]["data"]["note"] == "token=<redacted>"
    refute inspect(job.payload) =~ "never-store"
    refute inspect(job.payload) =~ "abcdefghijklmnopqrstuvwxyz0123456789"
  end

  test "out-of-bounds Telegram events insert no receipts" do
    deep = Enum.reduce(1..18, "leaf", fn index, acc -> %{"level#{index}" => acc} end)

    events = [
      %{"type" => "message", "data" => %{"text" => String.duplicate("x", 64_001)}},
      %{"type" => "message", "data" => deep},
      %{"type" => "message", "data" => Enum.to_list(1..1_001)},
      %{:type => "message", "type" => "collision", "data" => %{}}
    ]

    for {event, index} <- Enum.with_index(events) do
      assert {:error, :telegram_webhook_event_out_of_bounds} =
               BackgroundJobs.enqueue_telegram_webhook_event("123456", 91_000 + index, event)
    end

    refute Repo.exists?(
             from(job in BackgroundJob, where: job.job_type == "telegram_webhook_event")
           )
  end

  test "ordinary terminal job dedupe keys remain reusable", %{user_id: user_id} do
    key = "background:test:terminal-reuse:#{user_id}"

    assert {:ok, first} =
             BackgroundJobs.enqueue("email_processing", %{
               user_id: user_id,
               dedupe_key: key
             })

    first
    |> Ecto.Changeset.change(%{status: "completed", completed_at: DateTime.utc_now()})
    |> Repo.update!()

    assert {:ok, second} =
             BackgroundJobs.enqueue("email_processing", %{
               user_id: user_id,
               dedupe_key: key
             })

    refute second.id == first.id
  end

  test "concurrent Telegram enqueue calls converge on one row" do
    owner = self()
    update_id = System.unique_integer([:positive])

    tasks =
      for _index <- 1..4 do
        Task.async(fn ->
          receive do
            :go ->
              BackgroundJobs.enqueue_telegram_webhook_event("123456", update_id, %{
                type: "message",
                source: "telegram",
                data: %{text: "same update"}
              })
          end
        end)
      end

    Enum.each(tasks, fn task ->
      Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, task.pid)
      send(task.pid, :go)
    end)

    ids =
      Enum.map(tasks, fn task ->
        assert {:ok, job} = Task.await(task)
        job.id
      end)

    assert ids |> Enum.uniq() |> length() == 1
  end
end
