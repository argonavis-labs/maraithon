defmodule Maraithon.Runtime.TodoWorkflowReview do
  @moduledoc """
  Continuous workflow review on the existing durable, fair per-user lane.

  Each wake reads bounded synced context. Successful input fingerprints and
  calendar evidence live in the encrypted job result, committed by the fenced
  runner. A restart can repeat a review but cannot bypass workflow revisions or
  replay an external action. No process or timer is allocated per todo.
  """
  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.SourceCursor
  alias Maraithon.Repo
  alias Maraithon.Runtime.{BackgroundJob, TodoCompletionSweep}

  @calendar_refresh_seconds 30 * 60
  @calendar_evidence_version 2

  def run(%BackgroundJob{user_id: user_id} = job) do
    now = DateTime.utc_now()
    previous = previous_review(job)
    calendar_version = calendar_version(user_id)
    reuse_calendar? = reusable_calendar?(previous, calendar_version, now)

    opts = [
      now: now,
      skip_account_message_sources: true,
      review_memo: Map.get(previous, "review_memo", %{})
    ]

    opts =
      if reuse_calendar?,
        do: Keyword.put(opts, :cached_calendar_evidence, previous["calendar_evidence"]),
        else: opts

    case TodoCompletionSweep.run_for_user(user_id, opts) do
      %{cross_source: %{} = review} = result ->
        {:ok,
         result
         |> Map.drop([:cross_source])
         |> Map.put(:cross_source, Map.drop(review, [:review_memo, :calendar_evidence]))
         |> Map.put(:review_memo, Map.get(review, :review_memo, %{}))
         |> Map.put(:calendar_evidence, Map.get(review, :calendar_evidence, []))
         |> Map.put(:calendar_version, calendar_version)
         |> Map.put(
           :calendar_refreshed_at,
           if(reuse_calendar?,
             do: previous["calendar_refreshed_at"],
             else: DateTime.to_iso8601(now)
           )
         )
         |> Map.put(:calendar_reused, reuse_calendar?)}

      %{cross_source: {:skip, :no_open_todos}} ->
        {:ok, %{outcome: "no_open_todos", review_memo: %{}}}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :workflow_review_incomplete}
    end
  end

  defp previous_review(job) do
    BackgroundJob
    |> where([j], j.user_id == ^job.user_id and j.job_type == ^job.job_type)
    |> where([j], j.status == "completed" and is_nil(j.payload_purged_at))
    |> order_by([j], desc: j.completed_at, desc: j.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> %{}
      previous -> BackgroundJob.hydrate_payloads(previous).result || %{}
    end
  end

  # Only calendar data cursors invalidate the cached provider read. Watch
  # renewals and wall-clock freshness updates do not represent new content.
  defp calendar_version(user_id) do
    cursors =
      SourceCursor
      |> where([c], c.user_id == ^user_id and c.kind == "calendar_sync_token")
      |> order_by([c], asc: c.connected_account_id)
      |> select([c], {c.connected_account_id, c.value})
      |> Repo.all()

    accounts =
      ConnectedAccount
      |> where([a], a.user_id == ^user_id and like(a.provider, "google%"))
      |> order_by([a], asc: a.id)
      |> select([a], {a.id, a.status, a.scopes})
      |> Repo.all()

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({@calendar_evidence_version, cursors, accounts}, [:deterministic])
    )
    |> Base.encode16(case: :lower)
  end

  defp reusable_calendar?(previous, version, now) do
    degraded = get_in(previous, ["cross_source", "degraded_sources"]) || []

    with false <- "calendar" in degraded,
         ^version <- previous["calendar_version"],
         evidence when is_list(evidence) <- previous["calendar_evidence"],
         timestamp when is_binary(timestamp) <- previous["calendar_refreshed_at"],
         {:ok, refreshed, _} <- DateTime.from_iso8601(timestamp) do
      age = DateTime.diff(now, refreshed)
      age >= 0 and age < @calendar_refresh_seconds
    else
      _ -> false
    end
  end
end
