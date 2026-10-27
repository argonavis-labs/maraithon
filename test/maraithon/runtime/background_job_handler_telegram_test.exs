defmodule Maraithon.Runtime.BackgroundJobHandlerTelegramTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobHandler
  alias Maraithon.Runtime.BackgroundJobRunner
  alias Maraithon.Runtime.BackgroundJobs

  setup do
    original_insights = Application.get_env(:maraithon, :insights, [])
    original_failure = Application.get_env(:maraithon, :failing_telegram)

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)

      if original_failure,
        do: Application.put_env(:maraithon, :failing_telegram, original_failure),
        else: Application.delete_env(:maraithon, :failing_telegram)
    end)

    :ok
  end

  test "ignored events complete with an explicit noop outcome" do
    job =
      telegram_job(%{
        "type" => "ignored_update",
        "source" => "telegram",
        "data" => %{}
      })

    assert {:ok,
            %{
              source: "telegram_webhook",
              outcome: "noop",
              reason: "ignored_update"
            }} = BackgroundJobHandler.execute(job)
  end

  test "malformed durable events are retryable errors" do
    job = telegram_job(%{"type" => "unexpected", "source" => "telegram", "data" => %{}})

    assert {:error, {:telegram_event_processing_failed, :invalid_telegram_event}} =
             BackgroundJobHandler.execute(job)
  end

  test "Telegram send failure is not a processed tombstone" do
    reason = {:telegram_error, 503, "provider unavailable"}
    use_failing_telegram(reason)

    job =
      telegram_job(%{
        "type" => "message",
        "source" => "telegram",
        "data" => %{"chat_id" => 501, "message_id" => 1, "text" => "/start"}
      })

    assert {:error, {:telegram_event_processing_failed, {:telegram_send_failed, ^reason}}} =
             BackgroundJobHandler.execute(job)
  end

  test "runner retries send failure and retains the sanitized event payload" do
    reason = {:telegram_error, 503, "provider unavailable"}
    use_failing_telegram(reason)

    event = %{
      type: "message",
      source: "telegram",
      data: %{chat_id: 502, message_id: 2, text: "/start"}
    }

    assert {:ok, job} = BackgroundJobs.enqueue_telegram_webhook_event("778899", 5_001, event)

    runner =
      start_supervised!(
        {BackgroundJobRunner,
         [
           name: :background_job_handler_telegram_send_failure_runner,
           handler: BackgroundJobHandler,
           poll_interval_ms: 60_000,
           batch_size: 1,
           max_concurrency: 1
         ]}
      )

    job_id = job.id

    assert {:ok,
            [
              {^job_id,
               {:error, {:telegram_event_processing_failed, {:telegram_send_failed, ^reason}}}}
            ]} = BackgroundJobRunner.drain_once(runner)

    stored = Repo.get!(BackgroundJob, job.id)
    assert stored.status == "pending"
    assert stored.attempts == 1
    assert stored.payload["event"]["data"]["text"] == "/start"
  end

  test "edit-not-found completes as noop" do
    job =
      telegram_job(%{
        "type" => "edited_message",
        "source" => "telegram",
        "data" => %{"chat_id" => 503, "message_id" => 3, "text" => "edited"}
      })

    assert {:ok,
            %{
              source: "telegram_webhook",
              outcome: "noop",
              reason: "turn_not_found"
            }} = BackgroundJobHandler.execute(job)
  end

  test "rejects missing Telegram event payloads" do
    assert {:error, :invalid_telegram_webhook_payload} =
             BackgroundJobHandler.execute(%BackgroundJob{
               job_type: "telegram_webhook_event",
               payload: %{}
             })
  end

  defp telegram_job(event) do
    %BackgroundJob{job_type: "telegram_webhook_event", payload: %{"event" => event}}
  end

  defp use_failing_telegram(reason) do
    Application.put_env(:maraithon, :insights,
      telegram_module: Maraithon.TestSupport.FailingTelegram
    )

    Application.put_env(:maraithon, :failing_telegram, reason: reason)
  end
end
