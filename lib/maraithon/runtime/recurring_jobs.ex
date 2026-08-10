defmodule Maraithon.Runtime.RecurringJobs do
  @moduledoc """
  Durable schedules for short, stateless application maintenance cycles.

  A recurring cycle is one `background_jobs` row with a stable dedupe key.
  Successful execution moves that same claimed row back to `pending` at its
  next database-clock deadline. There is no scheduler PID whose mailbox or
  restart history is authoritative.

  `reconcile/0` repairs a missing schedule under a transaction-scoped
  PostgreSQL advisory lock. The lock elects authority for only that repair
  transaction; every execution remains claim-token fenced by
  `BackgroundJobRunner`.
  """

  alias Maraithon.AssistantChat.RunRecovery
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.BriefNotifier
  alias Maraithon.Runtime.BriefingCron
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.DbResilience
  alias Maraithon.Runtime.InsightNotifier
  alias Maraithon.TelegramAssistant.RunReaper

  @queue "runtime_recurring"
  @job_type_prefix "runtime_recurring:"
  @dedupe_prefix "runtime-recurring:"
  @authority_lock "maraithon:runtime-recurring-jobs:v1"

  @doc "Returns the currently configured durable recurring-job specifications."
  def specs do
    [
      spec(
        "insight_notifier",
        Config.positive_integer(:insight_notify_interval_ms, :timer.minutes(1)),
        Config.positive_integer(:insight_notify_initial_delay_ms, :timer.seconds(1))
      ),
      spec(
        "brief_notifier",
        Config.positive_integer(:brief_notify_interval_ms, :timer.minutes(1)),
        Config.positive_integer(:brief_notify_initial_delay_ms, :timer.seconds(2))
      ),
      spec(
        "briefing_cron",
        Config.positive_integer(:briefing_cron_interval_ms, :timer.minutes(1)),
        Config.positive_integer(:briefing_cron_initial_delay_ms, :timer.seconds(5))
      ),
      spec(
        "assistant_run_recovery",
        Config.positive_integer(:assistant_run_recovery_interval_ms, :timer.minutes(1)),
        Config.positive_integer(:assistant_run_recovery_initial_delay_ms, :timer.minutes(1))
      ),
      spec(
        "telegram_run_reaper",
        Config.positive_integer(:run_reaper_poll_interval_ms, :timer.minutes(1)),
        Config.positive_integer(:run_reaper_initial_delay_ms, :timer.minutes(1))
      )
    ]
  end

  @doc "Repairs missing durable schedules while holding transaction-scoped authority."
  def reconcile do
    case DbResilience.with_database("recurring background job reconcile", fn ->
           Repo.transaction(fn ->
             if take_advisory_authority!() do
               now = database_now!()

               jobs =
                 Enum.map(specs(), fn spec ->
                   case BackgroundJobs.enqueue(spec.job_type, %{
                          queue: @queue,
                          dedupe_key: spec.dedupe_key,
                          max_attempts: 3,
                          scheduled_at: DateTime.add(now, spec.initial_delay_ms, :millisecond),
                          payload: %{"recurring_job" => spec.name}
                        }) do
                     {:ok, %BackgroundJob{} = job} ->
                       %{name: spec.name, id: job.id, status: job.status}

                     {:error, reason} ->
                       Repo.rollback({:recurring_job_enqueue_failed, spec.name, reason})
                   end
                 end)

               %{authority: true, jobs: jobs}
             else
               %{authority: false, jobs: []}
             end
           end)
         end) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def execute(%BackgroundJob{job_type: job_type}) when is_binary(job_type) do
    case Enum.find(specs(), &(&1.job_type == job_type)) do
      nil ->
        {:error, {:unknown_recurring_job, job_type}}

      spec ->
        result = run_cycle(spec.name)
        {:ok, result, {:reschedule_in, spec.interval_ms}}
    end
  end

  @doc false
  def job_type(name) when is_binary(name), do: @job_type_prefix <> name

  @doc false
  def dedupe_key(name) when is_binary(name), do: @dedupe_prefix <> name

  @doc false
  def queue, do: @queue

  defp spec(name, interval_ms, initial_delay_ms) do
    %{
      name: name,
      job_type: job_type(name),
      dedupe_key: dedupe_key(name),
      interval_ms: interval_ms,
      initial_delay_ms: initial_delay_ms
    }
  end

  defp run_cycle("insight_notifier"), do: InsightNotifier.run_once()
  defp run_cycle("brief_notifier"), do: BriefNotifier.run_once()
  defp run_cycle("briefing_cron"), do: BriefingCron.run_once()
  defp run_cycle("assistant_run_recovery"), do: RunRecovery.run_once()
  defp run_cycle("telegram_run_reaper"), do: RunReaper.run_once()

  defp take_advisory_authority! do
    case Repo.query!(
           "SELECT pg_try_advisory_xact_lock(hashtextextended($1::text, 0))",
           [@authority_lock],
           log: false
         ).rows do
      [[true]] -> true
      _not_authoritative -> false
    end
  end

  defp database_now! do
    case Repo.query!("SELECT timezone('UTC', clock_timestamp())", [], log: false).rows do
      [[%NaiveDateTime{} = value]] -> DateTime.from_naive!(value, "Etc/UTC")
      [[%DateTime{} = value]] -> value
    end
  end
end
