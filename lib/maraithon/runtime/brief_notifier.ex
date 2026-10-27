defmodule Maraithon.Runtime.BriefNotifier do
  @moduledoc """
  Dispatches one bounded batch of pending chief-of-staff briefs.

  Cadence and execution ownership live in `Maraithon.Runtime.RecurringJobs`
  and the durable background-job claim, not in a resident notifier process.
  """

  alias Maraithon.Briefs
  alias Maraithon.Runtime.Config

  require Logger

  def run_once do
    batch_size = Config.positive_integer(:brief_notify_batch_size, 10)
    result = Briefs.dispatch_pending_batch(batch_size: batch_size)

    if result.sent > 0 or result.failed > 0 do
      Logger.info("Brief notifier cycle",
        sent: result.sent,
        failed: result.failed,
        skipped: result.skipped
      )
    end

    result
  end
end
