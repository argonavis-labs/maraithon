defmodule Maraithon.Runtime.BackgroundJobs do
  @moduledoc """
  Public API for app-level background jobs.

  Use this for work that can be durable, asynchronous, retried, and observed
  without tying up a web request, Telegram turn, source webhook, or database
  connection longer than necessary.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.{BoundedJSON, DurablePayload, Redaction, Repo}
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DbResilience

  @default_max_attempts 3
  @default_limit 50
  @telegram_webhook_job_type "telegram_webhook_event"
  @max_telegram_update_id 9_223_372_036_854_775_807
  @telegram_event_max_bytes 600_000
  @default_telegram_ingress_ordering_grace_ms 1_000
  @source_account_job_types [
    "runtime_partition:source_account_discovery",
    "runtime_partition:source_account_discovery_reason",
    "runtime_partition:source_account_discovery_finalize",
    "runtime_partition:source_account_closure_acquire",
    "runtime_partition:source_account_closure_reason",
    "runtime_partition:source_account_closure_finalize"
  ]
  @telegram_event_bounds [
    max_binary_bytes: 64_000,
    max_depth: 16,
    max_nodes: 10_000,
    max_map_entries: 1_000,
    max_list_items: 1_000
  ]

  @doc false
  def source_account_job_types, do: @source_account_job_types

  def enqueue(job_type, attrs \\ %{})

  def enqueue(job_type, attrs) when is_binary(job_type) do
    case String.trim(job_type) do
      @telegram_webhook_job_type ->
        {:error, :telegram_webhook_event_requires_dedicated_enqueue}

      normalized_job_type ->
        enqueue_job(normalized_job_type, attrs)
    end
  end

  @doc """
  Durably accepts one normalized Telegram webhook update.

  Unlike ordinary background-job dedupe, the `(bot_id, update_id)` identity is
  permanent across terminal states. Replays return the original job row and
  never create fresh work.
  """
  def enqueue_telegram_webhook_event(bot_id, update_id, event)
      when is_binary(bot_id) and is_integer(update_id) and is_map(event) do
    bot_id = String.trim(bot_id)

    cond do
      not valid_telegram_identity?(bot_id, update_id) ->
        {:error, :invalid_telegram_webhook_identity}

      not bounded_telegram_event?(event) ->
        {:error, :telegram_webhook_event_out_of_bounds}

      true ->
        sanitized_event = event |> normalize_value() |> scrub_raw_fields() |> Redaction.redact()

        if bounded_telegram_event?(sanitized_event) do
          enqueue_job(@telegram_webhook_job_type, %{
            queue: "ingress",
            dedupe_key: "telegram-webhook:#{bot_id}:#{update_id}",
            telegram_bot_id: bot_id,
            telegram_update_id: update_id,
            max_attempts: 5,
            scheduled_at: telegram_ingress_scheduled_at(),
            payload: %{"event" => sanitized_event}
          })
        else
          {:error, :telegram_webhook_event_out_of_bounds}
        end
    end
  end

  def enqueue_telegram_webhook_event(_bot_id, _update_id, _event),
    do: {:error, :invalid_telegram_webhook_identity}

  def enqueue_email_processing(user_id, attrs \\ %{}) when is_binary(user_id) do
    attrs =
      attrs
      |> normalize_map()
      |> Map.put("user_id", user_id)
      |> Map.put_new("queue", "email")
      |> Map.put_new("dedupe_key", dedupe_key(user_id, "email_processing", attrs))

    enqueue("email_processing", attrs)
  end

  def enqueue_relationship_learning(user_id, observations, attrs \\ [])
      when is_binary(user_id) and is_list(observations) do
    attrs = normalize_map(attrs)

    attrs =
      attrs
      |> Map.put("user_id", user_id)
      |> Map.put_new("queue", "relationships")
      |> Map.put("payload", Map.put(read_map(attrs, "payload"), "observations", observations))

    enqueue("relationship_learning", attrs)
  end

  def enqueue_communication_score_refresh(user_id, attrs \\ %{}) when is_binary(user_id) do
    attrs =
      attrs
      |> normalize_map()
      |> Map.put("user_id", user_id)
      |> Map.put_new("queue", "relationships")
      |> Map.put_new("dedupe_key", "#{user_id}:communication_score_refresh")

    enqueue("communication_score_refresh", attrs)
  end

  def enqueue_open_loop_check(user_id, attrs \\ %{}) when is_binary(user_id) do
    attrs =
      attrs
      |> normalize_map()
      |> Map.put("user_id", user_id)
      |> Map.put_new("queue", "open_loops")
      |> Map.put_new("dedupe_key", dedupe_key(user_id, "open_loop_check", attrs))

    enqueue("open_loop_check", attrs)
  end

  def enqueue_relationship_graph_refresh(user_id, attrs \\ %{}) when is_binary(user_id) do
    attrs =
      attrs
      |> normalize_map()
      |> Map.put("user_id", user_id)
      |> Map.put_new("queue", "relationships")
      |> Map.put_new("dedupe_key", "#{user_id}:relationship_graph_refresh")

    enqueue("relationship_graph_refresh", attrs)
  end

  def enqueue_person_enrichment(user_id, attrs \\ %{}) when is_binary(user_id) do
    attrs =
      attrs
      |> normalize_map()
      |> Map.put("user_id", user_id)
      |> Map.put_new("queue", "relationships")
      |> Map.put_new("dedupe_key", "#{user_id}:person_enrichment")

    enqueue("person_enrichment", attrs)
  end

  def enqueue_goal_people_discovery(user_id, attrs \\ %{}) when is_binary(user_id) do
    attrs =
      attrs
      |> normalize_map()
      |> Map.put("user_id", user_id)
      |> Map.put_new("queue", "relationships")
      |> Map.put_new("dedupe_key", "#{user_id}:goal_people_discovery")

    enqueue("goal_people_discovery", attrs)
  end

  def enqueue_person_dedupe(user_id, attrs \\ %{}) when is_binary(user_id) do
    attrs =
      attrs
      |> normalize_map()
      |> Map.put("user_id", user_id)
      |> Map.put_new("queue", "relationships")
      |> Map.put_new("dedupe_key", "#{user_id}:person_dedupe")

    enqueue("person_dedupe", attrs)
  end

  # SPEC 04 R6: rerunnable backfill resolving legacy label-only owed todos
  # to a counterparty_person_id (deterministic pass + model-gated pass).
  def enqueue_counterparty_backfill(user_id, attrs \\ %{}) when is_binary(user_id) do
    attrs =
      attrs
      |> normalize_map()
      |> Map.put("user_id", user_id)
      |> Map.put_new("queue", "relationships")
      |> Map.put_new("dedupe_key", "#{user_id}:counterparty_backfill")

    enqueue("counterparty_backfill", attrs)
  end

  def enqueue_user_scheduled_task(user_id, task_id, attrs \\ %{})
      when is_binary(user_id) and is_binary(task_id) do
    attrs = normalize_map(attrs)

    attrs =
      attrs
      |> Map.put("user_id", user_id)
      |> Map.put_new("queue", "scheduled_tasks")
      |> Map.put("payload", Map.put(read_map(attrs, "payload"), "task_id", task_id))
      |> Map.put_new("dedupe_key", user_scheduled_task_dedupe_key(user_id, task_id, attrs))

    enqueue("user_scheduled_task", attrs)
  end

  @doc """
  Enqueue the `relationship_ingestion` job that runs once a `Crm.Ingest.Window`
  has been guarded into `flushed` status. Idempotent on `window_id`.
  """
  def enqueue_relationship_ingestion(window_id, user_id \\ nil) when is_binary(window_id) do
    attrs = %{
      "user_id" => user_id,
      "queue" => "relationships",
      "payload" => %{"window_id" => window_id},
      "dedupe_key" => "crm_ingest:flush:#{window_id}"
    }

    case enqueue("relationship_ingestion", attrs) do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if is_binary(user_id) and user_foreign_key_error?(changeset) do
          enqueue("relationship_ingestion", Map.put(attrs, "user_id", nil))
        else
          error
        end

      other ->
        other
    end
  end

  @doc """
  Enqueue a one-shot bounded backfill chain for a (user, source). Subsequent
  pages re-enqueue themselves; the dedupe key blocks parallel chains for the
  same (user, source).
  """
  def enqueue_relationship_backfill(user_id, source, opts \\ [])
      when is_binary(user_id) and is_binary(source) do
    days_back = Keyword.get(opts, :days_back, 30)
    max_observations = Keyword.get(opts, :max_observations, 5_000)
    page_token = Keyword.get(opts, :page_token)
    observations_so_far = Keyword.get(opts, :observations_so_far, 0)
    scheduled_at = Keyword.get(opts, :scheduled_at, DateTime.utc_now())

    enqueue("relationship_backfill", %{
      "user_id" => user_id,
      "queue" => "relationships",
      "payload" => %{
        "source" => source,
        "days_back" => days_back,
        "max_observations" => max_observations,
        "page_token" => page_token,
        "observations_so_far" => observations_so_far
      },
      "dedupe_key" => "crm_backfill:#{user_id}:#{source}",
      "scheduled_at" => scheduled_at
    })
  end

  def list(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    status = Keyword.get(opts, :status)
    queue = Keyword.get(opts, :queue)
    user_id = Keyword.get(opts, :user_id)

    BackgroundJob
    |> maybe_filter(:status, status)
    |> maybe_filter(:queue, queue)
    |> maybe_filter(:user_id, user_id)
    |> order_by([job], asc: job.scheduled_at, desc: job.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&BackgroundJob.hydrate_payloads/1)
  end

  @doc """
  Lists every recent durable execution header for source-account workers.

  This deliberately selects no encrypted source payload. Source worker results
  contain counts and outcome labels only, so Activity can show actual model and
  decision counts without loading message deltas or handoffs into the web
  process.
  """
  def list_latest_source_account_runs_for_user(user_id, opts \\ [])

  def list_latest_source_account_runs_for_user(user_id, opts)
      when is_binary(user_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, 200) |> clamp_limit()

    jobs =
      BackgroundJob
      |> where(
        [job],
        job.user_id == ^user_id and job.job_type in ^@source_account_job_types and
          not is_nil(job.dedupe_key)
      )
      |> order_by(
        [job],
        desc: job.inserted_at,
        desc: job.id
      )
      |> limit(^limit)
      |> select([job], %{
        id: job.id,
        job_type: job.job_type,
        status: job.status,
        queue: job.queue,
        dedupe_key: job.dedupe_key,
        attempts: job.attempts,
        max_attempts: job.max_attempts,
        scheduled_at: job.scheduled_at,
        claimed_at: job.claimed_at,
        completed_at: job.completed_at,
        failed_at: job.failed_at,
        cancelled_at: job.cancelled_at,
        result: job.result,
        last_error: job.last_error,
        inserted_at: job.inserted_at
      })
      |> Repo.all()

    accounts_by_id = source_accounts_by_id(user_id, jobs)

    jobs
    |> Enum.map(fn job ->
      account_id = source_account_id(job.job_type, job.dedupe_key)

      job
      |> Map.put(:account_id, account_id)
      |> Map.put(:account, Map.get(accounts_by_id, account_id))
    end)
    |> Enum.sort_by(&source_run_occurred_at/1, {:desc, DateTime})
  end

  def list_latest_source_account_runs_for_user(_user_id, _opts), do: []

  def count_by_status(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    BackgroundJob
    |> maybe_filter(:user_id, user_id)
    |> group_by([job], job.status)
    |> select([job], {job.status, count(job.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp source_accounts_by_id(_user_id, []), do: %{}

  defp source_accounts_by_id(user_id, jobs) do
    account_ids =
      jobs
      |> Enum.map(&source_account_id(&1.job_type, &1.dedupe_key))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ConnectedAccount
    |> where([account], account.user_id == ^user_id and account.id in ^account_ids)
    |> select([account], %{
      id: account.id,
      provider: account.provider,
      external_account_id: account.external_account_id,
      metadata: account.metadata
    })
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp source_account_id(job_type, dedupe_key)
       when is_binary(job_type) and is_binary(dedupe_key) do
    segments = String.split(dedupe_key, ":")

    segment =
      case job_type do
        type
        when type in [
               "runtime_partition:source_account_discovery_finalize",
               "runtime_partition:source_account_closure_acquire",
               "runtime_partition:source_account_closure_finalize"
             ] ->
          Enum.at(segments, -2)

        _other ->
          List.last(segments)
      end

    parse_integer(segment, nil)
  end

  defp source_account_id(_job_type, _dedupe_key), do: nil

  defp source_run_occurred_at(job) do
    job.claimed_at || job.scheduled_at || job.inserted_at || ~U[1970-01-01 00:00:00Z]
  end

  def cancel(id) when is_binary(id) do
    case DbResilience.with_database("background jobs cancel", fn ->
           Repo.transaction(fn ->
             :ok = DurablePayload.require_current_mutation!()

             job =
               BackgroundJob
               |> where([candidate], candidate.id == ^id)
               |> where([candidate], candidate.status in ["pending", "running"])
               |> lock("FOR UPDATE")
               |> Repo.one()

             cancel_locked(BackgroundJob.hydrate_payloads(job))
           end)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_locked(nil), do: Repo.rollback(:not_found_or_not_cancellable)

  defp cancel_locked(%BackgroundJob{} = job) do
    now = database_now!()

    changeset =
      job
      |> BackgroundJob.changeset(%{
        status: "cancelled",
        payload: cancelled_payload(job),
        cancelled_at: now,
        claimed_by: nil,
        claimed_at: nil
      })
      |> Ecto.Changeset.force_change(:claim_token, nil)
      |> Ecto.Changeset.force_change(:updated_at, now)

    case Repo.update(changeset) do
      {:ok, _job} -> :cancelled
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp cancelled_payload(%BackgroundJob{job_type: @telegram_webhook_job_type}), do: %{}
  defp cancelled_payload(%BackgroundJob{payload: payload}), do: payload || %{}

  defp telegram_ingress_scheduled_at do
    grace_ms =
      case RuntimeConfig.get(
             :telegram_ingress_ordering_grace_ms,
             @default_telegram_ingress_ordering_grace_ms
           ) do
        value when is_integer(value) and value >= 0 -> value
        _invalid -> @default_telegram_ingress_ordering_grace_ms
      end

    DateTime.add(DateTime.utc_now(), grace_ms, :millisecond)
  end

  defp enqueue_job(job_type, attrs) do
    attrs = normalize_attrs(job_type, attrs)

    case attrs["user_id"] do
      user_id when is_binary(user_id) ->
        Repo.transaction(fn ->
          _user = WriteFence.lock_user_writable!(user_id)

          case do_enqueue_job(attrs) do
            {:ok, job} -> job
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> case do
          {:ok, job} -> {:ok, job}
          {:error, reason} -> {:error, reason}
        end

      _no_user ->
        do_enqueue_job(attrs)
    end
  end

  defp do_enqueue_job(attrs) do
    case existing_active(attrs) do
      %BackgroundJob{} = job ->
        {:ok, job}

      nil ->
        %BackgroundJob{}
        |> BackgroundJob.changeset(attrs)
        |> Repo.insert()
        |> handle_dedupe_conflict(attrs)
    end
  end

  def normalize_attrs(job_type, attrs) when is_binary(job_type) do
    attrs = normalize_map(attrs)
    payload = read_map(attrs, "payload")

    %{
      "user_id" => read_string(attrs, "user_id"),
      "queue" => read_string(attrs, "queue", default_queue(job_type)),
      "job_type" => job_type,
      "payload" => payload,
      "status" => read_string(attrs, "status", "pending"),
      "dedupe_key" => read_string(attrs, "dedupe_key"),
      "partition_key" => read_string(attrs, "partition_key"),
      "rate_limit_key" => read_string(attrs, "rate_limit_key"),
      "telegram_bot_id" => read_string(attrs, "telegram_bot_id"),
      "telegram_update_id" => read_integer(attrs, "telegram_update_id", nil),
      "attempts" => read_integer(attrs, "attempts", 0),
      "max_attempts" => read_integer(attrs, "max_attempts", @default_max_attempts),
      "scheduled_at" => read_datetime(attrs, "scheduled_at") || DateTime.utc_now(),
      "result" => read_map(attrs, "result")
    }
  end

  def serialize(%BackgroundJob{} = job) do
    job = BackgroundJob.hydrate_payloads(job)

    %{
      id: job.id,
      user_id: job.user_id,
      queue: job.queue,
      job_type: job.job_type,
      status: job.status,
      dedupe_key: job.dedupe_key,
      partition_key: job.partition_key,
      rate_limit_key: job.rate_limit_key,
      telegram_bot_id: job.telegram_bot_id,
      telegram_update_id: job.telegram_update_id,
      attempts: job.attempts,
      max_attempts: job.max_attempts,
      scheduled_at: job.scheduled_at,
      claimed_by: job.claimed_by,
      claimed_at: job.claimed_at,
      completed_at: job.completed_at,
      failed_at: job.failed_at,
      cancelled_at: job.cancelled_at,
      result: job.result || %{},
      last_error: job.last_error
    }
  end

  defp existing_active(%{
         "job_type" => @telegram_webhook_job_type,
         "dedupe_key" => dedupe_key
       })
       when is_binary(dedupe_key) do
    Repo.one(
      from(job in BackgroundJob,
        where: job.job_type == @telegram_webhook_job_type,
        where: job.dedupe_key == ^dedupe_key,
        order_by: [desc: job.inserted_at],
        limit: 1
      )
    )
    |> BackgroundJob.hydrate_payloads()
  end

  defp existing_active(%{"dedupe_key" => dedupe_key}) when is_binary(dedupe_key) do
    Repo.one(
      from(job in BackgroundJob,
        where: job.dedupe_key == ^dedupe_key,
        where: job.status in ["pending", "running"],
        order_by: [desc: job.inserted_at],
        limit: 1
      )
    )
    |> BackgroundJob.hydrate_payloads()
  end

  defp existing_active(_attrs), do: nil

  defp handle_dedupe_conflict({:ok, %BackgroundJob{} = job}, _attrs),
    do: {:ok, BackgroundJob.hydrate_payloads(job)}

  defp handle_dedupe_conflict(
         {:error, changeset},
         %{"dedupe_key" => dedupe_key} = attrs
       )
       when is_binary(dedupe_key) do
    case existing_active(attrs) do
      %BackgroundJob{} = job -> {:ok, job}
      nil -> {:error, changeset}
    end
  end

  defp handle_dedupe_conflict({:error, changeset}, _attrs), do: {:error, changeset}

  defp user_foreign_key_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:user_id, {_message, opts}} ->
        Keyword.get(opts, :constraint) == :foreign and
          Keyword.get(opts, :constraint_name) == "background_jobs_user_id_fkey"

      _other ->
        false
    end)
  end

  defp default_queue(@telegram_webhook_job_type), do: "ingress"
  defp default_queue("email_processing"), do: "email"
  defp default_queue("relationship_learning"), do: "relationships"
  defp default_queue("relationship_ingestion"), do: "relationships"
  defp default_queue("relationship_backfill"), do: "relationships"
  defp default_queue("open_loop_check"), do: "open_loops"
  defp default_queue("insight_refresh"), do: "open_loops"
  defp default_queue("user_scheduled_task"), do: "scheduled_tasks"
  defp default_queue(_job_type), do: "default"

  defp user_scheduled_task_dedupe_key(user_id, task_id, attrs) do
    scheduled_at =
      attrs
      |> normalize_map()
      |> read_datetime("scheduled_at")
      |> case do
        %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
        _ -> "now"
      end

    "scheduled_task:#{user_id}:#{task_id}:#{scheduled_at}"
  end

  defp dedupe_key(user_id, job_type, attrs) do
    attrs = normalize_map(attrs)
    payload = read_map(attrs, "payload")

    source_item_id =
      read_string(attrs, "source_item_id") || read_string(payload, "source_item_id")

    suffix = source_item_id || "latest"
    "background:#{job_type}:#{user_id}:#{suffix}"
  end

  defp database_now! do
    case Repo.query!("SELECT timezone('UTC', clock_timestamp())", [], log: false).rows do
      [[%NaiveDateTime{} = value]] -> DateTime.from_naive!(value, "Etc/UTC")
      [[%DateTime{} = value]] -> value
    end
  end

  defp bounded_telegram_event?(event) do
    BoundedJSON.valid?(event, @telegram_event_max_bytes, @telegram_event_bounds)
  end

  defp valid_telegram_identity?(bot_id, update_id) do
    bot_id != "" and byte_size(bot_id) <= 32 and String.valid?(bot_id) and
      Regex.match?(~r/^\d+$/, bot_id) and update_id >= 0 and
      update_id <= @max_telegram_update_id
  end

  defp scrub_raw_fields(value) when is_map(value) do
    Enum.reduce(value, %{}, fn
      {key, _nested}, acc when key in [:raw, "raw"] ->
        acc

      {key, nested}, acc ->
        Map.put(acc, key, scrub_raw_fields(nested))
    end)
  end

  defp scrub_raw_fields(value) when is_list(value), do: Enum.map(value, &scrub_raw_fields/1)
  defp scrub_raw_fields(value), do: value
  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query

  defp maybe_filter(query, field, value) when field in [:status, :queue, :user_id] do
    where(query, [job], field(job, ^field) == ^value)
  end

  defp clamp_limit(value) when is_integer(value), do: min(max(value, 1), 10_000)
  defp clamp_limit(_value), do: @default_limit

  defp normalize_map(attrs) when is_map(attrs), do: stringify_keys(attrs)
  defp normalize_map(attrs) when is_list(attrs), do: attrs |> Map.new() |> stringify_keys()
  defp normalize_map(_attrs), do: %{}

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

  defp read_string(attrs, key, default \\ nil) when is_map(attrs) do
    case Map.get(attrs, key, default) do
      nil -> default
      "" -> default
      value when is_binary(value) -> String.trim(value)
      value -> to_string(value)
    end
  end

  defp read_map(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_integer(attrs, key, default) when is_map(attrs) do
    case Map.get(attrs, key, default) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _ -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp read_datetime(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) do
      %DateTime{} = datetime -> datetime
      value when is_binary(value) -> parse_datetime(value)
      _ -> nil
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end
end
