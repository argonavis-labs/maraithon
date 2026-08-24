defmodule Maraithon.Runtime.PeriodicJobs do
  @moduledoc """
  Durable discovery and partition execution for periodic provider/model work.

  Recurring coordinator rows only discover bounded work. Provider calls run as
  one account partition in `runtime_provider_account`; user/model calls run as
  one tenant partition in `runtime_model_user`. The lane runner, PostgreSQL
  partition watermarks, claim tokens, and durable cooldown rows are authority.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.SourceCursor
  alias Maraithon.OAuth.Token
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.FreshnessSweep
  alias Maraithon.Runtime.NudgeSweep
  alias Maraithon.Runtime.ProactiveCheckIn
  alias Maraithon.Runtime.StalenessTriageSweep
  alias Maraithon.Runtime.TodoCompletionSweep
  alias Maraithon.Runtime.TokenRefresher
  alias Maraithon.Runtime.WatchRenewer
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.Todos.{OutcomeLearning, UserBatch}

  @provider_queue "runtime_provider_account"
  @model_queue "runtime_model_user"
  @active_statuses ~w(pending running)
  @default_retry_after_seconds 30

  @token_job "runtime_partition:token_refresh"
  @watch_job "runtime_partition:watch_renewal"
  @freshness_account_job "runtime_partition:freshness_account"
  @freshness_watch_job "runtime_partition:freshness_watch"
  @telegram_heal_job "runtime_partition:telegram_heal"
  @proactive_job "runtime_partition:proactive_check_in"
  @todo_completion_job "runtime_partition:todo_completion"
  @nudge_job "runtime_partition:nudge"
  @staleness_job "runtime_partition:staleness_triage"
  @todo_outcome_job "runtime_partition:todo_outcome_learning"

  def provider_queue, do: @provider_queue
  def model_queue, do: @model_queue

  @doc "Runs one bounded recurring discovery coordinator."
  def schedule("token_refresher"), do: schedule_token_refreshes()
  def schedule("watch_renewer"), do: schedule_watch_renewals()
  def schedule("freshness_sweep"), do: schedule_freshness_checks()
  def schedule("proactive_check_in"), do: schedule_proactive_users()
  def schedule("todo_completion_sweep"), do: schedule_open_todo_users("todo_completion_sweep")
  def schedule("nudge_sweep"), do: schedule_nudge_users()
  def schedule("staleness_triage_sweep"), do: schedule_open_todo_users("staleness_triage_sweep")
  def schedule(name), do: {:error, {:unknown_periodic_schedule, name}}

  @doc "Executes one claimed provider/model partition row."
  def execute(%BackgroundJob{queue: @provider_queue} = job), do: execute_provider(job)
  def execute(%BackgroundJob{queue: @model_queue} = job), do: execute_model(job)
  def execute(%BackgroundJob{} = job), do: {:error, {:invalid_periodic_lane, job.queue}}

  defp schedule_token_refreshes do
    now = database_now!()
    lookahead = Config.positive_integer(:oauth_refresh_lookahead_seconds, 15 * 60)
    batch_size = Config.positive_integer(:oauth_refresh_batch_size, 100)
    cutoff = DateTime.add(now, lookahead, :second)

    tokens =
      Token
      |> join(:left, [token], job in BackgroundJob,
        on:
          job.dedupe_key == fragment("'runtime-partition:token:' || ?::text", token.id) and
            job.status in @active_statuses
      )
      |> where([token, job], is_nil(job.id))
      |> where([token, _job], not is_nil(token.refresh_token))
      |> where([token, _job], not is_nil(token.expires_at) and token.expires_at <= ^cutoff)
      |> order_by([token, _job], asc: token.expires_at, asc: token.id)
      |> limit(^batch_size)
      |> Repo.all()
      |> Enum.filter(&TokenRefresher.refresh_supported_provider?(&1.provider))

    enqueue_many(tokens, fn token ->
      BackgroundJobs.enqueue(@token_job, %{
        user_id: token.user_id,
        queue: @provider_queue,
        dedupe_key: "runtime-partition:token:#{token.id}",
        partition_key: provider_partition(token.user_id, token.provider),
        rate_limit_key: TokenRefresher.provider_family(token.provider),
        max_attempts: 5,
        scheduled_at: now,
        payload: %{"token_id" => token.id, "lookahead_seconds" => lookahead}
      })
    end)
    |> schedule_summary("token_refresher", length(tokens))
  end

  defp schedule_watch_renewals do
    now = database_now!()
    lookahead = Config.positive_integer(:watch_renewal_lookahead_seconds, 24 * 60 * 60)
    batch_size = Config.positive_integer(:watch_renewal_batch_size, 50)
    cutoff = DateTime.add(now, lookahead, :second)

    cursors =
      SourceCursor
      |> join(:left, [cursor], job in BackgroundJob,
        on:
          job.dedupe_key == fragment("'runtime-partition:watch:' || ?::text", cursor.id) and
            job.status in @active_statuses
      )
      |> where([cursor, job], is_nil(job.id))
      |> where([cursor, _job], not is_nil(cursor.watch_expires_at))
      |> where([cursor, _job], cursor.watch_expires_at <= ^cutoff)
      |> order_by([cursor, _job], asc: cursor.watch_expires_at, asc: cursor.id)
      |> limit(^batch_size)
      |> Repo.all()

    enqueue_many(cursors, fn cursor ->
      BackgroundJobs.enqueue(@watch_job, %{
        user_id: cursor.user_id,
        queue: @provider_queue,
        dedupe_key: "runtime-partition:watch:#{cursor.id}",
        partition_key: provider_partition(cursor.user_id, cursor.provider),
        rate_limit_key: TokenRefresher.provider_family(cursor.provider),
        max_attempts: 5,
        scheduled_at: now,
        payload: %{"cursor_id" => cursor.id, "lookahead_seconds" => lookahead}
      })
    end)
    |> schedule_summary("watch_renewer", length(cursors))
  end

  defp schedule_freshness_checks do
    now = database_now!()
    batch_size = Config.positive_integer(:freshness_sweep_batch_size, 500)

    accounts = freshness_accounts(batch_size)
    expired_watches = expired_watch_cursors(now, batch_size)
    telegram_accounts = soft_flagged_telegram_accounts(batch_size)

    with {:ok, account_count} <-
           enqueue_many(accounts, fn account ->
             BackgroundJobs.enqueue(@freshness_account_job, %{
               user_id: account.user_id,
               queue: @provider_queue,
               dedupe_key: "runtime-partition:freshness-account:#{account.id}",
               partition_key: provider_partition(account.user_id, account.provider),
               rate_limit_key: TokenRefresher.provider_family(account.provider),
               scheduled_at: now,
               payload: %{"account_id" => account.id}
             })
           end),
         {:ok, watch_count} <-
           enqueue_many(expired_watches, fn cursor ->
             BackgroundJobs.enqueue(@freshness_watch_job, %{
               user_id: cursor.user_id,
               queue: @provider_queue,
               dedupe_key: "runtime-partition:freshness-watch:#{cursor.id}",
               partition_key: provider_partition(cursor.user_id, cursor.provider),
               rate_limit_key: TokenRefresher.provider_family(cursor.provider),
               scheduled_at: now,
               payload: %{"cursor_id" => cursor.id}
             })
           end),
         {:ok, heal_count} <-
           enqueue_many(telegram_accounts, fn account ->
             BackgroundJobs.enqueue(@telegram_heal_job, %{
               user_id: account.user_id,
               queue: @provider_queue,
               dedupe_key: "runtime-partition:telegram-heal:#{account.id}",
               partition_key: provider_partition(account.user_id, account.provider),
               rate_limit_key: "telegram",
               scheduled_at: now,
               payload: %{"account_id" => account.id}
             })
           end) do
      {:ok,
       %{
         schedule: "freshness_sweep",
         discovered: length(accounts) + length(expired_watches) + length(telegram_accounts),
         enqueued: account_count + watch_count + heal_count
       }}
    end
  end

  defp freshness_accounts(limit) do
    ConnectedAccount
    |> join(:left, [account], job in BackgroundJob,
      on:
        job.dedupe_key ==
          fragment("'runtime-partition:freshness-account:' || ?::text", account.id) and
          job.status in @active_statuses
    )
    |> where([account, job], account.status == "connected" and is_nil(job.id))
    |> order_by([account, _job], asc_nulls_first: account.last_refreshed_at, asc: account.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp expired_watch_cursors(now, limit) do
    SourceCursor
    |> join(:left, [cursor], job in BackgroundJob,
      on:
        job.dedupe_key ==
          fragment("'runtime-partition:freshness-watch:' || ?::text", cursor.id) and
          job.status in @active_statuses
    )
    |> where([cursor, job], is_nil(job.id))
    |> where([cursor, _job], not is_nil(cursor.watch_expires_at))
    |> where([cursor, _job], cursor.watch_expires_at < ^now)
    |> order_by([cursor, _job], asc: cursor.watch_expires_at, asc: cursor.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp soft_flagged_telegram_accounts(limit) do
    reasons = Maraithon.ConnectedAccounts.soft_reconnect_reasons()

    ConnectedAccount
    |> join(:left, [account], job in BackgroundJob,
      on:
        job.dedupe_key ==
          fragment("'runtime-partition:telegram-heal:' || ?::text", account.id) and
          job.status in @active_statuses
    )
    |> where(
      [account, job],
      account.provider == "telegram" and account.status == "error" and is_nil(job.id)
    )
    |> where(
      [account, _job],
      fragment("?->'last_error'->>'reason'", account.metadata) in ^reasons
    )
    |> order_by([account, _job], asc_nulls_first: account.last_refreshed_at, asc: account.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp schedule_proactive_users do
    now = database_now!()
    hygiene = ProactiveCheckIn.run_hygiene(now)
    batch_size = Config.positive_integer(:proactive_check_in_batch_size, 25)
    active_users = active_user_ids(@proactive_job)

    users =
      ProactiveQueue.pending_deliverable_user_ids(
        limit: batch_size,
        now: now,
        exclude_user_ids: active_users
      )

    enqueue_model_users("proactive_check_in", @proactive_job, users, now, hygiene)
  end

  defp schedule_nudge_users do
    cursor_key = "durable_nudge_sweep"
    cursor = UserBatch.load_cursor(cursor_key)
    now = database_now!()
    users = NudgeSweep.due_user_ids(after_user_id: cursor, now: now)

    enqueue_model_users("nudge_sweep", @nudge_job, users, now)
    |> record_cursor_after(cursor_key, users)
  end

  defp schedule_open_todo_users(schedule) do
    {cursor_key, job_type} =
      case schedule do
        "todo_completion_sweep" -> {"durable_todo_completion_sweep", @todo_completion_job}
        "staleness_triage_sweep" -> {"durable_staleness_triage_sweep", @staleness_job}
      end

    cursor = UserBatch.load_cursor(cursor_key)
    users = UserBatch.open_todo_user_ids(after_user_id: cursor)
    now = database_now!()

    enqueue_model_users(schedule, job_type, users, now)
    |> record_cursor_after(cursor_key, users)
  end

  defp enqueue_model_users(schedule, job_type, users, now, extra \\ %{}) do
    case enqueue_many(users, fn user_id ->
           BackgroundJobs.enqueue(job_type, %{
             user_id: user_id,
             queue: @model_queue,
             dedupe_key: model_dedupe_key(schedule, user_id),
             partition_key: tenant_partition(user_id),
             rate_limit_key: "model",
             max_attempts: 3,
             scheduled_at: now,
             payload: %{"user_id" => user_id}
           })
         end) do
      {:ok, count} ->
        {:ok,
         Map.merge(
           %{schedule: schedule, discovered: length(users), enqueued: count},
           extra
         )}

      {:error, _reason} = error ->
        error
    end
  end

  defp record_cursor_after({:ok, _summary} = result, cursor_key, users) do
    case List.last(users) do
      user_id when is_binary(user_id) ->
        case UserBatch.record_cursor(cursor_key, user_id) do
          :ok -> result
          :error -> {:error, {:cursor_record_failed, cursor_key}}
        end

      _none ->
        result
    end
  end

  defp record_cursor_after(error, _cursor_key, _users), do: error

  defp active_user_ids(job_type) do
    BackgroundJob
    |> where([job], job.job_type == ^job_type and job.status in @active_statuses)
    |> where([job], not is_nil(job.user_id))
    |> select([job], job.user_id)
    |> limit(1_000)
    |> Repo.all()
  end

  defp execute_provider(%BackgroundJob{job_type: @token_job} = job) do
    with {:ok, token_id} <- payload_integer(job, "token_id") do
      TokenRefresher.run_token(token_id,
        lookahead_seconds: payload_integer_value(job, "lookahead_seconds", 15 * 60)
      )
      |> normalize_work_result()
    end
  end

  defp execute_provider(%BackgroundJob{job_type: @watch_job} = job) do
    with {:ok, cursor_id} <- payload_string(job, "cursor_id") do
      WatchRenewer.run_cursor(cursor_id,
        lookahead_seconds: payload_integer_value(job, "lookahead_seconds", 24 * 60 * 60),
        now: database_now!()
      )
      |> normalize_work_result()
    end
  end

  defp execute_provider(%BackgroundJob{job_type: @freshness_account_job} = job) do
    with {:ok, account_id} <- payload_integer(job, "account_id") do
      FreshnessSweep.run_account(account_id, now: database_now!()) |> normalize_work_result()
    end
  end

  defp execute_provider(%BackgroundJob{job_type: @freshness_watch_job} = job) do
    with {:ok, cursor_id} <- payload_string(job, "cursor_id") do
      FreshnessSweep.run_expired_watch(cursor_id, now: database_now!())
      |> normalize_work_result()
    end
  end

  defp execute_provider(%BackgroundJob{job_type: @telegram_heal_job} = job) do
    with {:ok, account_id} <- payload_integer(job, "account_id") do
      FreshnessSweep.run_telegram_heal(account_id) |> normalize_work_result()
    end
  end

  defp execute_provider(%BackgroundJob{} = job),
    do: {:error, {:unknown_provider_partition, job.job_type}}

  defp execute_model(%BackgroundJob{job_type: @proactive_job} = job) do
    with {:ok, user_id} <- partition_user_id(job) do
      ProactiveCheckIn.run_for_user(user_id) |> normalize_work_result()
    end
  end

  defp execute_model(%BackgroundJob{job_type: @todo_completion_job} = job) do
    with {:ok, user_id} <- partition_user_id(job) do
      TodoCompletionSweep.run_for_user(user_id) |> normalize_work_result()
    end
  end

  defp execute_model(%BackgroundJob{job_type: @nudge_job} = job) do
    with {:ok, user_id} <- partition_user_id(job) do
      NudgeSweep.run_for_user(user_id) |> normalize_work_result()
    end
  end

  defp execute_model(%BackgroundJob{job_type: @staleness_job} = job) do
    with {:ok, user_id} <- partition_user_id(job) do
      StalenessTriageSweep.run_for_user(user_id) |> normalize_work_result()
    end
  end

  defp execute_model(%BackgroundJob{job_type: @todo_outcome_job} = job) do
    with {:ok, event_id} <- payload_string(job, "event_id") do
      OutcomeLearning.process_event(event_id) |> normalize_work_result()
    end
  end

  defp execute_model(%BackgroundJob{} = job),
    do: {:error, {:unknown_model_partition, job.job_type}}

  defp normalize_work_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_work_result(result) when is_map(result), do: {:ok, result}
  defp normalize_work_result(:ok), do: {:ok, %{outcome: "ok"}}
  defp normalize_work_result({:skip, reason}), do: {:ok, %{outcome: "skipped", reason: reason}}

  defp normalize_work_result({:error, reason}) do
    case retry_after_seconds(reason, 0) do
      {:ok, seconds} -> {:error, {:retry_after, seconds, reason}}
      :none -> {:error, reason}
    end
  end

  defp normalize_work_result(other), do: {:ok, %{outcome: "completed", result: inspect(other)}}

  # Provider clients wrap HTTP failures (for example
  # `{:token_refresh_failed, {:rate_limited, ...}}`). Walk only a small tuple
  # depth so Retry-After still reaches the durable lane cooldown without
  # inspecting or persisting arbitrary response structures.
  defp retry_after_seconds({:rate_limited, seconds, _detail}, _depth)
       when is_integer(seconds) and seconds >= 0,
       do: {:ok, seconds}

  # The two-tuple form is emitted by the model limiter in milliseconds.
  defp retry_after_seconds({:rate_limited, retry_after_ms}, _depth)
       when is_integer(retry_after_ms) and retry_after_ms >= 0,
       do: {:ok, max(div(retry_after_ms + 999, 1_000), 1)}

  defp retry_after_seconds({:rate_limited, _detail}, _depth),
    do: {:ok, @default_retry_after_seconds}

  defp retry_after_seconds({:http_status, 429, _detail}, _depth),
    do: {:ok, @default_retry_after_seconds}

  defp retry_after_seconds({:http_status, 429}, _depth),
    do: {:ok, @default_retry_after_seconds}

  defp retry_after_seconds(reason, depth) when is_tuple(reason) and depth < 4 do
    reason
    |> Tuple.to_list()
    |> Enum.reduce_while(:none, fn value, :none ->
      case retry_after_seconds(value, depth + 1) do
        {:ok, _seconds} = found -> {:halt, found}
        :none -> {:cont, :none}
      end
    end)
  end

  defp retry_after_seconds(_reason, _depth), do: :none

  defp partition_user_id(%BackgroundJob{user_id: user_id}) when is_binary(user_id),
    do: {:ok, user_id}

  defp partition_user_id(_job), do: {:error, :missing_user_id}

  defp payload_integer(job, key, default \\ nil)

  defp payload_integer(%BackgroundJob{payload: payload}, key, default) do
    case Map.get(payload || %{}, key, default) do
      value when is_integer(value) -> {:ok, value}
      value when is_binary(value) -> parse_integer(value, default)
      _other when is_integer(default) -> {:ok, default}
      _other -> {:error, {:missing_integer_payload, key}}
    end
  end

  defp payload_integer_value(job, key, default) do
    case payload_integer(job, key, default) do
      {:ok, value} -> value
      _error -> default
    end
  end

  defp payload_string(%BackgroundJob{payload: payload}, key) do
    case Map.get(payload || %{}, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_string_payload, key}}
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _ when is_integer(default) -> {:ok, default}
      _ -> {:error, :invalid_integer_payload}
    end
  end

  defp enqueue_many(items, enqueue_fun) do
    Enum.reduce_while(items, {:ok, 0}, fn item, {:ok, count} ->
      case enqueue_fun.(item) do
        {:ok, %BackgroundJob{}} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp schedule_summary({:ok, count}, schedule, discovered),
    do: {:ok, %{schedule: schedule, discovered: discovered, enqueued: count}}

  defp schedule_summary({:error, _reason} = error, _schedule, _discovered), do: error

  defp provider_partition(user_id, provider),
    do: hashed_key("provider-account", "#{user_id}:#{provider}")

  defp tenant_partition(user_id), do: hashed_key("tenant", user_id)

  defp model_dedupe_key(schedule, user_id),
    do: hashed_key("runtime-model:#{schedule}", user_id)

  defp hashed_key(prefix, value) when is_binary(prefix) and is_binary(value) do
    digest = :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
    "#{prefix}:#{digest}"
  end

  defp database_now! do
    case Repo.query!("SELECT timezone('UTC', clock_timestamp())", [], log: false).rows do
      [[%NaiveDateTime{} = value]] -> DateTime.from_naive!(value, "Etc/UTC")
      [[%DateTime{} = value]] -> value
    end
  end
end
