defmodule Maraithon.Runtime.BackgroundJobHandlerTelegramTest do
  use ExUnit.Case, async: true

  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobHandler

  test "executes normalized Telegram no-op events through the durable handler" do
    job = %BackgroundJob{
      job_type: "telegram_webhook_event",
      payload: %{
        "event" => %{
          "type" => "ignored_update",
          "source" => "telegram",
          "data" => %{}
        }
      }
    }

    assert {:ok, %{source: "telegram_webhook", processed: true}} =
             BackgroundJobHandler.execute(job)
  end

  test "rejects missing Telegram event payloads" do
    assert {:error, :invalid_telegram_webhook_payload} =
             BackgroundJobHandler.execute(%BackgroundJob{
               job_type: "telegram_webhook_event",
               payload: %{}
             })
  end
end
