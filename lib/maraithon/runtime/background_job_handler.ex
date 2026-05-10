defmodule Maraithon.Runtime.BackgroundJobHandler do
  @moduledoc """
  Executes app-level background jobs.

  Keep handlers small and explicit. Source scanners and interactive flows should
  enqueue one of these job types, then return quickly while the queue performs
  the slower work under supervision.
  """

  import Ecto.Query

  alias Maraithon.Crm.Ingest
  alias Maraithon.Crm.Ingest.Window
  alias Maraithon.Crm.Observation
  alias Maraithon.Insights.Refresh
  alias Maraithon.OpenLoops
  alias Maraithon.OperatorEvents
  alias Maraithon.RelationshipIntelligence
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob

  require Logger

  def execute(%BackgroundJob{job_type: "email_processing"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      Refresh.queue_for_user(user_id,
        requested_by: payload_string(job, "requested_by", "background_job"),
        reason: payload_string(job, "reason", "email_processing")
      )
    end
  end

  def execute(%BackgroundJob{job_type: "insight_refresh"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      Refresh.queue_for_user(user_id,
        requested_by: payload_string(job, "requested_by", "background_job"),
        reason: payload_string(job, "reason", "background_refresh")
      )
    end
  end

  def execute(%BackgroundJob{job_type: "relationship_learning"} = job) do
    with {:ok, user_id} <- require_user_id(job),
         observations when is_list(observations) and observations != [] <-
           get_in(job.payload || %{}, ["observations"]) do
      RelationshipIntelligence.learn_from_observations(user_id, observations,
        source: payload_string(job, "source", "background_relationship_learning")
      )
    else
      [] -> {:ok, %{relationship_learning: "skipped", reason: "no_observations"}}
      nil -> {:ok, %{relationship_learning: "skipped", reason: "no_observations"}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_relationship_observations}
    end
  end

  def execute(%BackgroundJob{job_type: "open_loop_check"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      query = payload_string(job, "query", nil)
      limit = payload_integer(job, "limit", 12)
      snapshot = OpenLoops.snapshot(user_id, query: query, limit: limit)

      _ =
        OperatorEvents.record(%{
          user_id: user_id,
          source: "background_jobs",
          event_type: "open_loop_check.completed",
          source_item_id: job.id,
          dedupe_key: "background:open_loop_check.completed:#{job.id}",
          payload: %{
            "job_id" => job.id,
            "query" => query,
            "totals" => Map.get(snapshot, :totals, %{}),
            "source" => Map.get(snapshot, :source)
          }
        })

      {:ok,
       %{
         source: "background_open_loop_check",
         totals: Map.get(snapshot, :totals, %{}),
         open_loop_tool_names: Map.get(snapshot, :tool_names, [])
       }}
    end
  end

  def execute(%BackgroundJob{job_type: "relationship_ingestion"} = job) do
    case payload_string(job, "window_id", nil) do
      window_id when is_binary(window_id) ->
        process_ingestion_window(window_id)

      _ ->
        {:error, :missing_window_id}
    end
  end

  def execute(%BackgroundJob{job_type: "relationship_backfill"} = job) do
    with {:ok, user_id} <- require_user_id(job) do
      source = payload_string(job, "source", nil)

      if is_binary(source) do
        process_backfill_page(user_id, source, job)
      else
        {:error, :missing_backfill_source}
      end
    end
  end

  def execute(%BackgroundJob{job_type: job_type}),
    do: {:error, {:unknown_background_job, job_type}}

  defp process_ingestion_window(window_id) do
    case Repo.get(Window, window_id) do
      nil ->
        {:error, :window_not_found}

      %Window{status: "completed"} ->
        {:ok, %{source: "crm_ingest", window_id: window_id, skipped: "already_completed"}}

      %Window{} = window ->
        observations =
          Repo.all(
            from o in Observation, where: o.window_id == ^window_id, order_by: o.occurred_at
          )

        run_ingestion_passes(window, observations)
    end
  end

  defp run_ingestion_passes(%Window{} = window, observations) do
    user_id = window.user_id
    now = DateTime.utc_now()

    with {:ok, relationship_result} <-
           run_relationship_pass(user_id, observations, now),
         {:ok, open_loop_result} <- run_open_loop_pass(user_id, observations, now) do
      mark_window_completed(window, observations, now, relationship_result, open_loop_result)
      record_completion_event(window, observations, relationship_result, open_loop_result, now)

      {:ok,
       %{
         source: "crm_ingest",
         window_id: window.id,
         observations_count: length(observations),
         relationship: relationship_result,
         open_loop: open_loop_result
       }}
    else
      {:error, stage, reason} ->
        mark_window_failed(window, "#{stage}:#{inspect(reason)}", now)
        {:error, reason}
    end
  end

  defp run_relationship_pass(_user_id, [], _now), do: {:ok, %{skipped: "no_observations"}}

  defp run_relationship_pass(user_id, observations, now) do
    intelligence_input = Enum.map(observations, &Observation.to_intelligence_input/1)

    case RelationshipIntelligence.learn_from_observations(user_id, intelligence_input,
           source: "crm_ingest",
           now: now
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, :relationship_pass, reason}
    end
  end

  defp run_open_loop_pass(_user_id, [], _now), do: {:ok, %{skipped: "no_observations"}}

  defp run_open_loop_pass(user_id, observations, now) do
    intelligence_input = Enum.map(observations, &Observation.to_intelligence_input/1)

    case OpenLoops.reconcile_from_observations(user_id, intelligence_input,
           source: "crm_ingest",
           now: now
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, :open_loop_pass, reason}
    end
  end

  defp mark_window_completed(%Window{} = window, observations, now, _r, _o) do
    obs_ids = Enum.map(observations, & &1.id)

    if obs_ids != [] do
      Repo.update_all(
        from(o in Observation, where: o.id in ^obs_ids),
        set: [learned_at: now, updated_at: now]
      )
    end

    Repo.update_all(
      from(w in Window, where: w.id == ^window.id),
      set: [
        status: "completed",
        completed_at: now,
        last_error: nil,
        updated_at: now
      ]
    )
  end

  defp mark_window_failed(%Window{} = window, last_error, now) do
    Repo.update_all(
      from(w in Window, where: w.id == ^window.id),
      set: [
        status: "failed",
        failed_at: now,
        last_error: String.slice(last_error || "", 0, 1_000),
        updated_at: now
      ]
    )
  end

  defp record_completion_event(
         %Window{} = window,
         observations,
         relationship_result,
         open_loop_result,
         now
       ) do
    people_touched =
      observations
      |> Enum.flat_map(&(&1.resolved_person_ids || []))
      |> Enum.uniq()
      |> length()

    todos_touched =
      open_loop_result
      |> Map.get(:todo_changes, [])
      |> length()

    _ =
      OperatorEvents.record(%{
        user_id: window.user_id,
        source: "crm_ingest",
        event_type: "crm_ingest.completed",
        source_item_id: window.id,
        dedupe_key: "crm_ingest:completed:#{window.id}",
        occurred_at: now,
        payload: %{
          "window_id" => window.id,
          "source" => window.source,
          "observations_count" => length(observations),
          "people_touched" => people_touched,
          "todos_touched" => todos_touched,
          "relationship_summary" => Map.get(relationship_result, :summary),
          "open_loop_summary" => Map.get(open_loop_result, :ingested) |> summarize_ingested()
        }
      })

    :ok
  end

  defp summarize_ingested(nil), do: nil

  defp summarize_ingested(%{} = ingested) do
    %{
      "todos" => Map.get(ingested, :todos, []) |> length(),
      "decisions" => Map.get(ingested, :decisions, []) |> length()
    }
  end

  defp summarize_ingested(_), do: nil

  defp process_backfill_page(user_id, source, %BackgroundJob{} = job) do
    max_observations = payload_integer(job, "max_observations", 5_000)
    observations_so_far = payload_integer(job, "observations_so_far", 0)

    if observations_so_far >= max_observations do
      _ = Ingest.flush_pending(user_id, source)

      {:ok,
       %{
         source: "crm_backfill",
         user_id: user_id,
         backfill_source: source,
         status: "ceiling_reached",
         observations: observations_so_far
       }}
    else
      # v1: backfill is a no-op landing surface. Real connector pagers will be
      # wired per source in a follow-up; flushing any pending observations
      # keeps the chain idempotent in the meantime.
      _ = Ingest.flush_pending(user_id, source)

      Logger.info("relationship_backfill page accepted",
        user_id: user_id,
        source: source,
        observations_so_far: observations_so_far
      )

      {:ok,
       %{
         source: "crm_backfill",
         user_id: user_id,
         backfill_source: source,
         status: "noop",
         observations: observations_so_far
       }}
    end
  end

  defp require_user_id(%BackgroundJob{user_id: user_id})
       when is_binary(user_id) and user_id != "",
       do: {:ok, user_id}

  defp require_user_id(_job), do: {:error, :missing_user_id}

  defp payload_string(%BackgroundJob{payload: payload}, key, default) when is_map(payload) do
    case Map.get(payload, key, default) do
      nil -> default
      "" -> default
      value when is_binary(value) -> String.trim(value)
      value -> to_string(value)
    end
  end

  defp payload_string(_job, _key, default), do: default

  defp payload_integer(%BackgroundJob{payload: payload}, key, default) when is_map(payload) do
    case Map.get(payload, key, default) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _ -> default
    end
  end

  defp payload_integer(_job, _key, default), do: default

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> default
    end
  end
end
