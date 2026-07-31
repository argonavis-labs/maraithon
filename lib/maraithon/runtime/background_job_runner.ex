defmodule Maraithon.Runtime.BackgroundJobRunner do
  @moduledoc """
  Polls and executes app-level background jobs.

  This is intentionally separate from the agent wakeup scheduler and effect
  runner. It handles user-scoped application work that can be retried and
  observed without blocking request-handling processes.
  """

  use GenServer

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobHandler
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DbResilience

  require Logger

  @default_poll_interval_ms 1_000
  @default_claim_timeout_ms 300_000
  @default_batch_size 10
  @default_max_concurrency 5
  # A `{:retry_after, seconds, reason}` error (e.g. HTTP 429 + Retry-After)
  # reschedules without burning an attempt, so it needs its own ceiling and
  # cap independent of `attempts`/`max_attempts` — otherwise a persistent
  # 429 (or an absurd Retry-After header) reschedules a job forever.
  @max_retry_after_delay_seconds 3_600
  @max_retry_after_reschedules 20

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def drain_once(server \\ __MODULE__) do
    GenServer.call(server, :drain_once, :infinity)
  end

  @impl true
  def init(opts) do
    poll_interval_ms =
      Keyword.get(
        opts,
        :poll_interval_ms,
        RuntimeConfig.positive_integer(
          :background_job_poll_interval_ms,
          @default_poll_interval_ms
        )
      )

    claim_timeout_ms =
      Keyword.get(
        opts,
        :claim_timeout_ms,
        RuntimeConfig.positive_integer(
          :background_job_claim_timeout_ms,
          @default_claim_timeout_ms
        )
      )

    batch_size =
      Keyword.get(
        opts,
        :batch_size,
        RuntimeConfig.positive_integer(:background_job_batch_size, @default_batch_size)
      )

    max_concurrency =
      Keyword.get(
        opts,
        :max_concurrency,
        RuntimeConfig.positive_integer(
          :background_job_max_concurrency,
          @default_max_concurrency
        )
      )

    schedule_poll(poll_interval_ms)

    {:ok,
     %{
       running: %{},
       monitors: %{},
       poll_interval_ms: poll_interval_ms,
       claim_timeout_ms: claim_timeout_ms,
       batch_size: batch_size,
       max_concurrency: max_concurrency,
       poll_retry_attempts: 0,
       handler: Keyword.get(opts, :handler, handler_module())
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    available_slots = max(state.max_concurrency - map_size(state.running), 0)

    if available_slots == 0 do
      schedule_poll(state.poll_interval_ms)
      {:noreply, state}
    else
      limit = min(state.batch_size, available_slots)

      case DbResilience.with_database("background job runner poll", fn ->
             reclaim_stale_jobs(state.claim_timeout_ms)
             fetch_pending_jobs(limit)
           end) do
        {:ok, jobs} ->
          state =
            Enum.reduce(jobs, state, fn job, acc ->
              case claim_job(job) do
                {:ok, claimed} ->
                  ref = execute_job_async(claimed, state.handler)

                  %{
                    acc
                    | running: Map.put(acc.running, claimed.id, claimed),
                      monitors: Map.put(acc.monitors, ref, claimed.id)
                  }

                :already_claimed ->
                  acc

                {:error, _reason} ->
                  acc
              end
            end)

          schedule_poll(state.poll_interval_ms)
          {:noreply, %{state | poll_retry_attempts: 0}}

        {:error, _reason} ->
          retry_in_ms = DbResilience.backoff_ms(state.poll_interval_ms, state.poll_retry_attempts)
          schedule_poll(retry_in_ms)
          {:noreply, %{state | poll_retry_attempts: state.poll_retry_attempts + 1}}
      end
    end
  end

  @impl true
  def handle_info({:background_job_done, job_id, _result}, state) do
    monitors =
      case Enum.find(state.monitors, fn {_ref, id} -> id == job_id end) do
        {ref, _id} ->
          Process.demonitor(ref, [:flush])
          Map.delete(state.monitors, ref)

        nil ->
          state.monitors
      end

    {:noreply, %{state | running: Map.delete(state.running, job_id), monitors: monitors}}
  end

  # Task.Supervisor.async_nolink reply for a task whose :background_job_done
  # message already cleaned up.
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}
  end

  # A job task died before reporting back (kill, OOM). Without this, the
  # `running` entry leaked and permanently consumed a concurrency slot.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {job_id, monitors} ->
        {job, running} = Map.pop(state.running, job_id)

        if job && reason != :normal do
          Logger.error("Background job task crashed for job #{job_id}: #{inspect(reason)}")
          release_crashed_job(job, reason)
        end

        {:noreply, %{state | running: running, monitors: monitors}}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("BackgroundJobRunner ignoring unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear_running, _from, state) do
    Enum.each(state.monitors, fn {ref, _id} -> Process.demonitor(ref, [:flush]) end)
    {:reply, :ok, %{state | running: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call(:drain_once, _from, state) do
    limit = max(state.batch_size, 1)

    result =
      DbResilience.with_database("background job runner drain once", fn ->
        reclaim_stale_jobs(state.claim_timeout_ms)

        limit
        |> fetch_pending_jobs()
        |> Enum.map(fn job ->
          case claim_job(job) do
            {:ok, claimed} -> {claimed.id, execute_job(claimed, state.handler)}
            other -> {job.id, other}
          end
        end)
      end)

    {:reply, result, state}
  end

  defp fetch_pending_jobs(limit) do
    now = DateTime.utc_now()

    BackgroundJob
    |> where([job], job.status == "pending")
    |> where([job], job.scheduled_at <= ^now)
    |> order_by([job], asc: job.scheduled_at, asc: job.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp claim_job(%BackgroundJob{} = job) do
    node_id = node() |> to_string()
    now = DateTime.utc_now()

    case DbResilience.with_database("background job runner claim job", fn ->
           Repo.update_all(
             from(candidate in BackgroundJob,
               where: candidate.id == ^job.id,
               where: candidate.status == "pending"
             ),
             set: [
               status: "running",
               claimed_by: node_id,
               claimed_at: now,
               updated_at: now
             ]
           )
         end) do
      {:ok, {1, _}} ->
        DbResilience.with_database("background job runner load claimed job", fn ->
          Repo.get!(BackgroundJob, job.id)
        end)

      {:ok, {0, _}} ->
        :already_claimed

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_job_async(%BackgroundJob{} = job, handler) do
    parent = self()

    %Task{ref: ref} =
      Task.Supervisor.async_nolink(Maraithon.Runtime.BackgroundJobTaskSupervisor, fn ->
        result = execute_job(job, handler)
        send(parent, {:background_job_done, job.id, result})
        :ok
      end)

    ref
  end

  defp release_crashed_job(%BackgroundJob{} = job, reason) do
    attempts = job.attempts + 1
    error = {:job_task_crashed, reason}

    if attempts < job.max_attempts do
      mark_pending_retry(job, error, attempts)
    else
      mark_failed(job, error, attempts)
    end
  end

  defp execute_job(%BackgroundJob{} = job, handler) do
    Logger.info("Executing background job",
      background_job_id: job.id,
      queue: job.queue,
      job_type: job.job_type,
      user_id: job.user_id
    )

    result = safe_execute(handler, job)

    case result do
      {:ok, data} ->
        mark_completed(job, data)

      {:error, {:retry_after, seconds, reason}} when is_integer(seconds) and seconds >= 0 ->
        # Provider-signaled backoff (e.g. HTTP 429 + Retry-After): reschedule
        # at the requested delay without burning an attempt.
        handle_retry_after(job, seconds, reason)

      {:error, reason} ->
        attempts = job.attempts + 1

        if attempts < job.max_attempts do
          mark_pending_retry(job, reason, attempts)
        else
          mark_failed(job, reason, attempts)
        end
    end

    result
  end

  defp mark_completed(%BackgroundJob{} = job, result) do
    now = DateTime.utc_now()

    DbResilience.with_database("background job runner mark completed", fn ->
      Repo.update_all(
        from(candidate in BackgroundJob, where: candidate.id == ^job.id),
        set: [
          status: "completed",
          result: normalize_result(result),
          completed_at: now,
          claimed_by: nil,
          claimed_at: nil,
          last_error: nil,
          updated_at: now
        ]
      )
    end)
  end

  # Clamps the provider-requested delay to `@max_retry_after_delay_seconds`
  # and counts the reschedule against `@max_retry_after_reschedules`
  # (tracked in `job.result["retry_after_count"]`, since `attempts` is
  # deliberately not burned for this path). Once a job has rescheduled on
  # `:retry_after` this many times without making progress, fall through to
  # the ordinary attempt/backoff machinery so it eventually fails out rather
  # than rescheduling forever.
  defp handle_retry_after(%BackgroundJob{} = job, seconds, reason) do
    retry_after_count = retry_after_count(job) + 1

    if retry_after_count > @max_retry_after_reschedules do
      attempts = job.attempts + 1

      if attempts < job.max_attempts do
        mark_pending_retry(job, reason, attempts)
      else
        mark_failed(job, reason, attempts)
      end
    else
      clamped_seconds = min(seconds, @max_retry_after_delay_seconds)
      retry_at = DateTime.add(DateTime.utc_now(), clamped_seconds, :second)
      mark_pending_rate_limited_retry(job, reason, retry_at, retry_after_count)
    end
  end

  defp retry_after_count(%BackgroundJob{result: %{"retry_after_count" => count}})
       when is_integer(count) do
    count
  end

  defp retry_after_count(_job), do: 0

  defp mark_pending_rate_limited_retry(
         %BackgroundJob{} = job,
         reason,
         %DateTime{} = retry_at,
         retry_after_count
       ) do
    now = DateTime.utc_now()

    DbResilience.with_database("background job runner mark rate-limited retry", fn ->
      Repo.update_all(
        from(candidate in BackgroundJob, where: candidate.id == ^job.id),
        set: [
          status: "pending",
          scheduled_at: retry_at,
          claimed_by: nil,
          claimed_at: nil,
          last_error: error_text(reason),
          result: Map.put(job.result || %{}, "retry_after_count", retry_after_count),
          updated_at: now
        ]
      )
    end)
  end

  defp mark_pending_retry(%BackgroundJob{} = job, reason, attempts) do
    backoff_ms = calculate_backoff(attempts)
    retry_at = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)
    mark_pending_retry(job, reason, attempts, retry_at)
  end

  defp mark_pending_retry(%BackgroundJob{} = job, reason, attempts, %DateTime{} = retry_at) do
    now = DateTime.utc_now()

    DbResilience.with_database("background job runner mark retry", fn ->
      Repo.update_all(
        from(candidate in BackgroundJob, where: candidate.id == ^job.id),
        set: [
          status: "pending",
          attempts: attempts,
          scheduled_at: retry_at,
          claimed_by: nil,
          claimed_at: nil,
          last_error: error_text(reason),
          updated_at: now
        ]
      )
    end)
  end

  defp mark_failed(%BackgroundJob{} = job, reason, attempts) do
    now = DateTime.utc_now()

    DbResilience.with_database("background job runner mark failed", fn ->
      Repo.update_all(
        from(candidate in BackgroundJob, where: candidate.id == ^job.id),
        set: [
          status: "failed",
          attempts: attempts,
          failed_at: now,
          claimed_by: nil,
          claimed_at: nil,
          last_error: error_text(reason),
          updated_at: now
        ]
      )
    end)
  end

  defp reclaim_stale_jobs(claim_timeout_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -claim_timeout_ms, :millisecond)
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(job in BackgroundJob,
          where: job.status == "running",
          where: job.claimed_at < ^cutoff
        ),
        set: [status: "pending", claimed_by: nil, claimed_at: nil, updated_at: now]
      )

    if count > 0 do
      Logger.info("Reclaimed stale background jobs", count: count)
    end

    sweep_stale_ingest_windows(now)
  end

  defp sweep_stale_ingest_windows(now) do
    case Maraithon.Crm.Ingest.sweep_stale_windows(now) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("Force-flushed stale CRM ingest windows", count: count)
    end
  rescue
    exception ->
      Logger.warning(
        "CRM ingest window sweep failed: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )
  catch
    kind, reason ->
      Logger.warning("CRM ingest window sweep crashed: #{kind} #{inspect(reason)}")
  end

  defp calculate_backoff(attempts) when is_integer(attempts) and attempts > 0 do
    min(:timer.seconds(30) * round(:math.pow(2, attempts - 1)), :timer.minutes(15))
  end

  defp schedule_poll(ms), do: Process.send_after(self(), :poll, ms)

  defp safe_execute(handler, %BackgroundJob{} = job) do
    handler.execute(job)
  rescue
    exception ->
      {:error, Exception.format(:error, exception, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp handler_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:handler, BackgroundJobHandler)
  end

  defp normalize_result(value) when is_map(value), do: stringify_keys(value)
  defp normalize_result(value), do: %{"value" => inspect(value)}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_value(value)}
      {key, value} when is_binary(key) -> {key, normalize_value(value)}
      {key, value} -> {to_string(key), normalize_value(value)}
    end)
  end

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)
end
