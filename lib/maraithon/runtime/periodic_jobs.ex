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
  alias Maraithon.Agents.Agent
  alias Maraithon.ChiefOfStaff.Skills
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
  alias Maraithon.Runtime.SourceAccountDiscovery
  alias Maraithon.Runtime.SourceAccountClosure
  alias Maraithon.Runtime.TodoCompletionSweep
  alias Maraithon.Runtime.TokenRefresher
  alias Maraithon.Runtime.WatchRenewer
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.Todos.Todo
  alias Maraithon.Todos.{OutcomeLearning, UserBatch}

  @provider_queue "runtime_provider_account"
  @model_queue "runtime_model_user"
  @active_statuses ~w(pending running)
  @default_retry_after_seconds 30
  @source_finalizer_retry_seconds 10
  @source_dependency_retry_ms 10_000

  @token_job "runtime_partition:token_refresh"
  @watch_job "runtime_partition:watch_renewal"
  @freshness_account_job "runtime_partition:freshness_account"
  @freshness_watch_job "runtime_partition:freshness_watch"
  @telegram_heal_job "runtime_partition:telegram_heal"
  @proactive_job "runtime_partition:proactive_check_in"
  @source_discovery_job "runtime_partition:source_account_discovery"
  @source_discovery_reason_job "runtime_partition:source_account_discovery_reason"
  @source_discovery_finalize_job "runtime_partition:source_account_discovery_finalize"
  @todo_completion_job "runtime_partition:todo_completion"
  @todo_account_closure_acquire_job "runtime_partition:source_account_closure_acquire"
  @todo_account_closure_job "runtime_partition:source_account_closure"
  @todo_account_closure_reason_job "runtime_partition:source_account_closure_reason"
  @todo_account_closure_finalize_job "runtime_partition:source_account_closure_finalize"
  @nudge_job "runtime_partition:nudge"
  @staleness_job "runtime_partition:staleness_triage"
  @todo_outcome_job "runtime_partition:todo_outcome_learning"

  def provider_queue, do: @provider_queue
  def model_queue, do: @model_queue

  @doc "Durably wakes the discovery and applicable closure workers for one source account."
  def wake_source_account(account, opts \\ [])

  def wake_source_account(%ConnectedAccount{status: "connected"} = account, opts)
      when is_list(opts) do
    now = Keyword.get(opts, :now, database_now!())

    enqueue_source_graph(fn ->
      with {:ok, discovery} <- enqueue_source_account_discovery(account, now),
           {:ok, closure} <-
             maybe_enqueue_source_account_closure(
               account,
               now,
               Map.get(discovery, :job_id)
             ) do
        {:ok, %{discovery: discovery, closure: closure}}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def wake_source_account(%ConnectedAccount{}, _opts), do: {:ok, %{outcome: "disconnected"}}
  def wake_source_account(_account, _opts), do: {:error, :invalid_source_account}

  @doc "Runs one bounded recurring discovery coordinator."
  def schedule("token_refresher"), do: schedule_token_refreshes()
  def schedule("watch_renewer"), do: schedule_watch_renewals()
  def schedule("freshness_sweep"), do: schedule_freshness_checks()
  def schedule("proactive_check_in"), do: schedule_proactive_users()
  def schedule("source_account_discovery"), do: schedule_source_account_discovery()
  def schedule("todo_completion_sweep"), do: schedule_todo_completion_partitions()
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

  defp schedule_source_account_discovery do
    now = database_now!()
    batch_size = Config.positive_integer(:source_account_discovery_batch_size, 100)
    cursor_key = "durable_source_account_discovery"
    cursor = load_account_cursor(cursor_key)
    accounts = source_discovery_accounts(batch_size, cursor)
    account_identities = source_discovery_account_identities(accounts)

    result =
      enqueue_many(account_identities, fn {account, agent} ->
        enqueue_source_discovery_job(account, agent, now)
      end)
      |> schedule_summary("source_account_discovery", length(account_identities))

    record_account_cursor_after(result, cursor_key, accounts)
  end

  defp source_discovery_account_identities(accounts) do
    accounts
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
    |> discovery_agents_by_user()
    |> then(fn agents_by_user ->
      Enum.flat_map(accounts, fn account ->
        case discovery_identity(Map.get(agents_by_user, account.user_id, [])) do
          {:ok, agent} -> [{account, agent}]
          {:skip, _reason} -> []
        end
      end)
    end)
  end

  defp source_discovery_accounts(limit, cursor) do
    query =
      ConnectedAccount
      |> join(:inner, [account], source_token in Token,
        on: source_token.user_id == account.user_id and source_token.provider == account.provider
      )
      |> join(:left, [account, _source_token], acquisition_job in BackgroundJob,
        on:
          acquisition_job.dedupe_key ==
            fragment("'runtime-partition:source-account-discovery:' || ?::text", account.id) and
            acquisition_job.status in @active_statuses
      )
      |> join(
        :left,
        [account, _source_token, _acquisition_job],
        reason_job in BackgroundJob,
        on:
          fragment(
            "? LIKE 'runtime-partition:source-account-discovery-reason:%:' || ?::text",
            reason_job.dedupe_key,
            account.id
          ) and
            reason_job.status in @active_statuses and
            reason_job.attempts < reason_job.max_attempts
      )
      |> join(
        :left,
        [account, _source_token, _acquisition_job, _reason_job],
        finalizer_job in BackgroundJob,
        on:
          finalizer_job.status in @active_statuses and
            (finalizer_job.dedupe_key ==
               fragment(
                 "'runtime-partition:source-account-discovery-finalize:' || ?::text",
                 account.id
               ) or
               fragment(
                 "? LIKE 'runtime-partition:source-account-discovery-finalize:' || ?::text || ':%'",
                 finalizer_job.dedupe_key,
                 account.id
               ))
      )
      |> where(
        [account, _source_token, acquisition_job, reason_job, finalizer_job],
        account.status == "connected" and is_nil(acquisition_job.id) and is_nil(reason_job.id) and
          is_nil(finalizer_job.id)
      )
      |> where(
        [account, _source_token, _acquisition_job, _reason_job, _finalizer_job],
        like(account.provider, "google%") or
          fragment("? ~ '^slack:[^:]+$'", account.provider)
      )
      |> distinct(
        [account, _source_token, _acquisition_job, _reason_job, _finalizer_job],
        account.id
      )
      |> order_by(
        [account, _source_token, _acquisition_job, _reason_job, _finalizer_job],
        asc: account.id
      )
      |> select(
        [account, _source_token, _acquisition_job, _reason_job, _finalizer_job],
        struct(account, [
          :id,
          :user_id,
          :provider,
          :external_account_id,
          :status,
          :scopes,
          :metadata
        ])
      )

    account_page(query, limit, cursor, :first)
  end

  defp enqueue_source_account_discovery(account, now) do
    case discovery_identity_for_user(account.user_id) do
      {:ok, agent} ->
        case enqueue_source_discovery_job(account, agent, now) do
          {:ok, %BackgroundJob{} = job} ->
            {:ok, %{outcome: "enqueued", job_id: job.id, agent_id: agent_id(agent)}}

          {:error, reason} ->
            {:error, {:source_discovery_enqueue_failed, reason}}
        end

      {:skip, reason} ->
        {:ok, %{outcome: "skipped", reason: to_string(reason)}}
    end
  end

  defp enqueue_source_discovery_job(account, agent, now) do
    BackgroundJobs.enqueue(@source_discovery_job, %{
      user_id: account.user_id,
      queue: @provider_queue,
      dedupe_key: source_discovery_dedupe_key(account.id),
      partition_key: provider_partition(account.user_id, account.provider),
      rate_limit_key: TokenRefresher.provider_family(account.provider),
      max_attempts: 5,
      scheduled_at: now,
      payload:
        %{
          "user_id" => account.user_id,
          "account_id" => account.id,
          "role" => "discovery"
        }
        |> maybe_put_discovery_agent_id(agent)
    })
  end

  defp discovery_identity_for_user(user_id) do
    Agent
    |> where(
      [agent],
      agent.user_id == ^user_id and agent.behavior == "ai_chief_of_staff" and
        agent.install_status != "removed"
    )
    |> order_by([agent], asc: agent.id)
    |> Repo.all()
    |> discovery_identity()
  end

  defp discovery_agents_by_user([]), do: %{}

  defp discovery_agents_by_user(user_ids) do
    Agent
    |> where(
      [agent],
      agent.user_id in ^user_ids and agent.behavior == "ai_chief_of_staff" and
        agent.install_status != "removed"
    )
    |> order_by([agent], asc: agent.id)
    |> Repo.all()
    |> Enum.group_by(& &1.user_id)
  end

  defp discovery_identity([]), do: {:ok, nil}

  defp discovery_identity(agents) do
    case Enum.find(agents, &eligible_discovery_agent?/1) do
      %Agent{} = agent -> {:ok, agent}
      nil -> {:skip, :chief_not_available}
    end
  end

  defp eligible_discovery_agent?(%Agent{} = agent) do
    agent.install_status == "enabled" and
      agent.status in ["running", "recovering", "degraded"] and
      "followthrough" in Skills.enabled_ids(agent.config || %{})
  end

  defp maybe_enqueue_source_account_closure(account, now, discovery_job_id) do
    open_todos? = user_has_open_todos?(account.user_id)

    cond do
      not open_todos? ->
        {:ok, %{outcome: "skipped", reason: "no_open_todos"}}

      not is_binary(discovery_job_id) or discovery_job_id == "" ->
        {:error, :source_closure_discovery_dependency_missing}

      true ->
        case enqueue_source_account_closure_job(account, now, discovery_job_id: discovery_job_id) do
          {:ok, %BackgroundJob{} = job} -> {:ok, %{outcome: "enqueued", job_id: job.id}}
          {:error, reason} -> {:error, {:source_closure_enqueue_failed, reason}}
        end
    end
  end

  defp enqueue_source_account_closure_job(account, now, opts) do
    discovery_job_id = Keyword.fetch!(opts, :discovery_job_id)

    BackgroundJobs.enqueue(@todo_account_closure_acquire_job, %{
      user_id: account.user_id,
      queue: @provider_queue,
      dedupe_key: source_closure_acquire_dedupe_key(account.id, discovery_job_id),
      partition_key: provider_partition(account.user_id, account.provider),
      rate_limit_key: TokenRefresher.provider_family(account.provider),
      max_attempts: 5,
      scheduled_at: now,
      payload: %{
        "user_id" => account.user_id,
        "account_id" => account.id,
        "role" => "closure",
        "discovery_job_id" => discovery_job_id
      }
    })
  end

  defp user_has_open_todos?(user_id) do
    Todo
    |> where([todo], todo.user_id == ^user_id)
    |> where([todo], todo.status in ["open", "snoozed"])
    |> Repo.exists?()
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

  defp schedule_todo_completion_partitions do
    now = database_now!()
    batch_size = Config.positive_integer(:todo_completion_account_batch_size, 100)
    account_cursor_key = "durable_todo_completion_accounts"
    account_cursor = load_account_cursor(account_cursor_key)
    accounts = todo_completion_accounts(batch_size, account_cursor)
    cursor_key = "durable_todo_completion_legacy_sweep"
    cursor = UserBatch.load_cursor(cursor_key)

    legacy_users =
      UserBatch.open_todo_user_ids_without_connected_source_account(after_user_id: cursor)

    with {:ok, account_count} <-
           enqueue_many(accounts, fn account ->
             enqueue_source_account_cycle(account, now)
           end),
         {:ok, legacy_count} <-
           enqueue_many(legacy_users, fn user_id ->
             BackgroundJobs.enqueue(@todo_completion_job, %{
               user_id: user_id,
               queue: @model_queue,
               dedupe_key: model_dedupe_key("todo_completion_legacy", user_id),
               partition_key: tenant_partition(user_id),
               rate_limit_key: "model",
               max_attempts: 3,
               scheduled_at: now,
               payload: %{"user_id" => user_id, "partition_role" => "legacy"}
             })
           end) do
      result =
        {:ok,
         %{
           schedule: "todo_completion_sweep",
           discovered: length(accounts) + length(legacy_users),
           enqueued: account_count + legacy_count,
           account_partitions: account_count,
           legacy_partitions: legacy_count
         }}

      result
      |> record_cursor_after(cursor_key, legacy_users)
      |> record_account_cursor_after(account_cursor_key, accounts)
    end
  end

  defp enqueue_source_account_cycle(account, now) do
    case wake_source_account(account, now: now) do
      {:ok, %{closure: %{job_id: closure_job_id}}} ->
        case Repo.get(BackgroundJob, closure_job_id) do
          %BackgroundJob{} = job -> {:ok, job}
          nil -> {:error, :source_account_cycle_closure_missing}
        end

      {:ok, result} ->
        {:error, {:source_account_cycle_incomplete, result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp todo_completion_accounts(limit, cursor) do
    open_todo_user_ids =
      Todo
      |> where([todo], todo.status in ["open", "snoozed"])
      |> distinct([todo], todo.user_id)
      |> select([todo], todo.user_id)

    query =
      ConnectedAccount
      |> join(:inner, [account], source_token in Token,
        on: source_token.user_id == account.user_id and source_token.provider == account.provider
      )
      |> join(:left, [account, _source_token], legacy_job in BackgroundJob,
        on:
          legacy_job.dedupe_key ==
            fragment("'runtime-partition:todo-account-closure:' || ?::text", account.id) and
            legacy_job.status in @active_statuses
      )
      |> join(:left, [account, _source_token, _legacy_job], acquisition_job in BackgroundJob,
        on:
          fragment(
            "? LIKE 'runtime-partition:source-account-closure-acquire:' || ?::text || '%'",
            acquisition_job.dedupe_key,
            account.id
          ) and
            acquisition_job.status in @active_statuses
      )
      |> join(
        :left,
        [account, _source_token, _legacy_job, _acquisition_job],
        reason_job in BackgroundJob,
        on:
          fragment(
            "? LIKE 'runtime-partition:source-account-closure-reason:%:' || ?::text",
            reason_job.dedupe_key,
            account.id
          ) and
            reason_job.status in @active_statuses and
            reason_job.attempts < reason_job.max_attempts
      )
      |> join(
        :left,
        [account, _source_token, _legacy_job, _acquisition_job, _reason_job],
        finalizer_job in BackgroundJob,
        on:
          finalizer_job.status in @active_statuses and
            (finalizer_job.dedupe_key ==
               fragment(
                 "'runtime-partition:source-account-closure-finalize:' || ?::text",
                 account.id
               ) or
               fragment(
                 "? LIKE 'runtime-partition:source-account-closure-finalize:' || ?::text || ':%'",
                 finalizer_job.dedupe_key,
                 account.id
               ))
      )
      |> where(
        [account, _source_token, legacy_job, acquisition_job, reason_job, finalizer_job],
        account.user_id in subquery(open_todo_user_ids) and account.status == "connected" and
          is_nil(legacy_job.id) and is_nil(acquisition_job.id) and is_nil(reason_job.id) and
          is_nil(finalizer_job.id)
      )
      |> where(
        [account, _source_token, _legacy_job, _acquisition_job, _reason_job, _finalizer_job],
        like(account.provider, "google%") or
          fragment("? ~ '^slack:[^:]+$'", account.provider)
      )
      |> distinct(
        [account, _source_token, _legacy_job, _acquisition_job, _reason_job, _finalizer_job],
        account.id
      )
      |> order_by(
        [account, _source_token, _legacy_job, _acquisition_job, _reason_job, _finalizer_job],
        asc: account.id
      )
      |> select(
        [account, _source_token, _legacy_job, _acquisition_job, _reason_job, _finalizer_job],
        struct(account, [
          :id,
          :user_id,
          :provider,
          :external_account_id,
          :status,
          :scopes,
          :metadata
        ])
      )

    account_page(query, limit, cursor, :first)
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

  defp record_account_cursor_after({:ok, _summary} = result, cursor_key, accounts) do
    case List.last(accounts) do
      %ConnectedAccount{id: account_id} ->
        case UserBatch.record_cursor(cursor_key, Integer.to_string(account_id)) do
          :ok -> result
          :error -> {:error, {:account_cursor_record_failed, cursor_key}}
        end

      nil ->
        result
    end
  end

  defp record_account_cursor_after(error, _cursor_key, _accounts), do: error

  defp load_account_cursor(cursor_key) do
    case UserBatch.load_cursor(cursor_key) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {account_id, ""} when account_id > 0 -> account_id
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp account_page(query, limit, cursor, account_binding) do
    first =
      query
      |> maybe_after_account(cursor, account_binding)
      |> limit(^limit)
      |> Repo.all()

    remaining = limit - length(first)

    if remaining > 0 and is_integer(cursor) do
      wrap =
        query
        |> before_or_at_account(cursor, account_binding)
        |> limit(^remaining)
        |> Repo.all()

      first ++ wrap
    else
      first
    end
  end

  defp maybe_after_account(query, nil, _account_binding), do: query

  defp maybe_after_account(query, cursor, :first) when is_integer(cursor),
    do: where(query, [account, ...], account.id > ^cursor)

  defp maybe_after_account(query, cursor, :second) when is_integer(cursor),
    do: where(query, [_todo, account, ...], account.id > ^cursor)

  defp before_or_at_account(query, cursor, :first),
    do: where(query, [account, ...], account.id <= ^cursor)

  defp before_or_at_account(query, cursor, :second),
    do: where(query, [_todo, account, ...], account.id <= ^cursor)

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

  defp execute_provider(%BackgroundJob{job_type: @source_discovery_job} = job) do
    with {:ok, account_id} <- payload_integer(job, "account_id"),
         %ConnectedAccount{} = account <- Repo.get(ConnectedAccount, account_id),
         {:ok, agent} <- discovery_agent_from_payload(job.payload || %{}),
         true <- discovery_identity_valid?(job, account, agent),
         {:ok, result} <-
           SourceAccountDiscovery.acquire(account, agent,
             acquisition_job_id: job.id,
             defer_watermark_commit: true
           ) do
      maybe_enqueue_discovery_reason(job, account, result)
    else
      nil -> {:error, :source_discovery_account_not_found}
      false -> {:error, :source_discovery_identity_mismatch}
      {:error, _reason} = error -> error
      {:skip, _reason} = skip -> normalize_work_result(skip)
    end
  end

  defp execute_provider(%BackgroundJob{job_type: @todo_account_closure_acquire_job} = job) do
    case source_discovery_dependency_status(job) do
      :ready ->
        execute_source_account_closure_acquire(job)

      {:waiting, stage} ->
        {:ok,
         %{
           outcome: "waiting_for_discovery",
           dependency_stage: stage
         }, {:reschedule_in, @source_dependency_retry_ms}}

      {:error, reason} ->
        {:error, {:discard, reason}}
    end
  end

  defp execute_provider(%BackgroundJob{} = job),
    do: {:error, {:unknown_provider_partition, job.job_type}}

  defp execute_source_account_closure_acquire(job) do
    with {:ok, account_id} <- payload_integer(job, "account_id"),
         %ConnectedAccount{} = account <- Repo.get(ConnectedAccount, account_id),
         true <- account.user_id == job.user_id,
         {:ok, result} <-
           SourceAccountClosure.acquire(account,
             acquisition_job_id: job.id,
             defer_watermark_commit: true
           ) do
      maybe_enqueue_closure_reason(job, account, result)
    else
      nil -> {:error, :source_account_not_found}
      false -> {:error, :source_account_user_mismatch}
      {:error, _reason} = error -> error
      {:skip, _reason} = skip -> normalize_work_result(skip)
    end
  end

  defp execute_model(%BackgroundJob{job_type: @proactive_job} = job) do
    with {:ok, user_id} <- partition_user_id(job) do
      ProactiveCheckIn.run_for_user(user_id) |> normalize_work_result()
    end
  end

  defp execute_model(%BackgroundJob{job_type: @todo_completion_job} = job) do
    with {:ok, user_id} <- partition_user_id(job) do
      opts =
        if Map.get(job.payload || %{}, "partition_role") == "legacy" do
          [source_account_unassigned?: true]
        else
          []
        end

      TodoCompletionSweep.run_for_user(user_id, opts) |> normalize_work_result()
    end
  end

  defp execute_model(%BackgroundJob{job_type: @todo_account_closure_job} = job) do
    with {:ok, account_id} <- payload_integer(job, "account_id"),
         %ConnectedAccount{} = account <- Repo.get(ConnectedAccount, account_id),
         true <- account.user_id == job.user_id do
      TodoCompletionSweep.run_for_account(account) |> normalize_work_result()
    else
      nil -> {:error, :source_account_not_found}
      false -> {:error, :source_account_user_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp execute_model(%BackgroundJob{job_type: @source_discovery_reason_job} = job) do
    with {:ok, account_id} <- payload_integer(job, "account_id"),
         %ConnectedAccount{} = account <- Repo.get(ConnectedAccount, account_id),
         {:ok, agent} <- discovery_agent_from_payload(job.payload || %{}),
         true <- discovery_identity_valid?(job, account, agent),
         {:ok, result} <- SourceAccountDiscovery.reason(account, agent, job.payload || %{}) do
      normalize_work_result(result)
    else
      nil -> {:error, :source_discovery_account_not_found}
      false -> {:error, :source_discovery_identity_mismatch}
      {:error, _reason} = error -> normalize_work_result(error)
    end
  end

  defp execute_model(%BackgroundJob{job_type: @source_discovery_finalize_job} = job) do
    with {:ok, account_id} <- payload_integer(job, "account_id"),
         {:ok, reason_job_ids} <- payload_string_list(job, "reason_job_ids"),
         %ConnectedAccount{} = account <- Repo.get(ConnectedAccount, account_id),
         {:ok, agent} <- discovery_agent_from_payload(job.payload || %{}),
         true <- discovery_identity_valid?(job, account, agent),
         {:ok, child_results} <- completed_child_results(reason_job_ids),
         {:ok, result} <-
           SourceAccountDiscovery.finalize(
             account,
             agent,
             job.payload || %{},
             child_results,
             defer_watermark_commit: true
           ) do
      normalize_work_result(result)
    else
      nil ->
        {:error, :source_discovery_account_not_found}

      false ->
        {:error, :source_discovery_identity_mismatch}

      {:pending, _count} ->
        {:error,
         {:retry_after, @source_finalizer_retry_seconds, :source_discovery_children_pending}}

      {:error, :source_discovery_child_failed} ->
        {:error, {:discard, :source_discovery_child_failed}}

      {:error, _reason} = error ->
        normalize_work_result(error)
    end
  end

  defp execute_model(%BackgroundJob{job_type: @todo_account_closure_reason_job} = job) do
    with {:ok, account_id} <- payload_integer(job, "account_id"),
         %ConnectedAccount{} = account <- Repo.get(ConnectedAccount, account_id),
         true <- account.user_id == job.user_id,
         {:ok, result} <- SourceAccountClosure.reason(account, job.payload || %{}) do
      normalize_work_result(result)
    else
      nil -> {:error, :source_account_not_found}
      false -> {:error, :source_account_user_mismatch}
      {:error, _reason} = error -> normalize_work_result(error)
    end
  end

  defp execute_model(%BackgroundJob{job_type: @todo_account_closure_finalize_job} = job) do
    with {:ok, account_id} <- payload_integer(job, "account_id"),
         {:ok, reason_job_ids} <- payload_string_list(job, "reason_job_ids"),
         %ConnectedAccount{} = account <- Repo.get(ConnectedAccount, account_id),
         true <- account.user_id == job.user_id,
         {:ok, child_results} <- completed_child_results(reason_job_ids),
         {:ok, result} <-
           SourceAccountClosure.finalize(account, job.payload || %{}, child_results,
             defer_watermark_commit: true
           ) do
      normalize_work_result(result)
    else
      nil ->
        {:error, :source_account_not_found}

      false ->
        {:error, :source_account_user_mismatch}

      {:pending, _count} ->
        {:error,
         {:retry_after, @source_finalizer_retry_seconds, :source_closure_children_pending}}

      {:error, :source_discovery_child_failed} ->
        {:error, {:discard, :source_closure_child_failed}}

      {:error, _reason} = error ->
        normalize_work_result(error)
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

  defp maybe_enqueue_discovery_reason(
         acquisition_job,
         account,
         %{handoffs: handoffs, finalizer: finalizer} = result
       )
       when is_list(handoffs) and is_map(finalizer) do
    case enqueue_source_graph(fn ->
           with {:ok, reason_jobs} <-
                  enqueue_discovery_fanouts(acquisition_job, account, handoffs),
                reason_job_ids <- Enum.map(reason_jobs, & &1.id),
                finalizer_payload <- Map.put(finalizer, "reason_job_ids", reason_job_ids),
                {:ok, %BackgroundJob{} = finalizer_job} <-
                  BackgroundJobs.enqueue(@source_discovery_finalize_job, %{
                    user_id: account.user_id,
                    queue: @model_queue,
                    dedupe_key:
                      source_discovery_finalize_dedupe_key(account.id, acquisition_job.id),
                    partition_key: provider_partition(account.user_id, account.provider),
                    rate_limit_key: "model",
                    max_attempts: 25,
                    scheduled_at:
                      DateTime.add(database_now!(), max(length(reason_jobs), 1), :second),
                    payload: finalizer_payload
                  }),
                true <-
                  get_in(finalizer_job.payload || %{}, ["acquisition_job_id"]) ==
                    acquisition_job.id do
             {:ok, {reason_job_ids, finalizer_job.id}}
           else
             false -> {:error, :source_discovery_stale_finalizer}
             {:error, reason} -> {:error, reason}
           end
         end) do
      {:ok, {reason_job_ids, finalizer_job_id}} ->
        {:ok,
         result
         |> Map.delete(:handoffs)
         |> Map.delete(:finalizer)
         |> Map.put(:reason_job_ids, reason_job_ids)
         |> Map.put(:finalizer_job_id, finalizer_job_id)}

      {:error, :source_discovery_stale_finalizer} ->
        {:error, :source_discovery_stale_finalizer}

      {:error, reason} ->
        {:error, {:source_discovery_handoff_failed, reason}}
    end
  end

  defp maybe_enqueue_discovery_reason(_job, _account, result),
    do: normalize_work_result(result)

  defp enqueue_discovery_fanouts(acquisition_job, account, handoffs) do
    handoffs
    |> Enum.reduce_while({:ok, []}, fn handoff, {:ok, jobs} ->
      fanout_index = Map.get(handoff, "fanout_index")

      attrs = %{
        user_id: account.user_id,
        queue: @model_queue,
        dedupe_key:
          source_discovery_reason_dedupe_key(
            acquisition_job.id,
            fanout_index,
            Map.get(handoff, "fanout_count"),
            account.id
          ),
        partition_key:
          hashed_key(
            "source-discovery-reason",
            "#{account.user_id}:#{acquisition_job.id}:#{fanout_index}"
          ),
        rate_limit_key: "model",
        max_attempts: 3,
        scheduled_at: database_now!(),
        payload: handoff
      }

      case enqueue_cycle_job(@source_discovery_reason_job, attrs) do
        {:ok, %BackgroundJob{} = reason_job} ->
          valid? =
            get_in(reason_job.payload || %{}, ["acquisition_job_id"]) == acquisition_job.id and
              get_in(reason_job.payload || %{}, ["fanout_index"]) == fanout_index

          if valid?,
            do: {:cont, {:ok, [reason_job | jobs]}},
            else: {:halt, {:error, :source_discovery_stale_handoff}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, _reason} = error -> error
    end
  end

  defp enqueue_cycle_job(job_type, %{dedupe_key: dedupe_key} = attrs) do
    existing =
      BackgroundJob
      |> where([job], job.dedupe_key == ^dedupe_key)
      |> order_by([job], desc: job.inserted_at, desc: job.id)
      |> limit(1)
      |> Repo.one()

    case existing do
      %BackgroundJob{} = job -> {:ok, BackgroundJob.hydrate_payloads(job)}
      nil -> BackgroundJobs.enqueue(job_type, attrs)
    end
  end

  defp completed_child_results(reason_job_ids) do
    jobs =
      BackgroundJob
      |> where([job], job.id in ^reason_job_ids)
      |> Repo.all()
      |> Enum.map(&BackgroundJob.hydrate_payloads/1)

    cond do
      length(jobs) != length(reason_job_ids) ->
        {:error, :source_discovery_child_missing}

      Enum.any?(jobs, &(&1.status in ["failed", "cancelled"])) ->
        {:error, :source_discovery_child_failed}

      Enum.any?(jobs, &(&1.status in @active_statuses)) ->
        {:pending, Enum.count(jobs, &(&1.status in @active_statuses))}

      Enum.all?(jobs, &(&1.status == "completed")) ->
        ordered_results =
          reason_job_ids
          |> Enum.map(fn id -> Enum.find(jobs, &(&1.id == id)).result || %{} end)

        {:ok, ordered_results}

      true ->
        {:error, :source_discovery_child_invalid_status}
    end
  end

  defp maybe_enqueue_closure_reason(
         acquisition_job,
         account,
         %{handoffs: handoffs, finalizer: finalizer} = result
       )
       when is_list(handoffs) and is_map(finalizer) do
    case enqueue_source_graph(fn ->
           with {:ok, reason_jobs} <- enqueue_closure_fanouts(acquisition_job, account, handoffs),
                reason_job_ids <- Enum.map(reason_jobs, & &1.id),
                finalizer_payload <- Map.put(finalizer, "reason_job_ids", reason_job_ids),
                {:ok, %BackgroundJob{} = finalizer_job} <-
                  BackgroundJobs.enqueue(@todo_account_closure_finalize_job, %{
                    user_id: account.user_id,
                    queue: @model_queue,
                    dedupe_key:
                      source_closure_finalize_dedupe_key(account.id, acquisition_job.id),
                    partition_key: provider_partition(account.user_id, account.provider),
                    rate_limit_key: "model",
                    max_attempts: 25,
                    scheduled_at:
                      DateTime.add(database_now!(), max(length(reason_jobs), 1), :second),
                    payload: finalizer_payload
                  }),
                true <-
                  get_in(finalizer_job.payload || %{}, ["acquisition_job_id"]) ==
                    acquisition_job.id do
             {:ok, {reason_job_ids, finalizer_job.id}}
           else
             false -> {:error, :source_closure_stale_finalizer}
             {:error, reason} -> {:error, reason}
           end
         end) do
      {:ok, {reason_job_ids, finalizer_job_id}} ->
        {:ok,
         result
         |> Map.delete(:handoffs)
         |> Map.delete(:finalizer)
         |> Map.put(:reason_job_ids, reason_job_ids)
         |> Map.put(:finalizer_job_id, finalizer_job_id)}

      {:error, :source_closure_stale_finalizer} ->
        {:error, :source_closure_stale_finalizer}

      {:error, reason} ->
        {:error, {:source_closure_handoff_failed, reason}}
    end
  end

  defp maybe_enqueue_closure_reason(_job, _account, result),
    do: normalize_work_result(result)

  defp enqueue_closure_fanouts(acquisition_job, account, handoffs) do
    handoffs
    |> Enum.reduce_while({:ok, []}, fn handoff, {:ok, jobs} ->
      fanout_index = Map.get(handoff, "fanout_index")

      attrs = %{
        user_id: account.user_id,
        queue: @model_queue,
        dedupe_key:
          source_closure_reason_dedupe_key(
            acquisition_job.id,
            fanout_index,
            Map.get(handoff, "fanout_count"),
            Map.get(handoff, "source_partition_index"),
            Map.get(handoff, "source_partition_count"),
            Map.get(handoff, "todo_batch_index"),
            Map.get(handoff, "todo_batch_count"),
            account.id
          ),
        partition_key:
          source_closure_reason_partition_key(
            account.user_id,
            acquisition_job.id,
            fanout_index
          ),
        rate_limit_key: "model",
        max_attempts: 3,
        scheduled_at: database_now!(),
        payload: handoff
      }

      case enqueue_cycle_job(@todo_account_closure_reason_job, attrs) do
        {:ok, %BackgroundJob{} = reason_job} ->
          valid? =
            get_in(reason_job.payload || %{}, ["acquisition_job_id"]) == acquisition_job.id and
              get_in(reason_job.payload || %{}, ["fanout_index"]) == fanout_index

          if valid?,
            do: {:cont, {:ok, [reason_job | jobs]}},
            else: {:halt, {:error, :source_closure_stale_handoff}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, _reason} = error -> error
    end
  end

  defp enqueue_source_graph(enqueue_fun) when is_function(enqueue_fun, 0) do
    Repo.transaction(fn ->
      case enqueue_fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp discovery_identity_valid?(job, account, %Agent{} = agent) do
    account.user_id == job.user_id and agent.user_id == job.user_id and
      account.status == "connected" and agent.behavior == "ai_chief_of_staff" and
      agent.install_status == "enabled" and
      agent.status in ["running", "recovering", "degraded"] and
      "followthrough" in Skills.enabled_ids(agent.config || %{})
  end

  defp discovery_identity_valid?(job, account, nil) do
    account.user_id == job.user_id and account.status == "connected"
  end

  defp discovery_agent_from_payload(payload) do
    case Map.get(payload, "agent_id") do
      nil ->
        {:ok, nil}

      agent_id when is_binary(agent_id) ->
        case Repo.get(Agent, agent_id) do
          %Agent{} = agent -> {:ok, agent}
          nil -> {:error, :source_discovery_agent_not_found}
        end

      _other ->
        {:error, :invalid_source_discovery_agent_id}
    end
  end

  defp maybe_put_discovery_agent_id(payload, %Agent{id: id}),
    do: Map.put(payload, "agent_id", id)

  defp maybe_put_discovery_agent_id(payload, nil), do: payload

  defp source_discovery_dependency_status(%BackgroundJob{payload: payload} = closure_job) do
    case Map.get(payload || %{}, "discovery_job_id") do
      nil ->
        :ready

      discovery_job_id when is_binary(discovery_job_id) and discovery_job_id != "" ->
        validate_source_discovery_dependency(closure_job, discovery_job_id)

      _invalid ->
        {:error, :source_discovery_dependency_invalid}
    end
  end

  defp validate_source_discovery_dependency(closure_job, discovery_job_id) do
    with {:ok, account_id} <- payload_integer(closure_job, "account_id"),
         %BackgroundJob{} = discovery_job <- load_background_job(discovery_job_id),
         true <- discovery_job.job_type == @source_discovery_job,
         true <- discovery_job.user_id == closure_job.user_id,
         {:ok, ^account_id} <- payload_integer(discovery_job, "account_id") do
      source_discovery_acquisition_status(discovery_job, closure_job, account_id)
    else
      nil -> {:error, :source_discovery_dependency_missing}
      false -> {:error, :source_discovery_dependency_invalid}
      {:error, _reason} -> {:error, :source_discovery_dependency_invalid}
    end
  end

  defp source_discovery_acquisition_status(
         %BackgroundJob{status: status},
         _closure_job,
         _account_id
       )
       when status in @active_statuses,
       do: {:waiting, "acquisition"}

  defp source_discovery_acquisition_status(
         %BackgroundJob{status: "completed"} = discovery_job,
         closure_job,
         account_id
       ) do
    case source_result_string(discovery_job.result, "finalizer_job_id") do
      finalizer_job_id when is_binary(finalizer_job_id) ->
        validate_source_discovery_finalizer(
          finalizer_job_id,
          discovery_job,
          closure_job,
          account_id
        )

      nil ->
        if source_result_string(discovery_job.result, "outcome") == "empty_delta",
          do: :ready,
          else: {:error, :source_discovery_dependency_incomplete}
    end
  end

  defp source_discovery_acquisition_status(
         %BackgroundJob{status: status},
         _closure_job,
         _account_id
       )
       when status in ["failed", "cancelled"],
       do: {:error, :source_discovery_dependency_failed}

  defp source_discovery_acquisition_status(_job, _closure_job, _account_id),
    do: {:error, :source_discovery_dependency_invalid}

  defp validate_source_discovery_finalizer(
         finalizer_job_id,
         discovery_job,
         closure_job,
         account_id
       ) do
    with %BackgroundJob{} = finalizer_job <- load_background_job(finalizer_job_id),
         true <- finalizer_job.job_type == @source_discovery_finalize_job,
         true <- finalizer_job.user_id == closure_job.user_id,
         {:ok, ^account_id} <- payload_integer(finalizer_job, "account_id"),
         {:ok, discovery_job_id} <- payload_string(finalizer_job, "acquisition_job_id"),
         true <- discovery_job_id == discovery_job.id do
      source_discovery_finalizer_status(finalizer_job)
    else
      nil -> {:error, :source_discovery_finalizer_missing}
      false -> {:error, :source_discovery_finalizer_invalid}
      {:error, _reason} -> {:error, :source_discovery_finalizer_invalid}
    end
  end

  defp source_discovery_finalizer_status(%BackgroundJob{status: status})
       when status in @active_statuses,
       do: {:waiting, "finalizer"}

  defp source_discovery_finalizer_status(%BackgroundJob{status: "completed"}), do: :ready

  defp source_discovery_finalizer_status(%BackgroundJob{status: status})
       when status in ["failed", "cancelled"],
       do: {:error, :source_discovery_finalizer_failed}

  defp source_discovery_finalizer_status(_job),
    do: {:error, :source_discovery_finalizer_invalid}

  defp load_background_job(job_id) when is_binary(job_id) do
    BackgroundJob
    |> Repo.get(job_id)
    |> BackgroundJob.hydrate_payloads()
  end

  defp source_result_string(result, "finalizer_job_id") when is_map(result) do
    case Map.get(result, "finalizer_job_id", Map.get(result, :finalizer_job_id)) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp source_result_string(result, "outcome") when is_map(result) do
    case Map.get(result, "outcome", Map.get(result, :outcome)) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp source_result_string(_result, _key), do: nil

  defp agent_id(%Agent{id: id}), do: id
  defp agent_id(nil), do: nil

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

  defp payload_string_list(%BackgroundJob{payload: payload}, key) do
    case Map.get(payload || %{}, key) do
      values when is_list(values) and values != [] ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "")),
          do: {:ok, values},
          else: {:error, {:invalid_string_list_payload, key}}

      _other ->
        {:error, {:missing_string_list_payload, key}}
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

  defp source_discovery_dedupe_key(account_id),
    do: "runtime-partition:source-account-discovery:#{account_id}"

  defp source_discovery_reason_dedupe_key(
         acquisition_job_id,
         fanout_index,
         fanout_count,
         account_id
       ),
       do:
         "runtime-partition:source-account-discovery-reason:#{acquisition_job_id}:#{fanout_index}-of-#{fanout_count}:#{account_id}"

  defp source_discovery_finalize_dedupe_key(account_id, acquisition_job_id),
    do: "runtime-partition:source-account-discovery-finalize:#{account_id}:#{acquisition_job_id}"

  defp source_closure_acquire_dedupe_key(account_id, discovery_job_id),
    do: "runtime-partition:source-account-closure-acquire:#{account_id}:#{discovery_job_id}"

  defp source_closure_reason_dedupe_key(
         acquisition_job_id,
         fanout_index,
         fanout_count,
         source_partition_index,
         source_partition_count,
         todo_batch_index,
         todo_batch_count,
         account_id
       ),
       do:
         "runtime-partition:source-account-closure-reason:#{acquisition_job_id}:source-#{source_partition_index}-of-#{source_partition_count}:todo-#{todo_batch_index}-of-#{todo_batch_count}:#{fanout_index}-of-#{fanout_count}:#{account_id}"

  defp source_closure_finalize_dedupe_key(account_id, acquisition_job_id),
    do: "runtime-partition:source-account-closure-finalize:#{account_id}:#{acquisition_job_id}"

  @doc false
  def source_closure_reason_partition_key(user_id, acquisition_job_id, fanout_index)
      when is_binary(user_id) and is_binary(acquisition_job_id) and is_integer(fanout_index) and
             fanout_index > 0 do
    hashed_key(
      "source-closure-reason",
      "#{user_id}:#{acquisition_job_id}:#{fanout_index}"
    )
  end

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
