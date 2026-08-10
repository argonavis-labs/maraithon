defmodule Maraithon.Runtime.InsightNotifier do
  @moduledoc """
  Dispatches one bounded batch of pending Telegram insight notifications.

  Cadence and execution ownership live in `Maraithon.Runtime.RecurringJobs`
  and the durable background-job claim, not in a resident notifier process.
  """

  alias Maraithon.InsightNotifications
  alias Maraithon.Runtime.Config

  require Logger

  def run_once do
    batch_size = Config.positive_integer(:insight_notify_batch_size, 20)
    result = InsightNotifications.dispatch_telegram_batch(batch_size: batch_size)

    if result.staged > 0 or result.sent > 0 or result.failed > 0 do
      Logger.info("Insight notifier cycle",
        staged: result.staged,
        sent: result.sent,
        failed: result.failed
      )
    end

    result
  end
end
