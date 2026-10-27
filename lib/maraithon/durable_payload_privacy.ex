defmodule Maraithon.DurablePayloadPrivacy do
  @moduledoc """
  Evidence-bound, content-free contraction for Event, AgentRunStep, and
  bigint-identity Snapshot payloads.

  Additive legacy writers keep the exact JSON projection until each bounded
  batch crosses the authoritative stopped-fleet barrier. No confirmation-only
  mutation path remains.
  """

  alias Maraithon.Agents
  alias Maraithon.DurablePayloadContraction
  alias Maraithon.Events
  alias Maraithon.Repo
  alias Maraithon.Runtime.Snapshot

  @default_batch_size 25
  @max_batch_size 100
  @default_max_batches 20
  @max_batches 1_000
  @max_blocked_rows 10_000

  @doc "Returns content-free legacy payload and canonical work counts."
  def preflight do
    run_steps = Agents.legacy_run_step_payload_encryption_backlogs()

    %{
      legacy_events: Events.legacy_payload_encryption_backlog(),
      legacy_run_steps: run_steps.eligible,
      deferred_run_steps: run_steps.deferred,
      legacy_snapshots: Snapshot.legacy_payload_encryption_backlog(),
      in_flight: DurablePayloadContraction.work_preflight()
    }
  end

  @doc "Promotes one bounded batch behind exact stopped-fleet evidence."
  def backfill_batch(opts \\ [])

  def backfill_batch(opts) when is_list(opts) do
    with {:ok, config} <- backfill_options(opts),
         {:ok, result} <-
           DurablePayloadContraction.transaction(evidence_opts(config), fn ->
             events =
               unwrap!(
                 Events.backfill_legacy_payload_encryption(
                   limit: config.batch_size,
                   skip: config.event_skip
                 )
               )

             run_steps =
               unwrap!(
                 Agents.backfill_legacy_run_step_payload_encryption(
                   limit: config.batch_size,
                   skip: config.run_step_skip
                 )
               )

             snapshots =
               unwrap!(
                 Snapshot.backfill_legacy_payload_encryption(
                   limit: config.batch_size,
                   skip: config.snapshot_skip
                 )
               )

             %{
               migrated_events: events.migrated_events,
               migrated_run_steps: run_steps.migrated_run_steps,
               migrated_snapshots: snapshots.migrated_snapshots,
               blocked_events: events.blocked_events,
               blocked_run_steps: run_steps.blocked_run_steps,
               blocked_snapshots: snapshots.blocked_snapshots
             }
           end) do
      {:ok, result}
    end
  end

  def backfill_batch(_opts), do: {:error, :invalid_durable_payload_backfill_options}

  @doc "Runs bounded authoritative batches and reports the remaining backlog."
  def backfill(opts \\ [])

  def backfill(opts) when is_list(opts) do
    with {:ok, config} <- backfill_options(opts) do
      initial = %{
        batches: 0,
        migrated_events: 0,
        migrated_run_steps: 0,
        migrated_snapshots: 0,
        blocked_events: [],
        blocked_run_steps: [],
        blocked_snapshots: [],
        event_skip: config.event_skip,
        run_step_skip: config.run_step_skip,
        snapshot_skip: config.snapshot_skip
      }

      case run_batches(initial, config) do
        {:ok, result} ->
          {:ok,
           result
           |> Map.drop([:event_skip, :run_step_skip, :snapshot_skip])
           |> Map.put(:remaining, preflight())}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def backfill(_opts), do: {:error, :invalid_durable_payload_backfill_options}

  defp run_batches(%{batches: batches} = state, %{max_batches: max_batches})
       when batches >= max_batches,
       do: {:ok, state}

  defp run_batches(state, config) do
    opts =
      evidence_opts(config) ++
        [
          batch_size: config.batch_size,
          max_batches: config.max_batches,
          event_skip: state.event_skip,
          run_step_skip: state.run_step_skip,
          snapshot_skip: state.snapshot_skip
        ]

    case backfill_batch(opts) do
      {:ok, batch} ->
        state = merge_batch(state, batch)

        cond do
          blocked_count(state) > @max_blocked_rows ->
            {:error, :durable_payload_backfill_blocked_row_limit}

          migrated_count(batch) == 0 and blocked_count(batch) == 0 ->
            {:ok, state}

          true ->
            run_batches(state, config)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp merge_batch(state, batch) do
    %{
      state
      | batches: state.batches + 1,
        migrated_events: state.migrated_events + batch.migrated_events,
        migrated_run_steps: state.migrated_run_steps + batch.migrated_run_steps,
        migrated_snapshots: state.migrated_snapshots + batch.migrated_snapshots,
        blocked_events: state.blocked_events ++ batch.blocked_events,
        blocked_run_steps: state.blocked_run_steps ++ batch.blocked_run_steps,
        blocked_snapshots: state.blocked_snapshots ++ batch.blocked_snapshots,
        event_skip: state.event_skip + length(batch.blocked_events),
        run_step_skip: state.run_step_skip + length(batch.blocked_run_steps),
        snapshot_skip: state.snapshot_skip + length(batch.blocked_snapshots)
    }
  end

  defp migrated_count(batch),
    do: batch.migrated_events + batch.migrated_run_steps + batch.migrated_snapshots

  defp blocked_count(report) do
    length(report.blocked_events) + length(report.blocked_run_steps) +
      length(report.blocked_snapshots)
  end

  defp backfill_options(opts) do
    allowed = [
      :batch_size,
      :max_batches,
      :event_skip,
      :run_step_skip,
      :snapshot_skip,
      :confirmation,
      :evidence_id,
      :evidence_digest,
      :operator,
      :revision
    ]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
      max_batches = Keyword.get(opts, :max_batches, @default_max_batches)
      event_skip = Keyword.get(opts, :event_skip, 0)
      run_step_skip = Keyword.get(opts, :run_step_skip, 0)
      snapshot_skip = Keyword.get(opts, :snapshot_skip, 0)

      if is_integer(batch_size) and batch_size in 1..@max_batch_size and
           is_integer(max_batches) and max_batches in 1..@max_batches and
           is_integer(event_skip) and event_skip in 0..@max_blocked_rows and
           is_integer(run_step_skip) and run_step_skip in 0..@max_blocked_rows and
           is_integer(snapshot_skip) and snapshot_skip in 0..@max_blocked_rows do
        {:ok,
         %{
           batch_size: batch_size,
           max_batches: max_batches,
           event_skip: event_skip,
           run_step_skip: run_step_skip,
           snapshot_skip: snapshot_skip,
           confirmation: Keyword.get(opts, :confirmation),
           evidence_id: Keyword.get(opts, :evidence_id),
           evidence_digest: Keyword.get(opts, :evidence_digest),
           operator: Keyword.get(opts, :operator),
           revision: Keyword.get(opts, :revision)
         }}
      else
        {:error, :invalid_durable_payload_backfill_options}
      end
    else
      {:error, :invalid_durable_payload_backfill_options}
    end
  end

  defp evidence_opts(config) do
    [
      confirmation: config.confirmation,
      evidence_id: config.evidence_id,
      evidence_digest: config.evidence_digest,
      operator: config.operator,
      revision: config.revision
    ]
  end

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
