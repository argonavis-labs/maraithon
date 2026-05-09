defmodule Maraithon.Runtime.BackgroundJobHandler do
  @moduledoc """
  Executes app-level background jobs.

  Keep handlers small and explicit. Source scanners and interactive flows should
  enqueue one of these job types, then return quickly while the queue performs
  the slower work under supervision.
  """

  alias Maraithon.Insights.Refresh
  alias Maraithon.OpenLoops
  alias Maraithon.OperatorEvents
  alias Maraithon.RelationshipIntelligence
  alias Maraithon.Runtime.BackgroundJob

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

  def execute(%BackgroundJob{job_type: job_type}),
    do: {:error, {:unknown_background_job, job_type}}

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
