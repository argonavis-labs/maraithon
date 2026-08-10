defmodule Maraithon.DurablePayloadPrivacy do
  @moduledoc """
  Operator-facing, content-free coordination for staged Event and AgentRunStep
  payload encryption.

  Run `preflight/0`, stop legacy writers, repeatedly call `backfill/1`, and
  prove every non-deferred backlog is zero before activating the exact payload
  protocol. The functions return identifiers and closed error codes only;
  payload content is never included in results or logs.
  """

  alias Maraithon.Agents
  alias Maraithon.Events

  @default_batch_size 25
  @max_batch_size 100
  @default_max_batches 20
  @max_batches 1_000
  @max_blocked_rows 10_000

  @doc "Returns content-free legacy payload backlog counts."
  def preflight do
    run_steps = Agents.legacy_run_step_payload_encryption_backlogs()

    %{
      legacy_events: Events.legacy_payload_encryption_backlog(),
      legacy_run_steps: run_steps.eligible,
      deferred_run_steps: run_steps.deferred
    }
  end

  @doc "Promotes one bounded Event and terminal/inactive RunStep batch."
  def backfill_batch(opts \\ [])

  def backfill_batch(opts) when is_list(opts) do
    with {:ok, config} <- backfill_options(opts),
         {:ok, events} <-
           Events.backfill_legacy_payload_encryption(
             limit: config.batch_size,
             skip: config.event_skip
           ),
         {:ok, run_steps} <-
           Agents.backfill_legacy_run_step_payload_encryption(
             limit: config.batch_size,
             skip: config.run_step_skip
           ) do
      {:ok,
       %{
         migrated_events: events.migrated_events,
         migrated_run_steps: run_steps.migrated_run_steps,
         blocked_events: events.blocked_events,
         blocked_run_steps: run_steps.blocked_run_steps
       }}
    end
  end

  def backfill_batch(_opts), do: {:error, :invalid_durable_payload_backfill_options}

  @doc "Runs bounded batches and reports the remaining content-free backlog."
  def backfill(opts \\ [])

  def backfill(opts) when is_list(opts) do
    with {:ok, config} <- backfill_options(opts) do
      initial = %{
        batches: 0,
        migrated_events: 0,
        migrated_run_steps: 0,
        blocked_events: [],
        blocked_run_steps: [],
        event_skip: config.event_skip,
        run_step_skip: config.run_step_skip
      }

      case run_batches(initial, config) do
        {:ok, result} ->
          {:ok,
           result
           |> Map.drop([:event_skip, :run_step_skip])
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
    case backfill_batch(
           batch_size: config.batch_size,
           event_skip: state.event_skip,
           run_step_skip: state.run_step_skip
         ) do
      {:ok, batch} ->
        state = merge_batch(state, batch)

        cond do
          length(state.blocked_events) > @max_blocked_rows or
              length(state.blocked_run_steps) > @max_blocked_rows ->
            {:error, :durable_payload_backfill_blocked_row_limit}

          batch.migrated_events == 0 and batch.migrated_run_steps == 0 and
            batch.blocked_events == [] and batch.blocked_run_steps == [] ->
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
        blocked_events: state.blocked_events ++ batch.blocked_events,
        blocked_run_steps: state.blocked_run_steps ++ batch.blocked_run_steps,
        event_skip: state.event_skip + length(batch.blocked_events),
        run_step_skip: state.run_step_skip + length(batch.blocked_run_steps)
    }
  end

  defp backfill_options(opts) do
    if Keyword.keyword?(opts) do
      batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
      max_batches = Keyword.get(opts, :max_batches, @default_max_batches)
      event_skip = Keyword.get(opts, :event_skip, 0)
      run_step_skip = Keyword.get(opts, :run_step_skip, 0)

      if is_integer(batch_size) and batch_size in 1..@max_batch_size and
           is_integer(max_batches) and max_batches in 1..@max_batches and
           is_integer(event_skip) and event_skip in 0..@max_blocked_rows and
           is_integer(run_step_skip) and run_step_skip in 0..@max_blocked_rows do
        {:ok,
         %{
           batch_size: batch_size,
           max_batches: max_batches,
           event_skip: event_skip,
           run_step_skip: run_step_skip
         }}
      else
        {:error, :invalid_durable_payload_backfill_options}
      end
    else
      {:error, :invalid_durable_payload_backfill_options}
    end
  end
end
