defmodule Maraithon.Runtime.SourceClosureRecovery do
  @moduledoc """
  Resumes an interrupted closure window through a new immutable publication.

  Completed children retain their original jobs and exact outcome evidence.
  Abandoned children are copied into fresh jobs by the normal publisher. This
  module only reads; it never resets an ambiguous task or advances a cursor.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob

  @acquire "runtime_partition:source_account_closure_acquire"
  @reason "runtime_partition:source_account_closure_reason"
  @finalize "runtime_partition:source_account_closure_finalize"
  # Exhausted model retries leave the same sealed source window unfinished.
  # Recover those children in fresh jobs too, retaining the proven completed
  # siblings instead of acquiring and evaluating the entire window again.
  @interrupted_errors ~w(
    provider_outcome_ambiguous source_graph_abandoned source_closure_child_failed
    timeout cross_source_completion_incomplete_decisions
  )
  @result_fields ~w(account_id source_items source_partition_count todo_count todo_batch_count fanout_count)a

  # Version 2 confines decisions to the sealed bundle. Version 1 could include
  # unbound CRM/local evidence, so its completed batches cannot prove v2 work.
  # Bump this when completion semantics invalidate previously evaluated batches.
  @evaluation_version 2
  def evaluation_version, do: @evaluation_version

  def compatible_evaluation?(result) when is_map(result),
    do: Map.get(result, "closure_evaluation_version", 1) == @evaluation_version

  def compatible_evaluation?(_result), do: false

  @doc "Returns a publication plan for the latest interrupted live closure window."
  def recover(%ConnectedAccount{status: "connected"} = account, %BackgroundJob{} = current) do
    pattern = "runtime-partition:source-account-closure-acquire:#{account.id}:%"

    previous =
      BackgroundJob
      |> where([job], job.user_id == ^account.user_id and job.job_type == @acquire)
      |> where([job], job.status == "completed" and like(job.dedupe_key, ^pattern))
      |> where([job], job.inserted_at < ^current.inserted_at)
      |> order_by([job], desc: job.inserted_at, desc: job.id)
      |> limit(1)
      |> Repo.one()

    with true <- current.user_id == account.user_id and current.job_type == @acquire,
         %BackgroundJob{payload_purged_at: nil} <- previous,
         previous <- BackgroundJob.hydrate_payloads(previous),
         true <- compatible_acquisition?(previous, account),
         {:ok, finalizer, reasons} <- load_graph(previous, account),
         true <- interrupted_graph?(finalizer, reasons),
         {:ok, watermark} <- recovery_watermark(finalizer, account),
         true <- valid_handoffs?(previous, reasons, account),
         true <- completed_outcomes_proven?([previous | reasons]) do
      {:ok, publication(previous, finalizer, reasons, current, watermark)}
    else
      _unrecoverable -> :none
    end
  end

  def recover(_account, _current), do: :none

  defp compatible_acquisition?(previous, account) do
    result = previous.result

    previous.payload["account_id"] == account.id and
      result["account_id"] == account.id and
      is_nil(previous.payload["source_replay_mode"]) and
      result["outcome"] == "fanout_ready" and
      result["closure_partitioning_version"] == 1 and
      compatible_evaluation?(result) and
      is_list(result["reason_job_ids"]) and result["reason_job_ids"] != [] and
      length(result["reason_job_ids"]) == result["fanout_count"] and
      length(Enum.uniq(result["reason_job_ids"])) == result["fanout_count"]
  end

  defp load_graph(previous, account) do
    reason_ids = previous.result["reason_job_ids"]
    finalizer_id = previous.result["finalizer_job_id"]
    ids = [finalizer_id | reason_ids]

    with true <- Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))),
         %BackgroundJob{job_type: @finalize, payload_purged_at: nil} = finalizer <-
           Repo.get(BackgroundJob, finalizer_id),
         true <- finalizer.user_id == account.user_id and interrupted?(finalizer),
         statuses <-
           Repo.all(
             from(job in BackgroundJob,
               where: job.id in ^reason_ids and job.user_id == ^account.user_id,
               select: %{status: job.status, last_error: job.last_error}
             )
           ),
         true <-
           length(statuses) == length(reason_ids) and interrupted_graph?(finalizer, statuses) do
      finalizer = BackgroundJob.hydrate_payloads(finalizer)

      jobs =
        reason_ids
        |> Enum.chunk_every(32)
        |> Enum.flat_map(fn batch ->
          BackgroundJob
          |> where([job], job.id in ^batch and job.user_id == ^account.user_id)
          |> where([job], is_nil(job.payload_purged_at))
          |> Repo.all()
          |> Enum.map(&BackgroundJob.hydrate_payloads/1)
        end)
        |> Map.new(&{&1.id, &1})

      reasons = Enum.map(reason_ids, &jobs[&1])

      if map_size(jobs) == length(reason_ids) and
           finalizer.payload["acquisition_job_id"] == previous.id and
           finalizer.payload["account_id"] == account.id and
           finalizer.payload["reason_job_ids"] == reason_ids and
           Enum.all?(reasons, &match?(%BackgroundJob{job_type: @reason}, &1)),
         do: {:ok, finalizer, reasons},
         else: :none
    else
      _not_interrupted -> :none
    end
  end

  defp interrupted_graph?(finalizer, reasons) do
    interrupted?(finalizer) and
      Enum.all?(reasons, &(&1.status == "completed" or interrupted?(&1))) and
      Enum.any?(reasons, &(&1.status == "completed"))
  end

  defp interrupted?(job),
    do: job.status in ["failed", "cancelled"] and job.last_error in @interrupted_errors

  defp recovery_watermark(finalizer, account) do
    kind =
      if String.starts_with?(account.provider, "slack:"),
        do: "slack_closure_watermark",
        else: "gmail_closure_watermark"

    cursor = SourceCursors.get(account.id, kind)
    lower = cursor && cursor.value

    with [%{"account_id" => account_id, "kind" => ^kind, "value" => upper} = watermark] <-
           finalizer.payload["watermarks"],
         true <- account_id == account.id,
         true <- same_lower_cursor?(watermark, cursor),
         {upper_value, ""} when upper_value >= 0 <- Integer.parse(upper),
         true <- after_lower?(upper_value, lower) do
      {:ok, Map.put(watermark, "expected_lower_value", lower)}
    else
      _changed_window -> :none
    end
  end

  defp same_lower_cursor?(%{"expected_lower_value" => expected}, cursor),
    do: expected == (cursor && cursor.value)

  defp same_lower_cursor?(_watermark, _cursor), do: false

  defp after_lower?(_upper, nil), do: true

  defp after_lower?(upper, lower) when is_binary(lower) do
    case Integer.parse(lower) do
      {value, ""} when value >= 0 -> upper > value
      _invalid -> false
    end
  end

  defp valid_handoffs?(previous, reasons, account) do
    reused_ids = previous.result |> Map.get("reused_reason_job_ids", []) |> MapSet.new()

    reasons
    |> Enum.with_index(1)
    |> Enum.all?(fn {job, index} ->
      payload = job.payload

      payload["account_id"] == account.id and
        (payload["acquisition_job_id"] == previous.id or
           (job.status == "completed" and MapSet.member?(reused_ids, job.id))) and
        payload["fanout_index"] == index and
        payload["fanout_count"] == previous.result["fanout_count"] and
        payload["source_partition_count"] == previous.result["source_partition_count"] and
        payload["todo_batch_count"] == previous.result["todo_batch_count"] and
        is_nil(payload["source_replay_mode"]) and
        (job.status != "completed" or completed_payload_matches?(job))
    end)
  end

  defp completed_payload_matches?(job) do
    job.result["outcome"] == "evaluated" and
      Enum.all?(
        ~w(account_id fanout_index fanout_count source_partition_index source_partition_count todo_batch_index todo_batch_count source_items source_item_refs source_refs_digest todo_ids),
        &(Map.has_key?(job.payload, &1) and job.payload[&1] == job.result[&1])
      )
  end

  defp completed_outcomes_proven?(reasons) do
    ids = for job <- reasons, job.status == "completed", do: Ecto.UUID.dump!(job.id)

    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(DISTINCT job.id)
        FROM background_jobs job
        JOIN runtime_task_assignments task ON task.id = job.coordination_task_assignment_id
          AND task.work_kind = 'background_job' AND task.work_id = job.id
        JOIN runtime_task_outcome_evidence evidence ON evidence.assignment_id = task.id
          AND evidence.activation_epoch = task.activation_epoch
          AND evidence.claim_token = task.claim_token
          AND evidence.node_incarnation_id = task.node_incarnation_id
          AND evidence.supervisor_id = task.supervisor_id
          AND evidence.local_task_id = task.local_task_id
          AND evidence.outcome = task.outcome
        WHERE job.id = ANY($1::uuid[]) AND job.status = 'completed'
          AND task.state = 'settled' AND task.provider_boundary = 'outcome_known'
          AND task.outcome = 'completed'
        """,
        [ids]
      )

    count == length(ids)
  end

  defp publication(previous, finalizer, reasons, current, watermark) do
    handoffs =
      Enum.map(reasons, fn
        %BackgroundJob{status: "completed"} = job -> {:reuse, job}
        job -> Map.put(job.payload, "acquisition_job_id", current.id)
      end)

    @result_fields
    |> Map.new(&{&1, Map.fetch!(previous.result, Atom.to_string(&1))})
    |> Map.merge(%{
      outcome: "fanout_ready",
      closure_partitioning_version: 1,
      closure_evaluation_version: @evaluation_version,
      recovered_from_acquisition_job_id: previous.id,
      reused_reason_job_ids: for(job <- reasons, job.status == "completed", do: job.id),
      handoffs: handoffs,
      finalizer:
        finalizer.payload
        |> Map.delete("reason_job_ids")
        |> Map.put("acquisition_job_id", current.id)
        |> Map.put("watermarks", [watermark])
    })
  end
end
