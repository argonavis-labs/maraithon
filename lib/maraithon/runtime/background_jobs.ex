defmodule Maraithon.Runtime.BackgroundJobs do
  @moduledoc """
  Public API for app-level background jobs.

  Use this for work that can be durable, asynchronous, retried, and observed
  without tying up a web request, Telegram turn, source webhook, or database
  connection longer than necessary.
  """

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob

  @default_max_attempts 3
  @default_limit 50

  def enqueue(job_type, attrs \\ %{}) when is_binary(job_type) do
    attrs = normalize_attrs(job_type, attrs)

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

  def enqueue_open_loop_check(user_id, attrs \\ %{}) when is_binary(user_id) do
    attrs =
      attrs
      |> normalize_map()
      |> Map.put("user_id", user_id)
      |> Map.put_new("queue", "open_loops")
      |> Map.put_new("dedupe_key", dedupe_key(user_id, "open_loop_check", attrs))

    enqueue("open_loop_check", attrs)
  end

  @doc """
  Enqueue the `relationship_ingestion` job that runs once a `Crm.Ingest.Window`
  has been guarded into `flushed` status. Idempotent on `window_id`.
  """
  def enqueue_relationship_ingestion(window_id) when is_binary(window_id) do
    enqueue("relationship_ingestion", %{
      "queue" => "relationships",
      "payload" => %{"window_id" => window_id},
      "dedupe_key" => "crm_ingest:flush:#{window_id}"
    })
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
  end

  def count_by_status(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    BackgroundJob
    |> maybe_filter(:user_id, user_id)
    |> group_by([job], job.status)
    |> select([job], {job.status, count(job.id)})
    |> Repo.all()
    |> Map.new()
  end

  def cancel(id) when is_binary(id) do
    now = DateTime.utc_now()

    case Repo.update_all(
           from(job in BackgroundJob,
             where: job.id == ^id,
             where: job.status in ["pending", "running"]
           ),
           set: [
             status: "cancelled",
             cancelled_at: now,
             claimed_by: nil,
             claimed_at: nil,
             updated_at: now
           ]
         ) do
      {1, _} -> {:ok, :cancelled}
      {0, _} -> {:error, :not_found_or_not_cancellable}
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
      "attempts" => read_integer(attrs, "attempts", 0),
      "max_attempts" => read_integer(attrs, "max_attempts", @default_max_attempts),
      "scheduled_at" => read_datetime(attrs, "scheduled_at") || DateTime.utc_now(),
      "result" => read_map(attrs, "result")
    }
  end

  def serialize(%BackgroundJob{} = job) do
    %{
      id: job.id,
      user_id: job.user_id,
      queue: job.queue,
      job_type: job.job_type,
      status: job.status,
      dedupe_key: job.dedupe_key,
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

  defp existing_active(%{"dedupe_key" => dedupe_key}) when is_binary(dedupe_key) do
    Repo.one(
      from(job in BackgroundJob,
        where: job.dedupe_key == ^dedupe_key,
        where: job.status in ["pending", "running"],
        order_by: [desc: job.inserted_at],
        limit: 1
      )
    )
  end

  defp existing_active(_attrs), do: nil

  defp handle_dedupe_conflict({:ok, %BackgroundJob{} = job}, _attrs), do: {:ok, job}

  defp handle_dedupe_conflict({:error, changeset}, %{"dedupe_key" => dedupe_key})
       when is_binary(dedupe_key) do
    case existing_active(%{"dedupe_key" => dedupe_key}) do
      %BackgroundJob{} = job -> {:ok, job}
      nil -> {:error, changeset}
    end
  end

  defp handle_dedupe_conflict({:error, changeset}, _attrs), do: {:error, changeset}

  defp default_queue("email_processing"), do: "email"
  defp default_queue("relationship_learning"), do: "relationships"
  defp default_queue("relationship_ingestion"), do: "relationships"
  defp default_queue("relationship_backfill"), do: "relationships"
  defp default_queue("open_loop_check"), do: "open_loops"
  defp default_queue("insight_refresh"), do: "open_loops"
  defp default_queue(_job_type), do: "default"

  defp dedupe_key(user_id, job_type, attrs) do
    attrs = normalize_map(attrs)
    payload = read_map(attrs, "payload")

    source_item_id =
      read_string(attrs, "source_item_id") || read_string(payload, "source_item_id")

    suffix = source_item_id || "latest"
    "background:#{job_type}:#{user_id}:#{suffix}"
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query

  defp maybe_filter(query, field, value) when field in [:status, :queue, :user_id] do
    where(query, [job], field(job, ^field) == ^value)
  end

  defp clamp_limit(value) when is_integer(value), do: min(max(value, 1), 500)
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
