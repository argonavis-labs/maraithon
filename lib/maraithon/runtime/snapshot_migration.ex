defmodule Maraithon.Runtime.SnapshotMigration do
  @moduledoc """
  Resumable, bounded migration of durable Agent snapshots to tagged JSON v1.

  Every scan and mutation is paged by the snapshot's bigint id. A committed
  batch can safely be retried from an earlier cursor: v1 rows are only
  revalidated, conversions are idempotent, and quarantine reports use the
  source snapshot id as their conflict key.

  Invalid payloads are never copied to the report table. Invalid rows owned by
  an active Agent remain in place until that Agent writes a newer, fully valid
  v1 checkpoint; stopped/removed Agents can be quarantined immediately. Global
  pruning is intentionally delayed until conversion has no invalid rows left,
  then applies to every Agent status.

  `finalize/1` is the format proof. It locks writes, repeats the bounded
  application-level grammar validation, requires zero legacy/invalid/excess
  rows, adds the tagged-v1 database check, and validates all snapshot checks.
  Once that succeeds, the temporary legacy reader is operationally removable.
  """

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Runtime.Snapshot
  alias Maraithon.Runtime.SnapshotFormat
  alias Maraithon.Runtime.SnapshotQuarantine

  require Logger

  @default_batch_size 10
  @max_batch_size 25
  @default_prune_batch_size 500
  @max_prune_batch_size 5_000
  @default_max_batches 100
  @max_max_batches 10_000
  @lock_timeout_ms 5_000
  @query_timeout_ms 30_000
  @format_constraint "snapshots_tagged_v1_payloads"
  @snapshot_constraints [
    "snapshots_nonnegative_sequence",
    "snapshots_schema_version_range",
    "snapshots_payload_objects",
    "snapshots_payload_storage_bound",
    @format_constraint
  ]
  @constraint_definitions %{
    "snapshots_nonnegative_sequence" => "CHECK (sequence_num >= 0)",
    "snapshots_schema_version_range" =>
      "CHECK (schema_version >= 0 AND schema_version <= 2147483647)",
    "snapshots_payload_objects" =>
      "CHECK (jsonb_typeof(state_data) = 'object'::text AND jsonb_typeof(budget) = 'object'::text)",
    "snapshots_payload_storage_bound" =>
      "CHECK ((pg_column_size(state_data) + pg_column_size(budget)) <= 1200000)",
    @format_constraint =>
      "CHECK (((state_data ->> 'format'::text) = 'maraithon.agent_snapshot'::text AND " <>
        "(state_data -> 'format_version'::text) = '1'::jsonb AND " <>
        "(budget ->> 'format'::text) = 'maraithon.agent_snapshot'::text AND " <>
        "(budget -> 'format_version'::text) = '1'::jsonb) IS TRUE)"
  }

  @type preflight_stats :: %{
          total_snapshot_count: non_neg_integer(),
          tagged_v1_snapshot_count: non_neg_integer(),
          legacy_snapshot_count: non_neg_integer(),
          invalid_snapshot_count: non_neg_integer(),
          active_invalid_without_fresh_checkpoint_count: non_neg_integer(),
          agents_over_retention: non_neg_integer(),
          over_retention_snapshot_count: non_neg_integer(),
          blocked_quarantine_report_count: non_neg_integer(),
          quarantined_report_count: non_neg_integer(),
          format_constraint_installed: boolean(),
          format_constraint_validated: boolean()
        }

  @doc """
  Count tagged, safely migratable legacy, invalid, and over-retention rows.

  Payloads are fetched in bounded pages. Oversized JSONB values are counted as
  invalid without being transferred into the BEAM. The exact counts are also
  emitted at `[:maraithon, :runtime, :snapshot, :migration, :preflight]`.
  """
  @spec preflight(keyword()) :: {:ok, preflight_stats()} | {:error, term()}
  def preflight(opts \\ [])

  def preflight(opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, batch_size} <- batch_size(opts),
         {:ok, scanned} <- scan_preflight(repo, 0, batch_size, empty_preflight()),
         {:ok, retention} <- retention_stats(repo),
         {:ok, reports} <- quarantine_report_stats(repo),
         {:ok, constraint} <- format_constraint_status(repo) do
      stats =
        scanned
        |> Map.merge(retention)
        |> Map.merge(reports)
        |> Map.merge(constraint)

      if Keyword.get(opts, :emit_telemetry, true), do: emit_preflight(stats)
      {:ok, stats}
    end
  end

  def preflight(_opts), do: {:error, :invalid_options}

  @doc """
  Migrate at most one bounded page after `:after_id`.

  The result contains `:next_cursor`. Supplying that value on the next call
  resumes after the last committed row. Retrying an older cursor is safe.
  """
  @spec migrate_batch(keyword()) :: {:ok, map()} | {:error, term()}
  def migrate_batch(opts \\ [])

  def migrate_batch(opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    after_id = Keyword.get(opts, :after_id, 0)

    with {:ok, batch_size} <- batch_size(opts),
         true <- is_integer(after_id) and after_id >= 0 do
      result =
        repo.transaction(
          fn ->
            set_local_lock_timeout!(repo)

            case load_rows(repo, after_id, batch_size, lock?: true) do
              {:ok, rows} -> process_rows!(repo, rows, after_id, batch_size)
              {:error, reason} -> repo.rollback(reason)
            end
          end,
          timeout: @query_timeout_ms
        )

      case result do
        {:ok, summary} ->
          :telemetry.execute(
            [:maraithon, :runtime, :snapshot, :migration, :batch],
            numeric_measurements(summary),
            %{
              format_version: SnapshotFormat.version(),
              retention_count: Snapshot.retention_count()
            }
          )

          {:ok, summary}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :invalid_after_id}
      {:error, _reason} = error -> error
    end
  end

  def migrate_batch(_opts), do: {:error, :invalid_options}

  @doc """
  Run a bounded number of resumable conversion batches and, only after a clean
  format preflight, globally prune all Agents to the newest ten snapshots.
  """
  @spec migrate(keyword()) :: {:ok, map()} | {:error, term()}
  def migrate(opts \\ [])

  def migrate(opts) when is_list(opts) do
    after_id = Keyword.get(opts, :after_id, 0)

    with true <- is_integer(after_id) and after_id >= 0,
         {:ok, max_batches} <- max_batches(opts),
         {:ok, before} <- preflight(opts),
         {:ok, conversion} <- migrate_batches(opts, after_id, max_batches),
         {:ok, after_conversion} <- preflight(opts),
         {:ok, prune} <- maybe_prune(opts, conversion, after_conversion),
         {:ok, after_stats} <- preflight(opts) do
      complete? =
        conversion.pass_complete and clean_format?(after_stats) and
          after_stats.agents_over_retention == 0

      summary = %{
        before: before,
        conversion: conversion,
        prune: prune,
        after: after_stats,
        complete: complete?,
        next_cursor:
          cond do
            complete? -> nil
            conversion.pass_complete -> 0
            true -> conversion.next_cursor
          end
      }

      :telemetry.execute(
        [:maraithon, :runtime, :snapshot, :migration, :run],
        numeric_measurements(
          Map.merge(conversion, %{
            pruned: Map.get(prune, :deleted, 0),
            complete: if(complete?, do: 1, else: 0)
          })
        ),
        %{format_version: SnapshotFormat.version(), pass_complete: conversion.pass_complete}
      )

      {:ok, summary}
    else
      false -> {:error, :invalid_after_id}
      {:error, _reason} = error -> error
    end
  end

  def migrate(_opts), do: {:error, :invalid_options}

  @doc """
  Repeatedly apply the bounded global prune after proving every source row is
  valid v1. `:max_batches` keeps one invocation finite; rerunning is idempotent.

  No Agent status predicate is used, so stopped, paused, removed, and active
  Agents all obey the same retention bound. The proof and deletes share a table
  lock, preventing retention from racing a legacy/invalid insert and bypassing
  quarantine safety.
  """
  @spec prune_all(keyword()) :: {:ok, map()} | {:error, term()}
  def prune_all(opts \\ [])

  def prune_all(opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, max_batches} <- max_batches(opts),
         {:ok, _prune_batch_size} <- prune_batch_size(opts) do
      result =
        repo.transaction(
          fn ->
            set_local_lock_timeout!(repo)
            query!(repo, "LOCK TABLE snapshots IN SHARE ROW EXCLUSIVE MODE", [])

            proof_opts =
              opts
              |> Keyword.put(:repo, repo)
              |> Keyword.put(:emit_telemetry, false)

            case preflight(proof_opts) do
              {:ok, preflight} ->
                if clean_format?(preflight) do
                  case do_prune_all(opts, max_batches, %{batches: 0, deleted: 0}) do
                    {:ok, pruned} -> pruned
                    {:error, reason} -> repo.rollback(reason)
                  end
                else
                  repo.rollback({:snapshot_prune_requires_clean_format, preflight})
                end

              {:error, reason} ->
                repo.rollback(reason)
            end
          end,
          timeout: :infinity
        )

      case result do
        {:ok, pruned} ->
          :telemetry.execute(
            [:maraithon, :runtime, :snapshot, :migration, :prune],
            numeric_measurements(pruned),
            %{retention_count: Snapshot.retention_count()}
          )

          {:ok, pruned}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def prune_all(_opts), do: {:error, :invalid_options}

  @doc """
  Prove and enforce that every retained row uses fully decodable tagged v1.

  This obtains a table lock that excludes concurrent snapshot writes, repeats
  the bounded preflight under that lock, and refuses to finalize unless legacy,
  invalid, and over-retention counts are all zero. It then adds and validates a
  check requiring the exact v1 tags on both payload columns and validates the
  earlier storage-bound checks.
  """
  @spec finalize(keyword()) :: {:ok, preflight_stats()} | {:error, term()}
  def finalize(opts \\ [])

  def finalize(opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    result =
      repo.transaction(
        fn ->
          set_local_lock_timeout!(repo)
          query!(repo, "LOCK TABLE snapshots IN SHARE ROW EXCLUSIVE MODE", [])

          proof_opts =
            opts
            |> Keyword.put(:repo, repo)
            |> Keyword.put(:emit_telemetry, false)

          case preflight(proof_opts) do
            {:ok, stats} ->
              if clean_format?(stats) and stats.agents_over_retention == 0 do
                ensure_format_constraint!(repo)
                Enum.each(@snapshot_constraints, &require_constraint_definition!(repo, &1))
                Enum.each(@snapshot_constraints, &validate_required_constraint!(repo, &1))
                Enum.each(@snapshot_constraints, &require_constraint_definition!(repo, &1))

                case preflight(proof_opts) do
                  {:ok, proved} -> proved
                  {:error, reason} -> repo.rollback(reason)
                end
              else
                repo.rollback({:snapshot_preflight_not_clean, stats})
              end

            {:error, reason} ->
              repo.rollback(reason)
          end
        end,
        timeout: :infinity
      )

    case result do
      {:ok, stats} ->
        :telemetry.execute(
          [:maraithon, :runtime, :snapshot, :migration, :finalize],
          numeric_measurements(stats),
          %{format_version: SnapshotFormat.version(), constraint: @format_constraint}
        )

        {:ok, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def finalize(_opts), do: {:error, :invalid_options}

  def format_constraint_name, do: @format_constraint

  defp scan_preflight(repo, cursor, batch_size, stats) do
    case load_rows(repo, cursor, batch_size, lock?: false) do
      {:ok, []} ->
        {:ok, stats}

      {:ok, rows} ->
        case Enum.reduce_while(rows, {:ok, stats}, fn row, {:ok, acc} ->
               case count_preflight_row(repo, row, acc) do
                 {:ok, next} -> {:cont, {:ok, next}}
                 {:error, reason} -> {:halt, {:error, reason}}
               end
             end) do
          {:ok, next} -> scan_preflight(repo, List.last(rows).id, batch_size, next)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp count_preflight_row(repo, row, stats) do
    stats = Map.update!(stats, :total_snapshot_count, &(&1 + 1))

    case classify_row(row) do
      {:ok, :tagged_v1, _encoded} ->
        {:ok, Map.update!(stats, :tagged_v1_snapshot_count, &(&1 + 1))}

      {:ok, :legacy, _encoded} ->
        {:ok, Map.update!(stats, :legacy_snapshot_count, &(&1 + 1))}

      {:error, _reason} ->
        stats = Map.update!(stats, :invalid_snapshot_count, &(&1 + 1))

        case invalid_active_without_fresh_checkpoint?(repo, row) do
          {:ok, true} ->
            {:ok,
             Map.update!(
               stats,
               :active_invalid_without_fresh_checkpoint_count,
               &(&1 + 1)
             )}

          {:ok, false} ->
            {:ok, stats}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp process_rows!(repo, rows, after_id, batch_size) do
    initial = %{
      scanned: 0,
      tagged_v1: 0,
      migrated: 0,
      quarantined: 0,
      blocked_active: 0,
      next_cursor: after_id,
      pass_complete: length(rows) < batch_size
    }

    Enum.reduce(rows, initial, fn row, acc ->
      acc = %{acc | scanned: acc.scanned + 1, next_cursor: row.id}

      case classify_row(row) do
        {:ok, :tagged_v1, _encoded} ->
          %{acc | tagged_v1: acc.tagged_v1 + 1}

        {:ok, :legacy, encoded} ->
          count =
            Snapshot
            |> where([snapshot], snapshot.id == ^row.id)
            |> repo.update_all(set: [state_data: encoded.state_data, budget: encoded.budget])
            |> elem(0)

          if count != 1, do: repo.rollback(:snapshot_migration_update_lost)
          %{acc | migrated: acc.migrated + 1}

        {:error, reason} ->
          case quarantine_invalid!(repo, row, reason) do
            :quarantined -> %{acc | quarantined: acc.quarantined + 1}
            :blocked_active -> %{acc | blocked_active: acc.blocked_active + 1}
          end
      end
    end)
  end

  defp classify_row(row) do
    with :ok <- validate_metadata(row),
         :ok <- transferred_payload?(row, :state_data),
         :ok <- transferred_payload?(row, :budget),
         {:ok, state, state_kind} <- decode_column(row.state_data, :state_data),
         {:ok, budget, budget_kind} <- decode_column(row.budget, :budget),
         {:ok, encoded_state, state_bytes} <- encode_column(state, :state_data),
         {:ok, encoded_budget, budget_bytes} <- encode_column(budget, :budget),
         true <- state_bytes + budget_bytes <= SnapshotFormat.max_encoded_bytes() do
      kind =
        if state_kind == :tagged_v1 and budget_kind == :tagged_v1,
          do: :tagged_v1,
          else: :legacy

      {:ok, kind,
       %{
         state_data: encoded_state,
         budget: encoded_budget,
         encoded_bytes: state_bytes + budget_bytes
       }}
    else
      false -> {:error, {:payload, :snapshot_too_large}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_metadata(%{sequence_num: sequence_num, schema_version: schema_version})
       when is_integer(sequence_num) and sequence_num >= 0 and is_integer(schema_version) and
              schema_version >= 0 and schema_version <= 2_147_483_647,
       do: :ok

  defp validate_metadata(%{sequence_num: sequence_num})
       when not is_integer(sequence_num) or sequence_num < 0,
       do: {:error, {:sequence_num, :invalid_snapshot_metadata}}

  defp validate_metadata(_row),
    do: {:error, {:schema_version, :invalid_snapshot_metadata}}

  defp transferred_payload?(%{state_data: nil}, :state_data),
    do: {:error, {:state_data, :legacy_snapshot_too_large}}

  defp transferred_payload?(%{budget: nil}, :budget),
    do: {:error, {:budget, :legacy_snapshot_too_large}}

  defp transferred_payload?(_row, _field), do: :ok

  defp decode_column(value, field) do
    case SnapshotFormat.decode_stored(value) do
      {:ok, term, kind} -> {:ok, term, kind}
      {:error, reason} -> {:error, {field, reason}}
    end
  end

  defp encode_column(term, field) do
    case SnapshotFormat.encode(term) do
      {:ok, envelope, bytes} -> {:ok, envelope, bytes}
      {:error, reason} -> {:error, {field, reason}}
    end
  end

  defp quarantine_invalid!(repo, row, reason) do
    removable? =
      case active_agent?(repo, row.agent_id, lock?: true) do
        {:ok, false} ->
          true

        {:ok, true} ->
          case fresh_valid_checkpoint?(repo, row) do
            {:ok, fresh?} -> fresh?
            {:error, failure} -> repo.rollback(failure)
          end

        {:error, failure} ->
          repo.rollback(failure)
      end

    status = if removable?, do: "quarantined", else: "blocked_active"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      snapshot_id: row.id,
      agent_id: row.agent_id,
      sequence_num: row.sequence_num,
      failure_code: failure_code(reason),
      status: status,
      state_bytes: row.state_bytes,
      budget_bytes: row.budget_bytes,
      snapshot_inserted_at: as_utc_datetime(row.inserted_at),
      quarantined_at: if(removable?, do: now, else: nil),
      inserted_at: now
    }

    {_count, _rows} =
      repo.insert_all(SnapshotQuarantine, [attrs],
        on_conflict:
          {:replace,
           [
             :failure_code,
             :status,
             :state_bytes,
             :budget_bytes,
             :quarantined_at
           ]},
        conflict_target: [:snapshot_id]
      )

    if removable? do
      {deleted, _rows} =
        Snapshot
        |> where([snapshot], snapshot.id == ^row.id)
        |> repo.delete_all()

      if deleted != 1, do: repo.rollback(:snapshot_quarantine_delete_lost)

      Logger.warning("Quarantined invalid Agent snapshot",
        snapshot_id: row.id,
        sequence_num: row.sequence_num,
        agent_reference: Maraithon.Redaction.fingerprint(row.agent_id),
        failure_code: failure_code(reason)
      )

      :quarantined
    else
      Logger.warning("Retaining invalid active-Agent snapshot until a fresh checkpoint exists",
        snapshot_id: row.id,
        sequence_num: row.sequence_num,
        agent_reference: Maraithon.Redaction.fingerprint(row.agent_id),
        failure_code: failure_code(reason)
      )

      :blocked_active
    end
  end

  defp invalid_active_without_fresh_checkpoint?(repo, row) do
    with {:ok, active?} <- active_agent?(repo, row.agent_id) do
      if active? do
        with {:ok, fresh?} <- fresh_valid_checkpoint?(repo, row), do: {:ok, not fresh?}
      else
        {:ok, false}
      end
    end
  end

  defp active_agent?(repo, agent_id, opts \\ []) do
    lock = if Keyword.get(opts, :lock?, false), do: "FOR SHARE", else: ""

    sql = """
    SELECT status, install_status
    FROM agents
    WHERE id::text = $1
    #{lock}
    """

    case repo.query(sql, [agent_id], timeout: @query_timeout_ms) do
      {:ok, %{rows: [[status, "enabled"]]}} ->
        {:ok, status in ["recovering", "running", "degraded"]}

      {:ok, %{rows: []}} ->
        {:ok, false}

      {:ok, %{rows: [[_status, _install_status]]}} ->
        {:ok, false}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fresh_valid_checkpoint?(repo, row) do
    max_stored = SnapshotFormat.max_legacy_stored_bytes()

    sql = """
    SELECT
      id,
      agent_id::text,
      sequence_num,
      state_name,
      CASE WHEN octet_length(state_data::text) <= $3 THEN state_data ELSE NULL END,
      CASE WHEN octet_length(budget::text) <= $3 THEN budget ELSE NULL END,
      schema_version,
      inserted_at,
      octet_length(state_data::text)::bigint,
      octet_length(budget::text)::bigint
    FROM snapshots
    WHERE agent_id::text = $1
      AND id > $2
      AND state_data ->> 'format' = 'maraithon.agent_snapshot'
      AND state_data -> 'format_version' = '1'::jsonb
      AND budget ->> 'format' = 'maraithon.agent_snapshot'
      AND budget -> 'format_version' = '1'::jsonb
    ORDER BY id DESC
    LIMIT #{Snapshot.retention_count()}
    """

    case repo.query(sql, [row.agent_id, row.id, max_stored], timeout: @query_timeout_ms) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.any?(rows, fn values ->
           candidate = row_from_values(values)
           match?({:ok, :tagged_v1, _encoded}, classify_row(candidate))
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp migrate_batches(opts, after_id, max_batches) do
    do_migrate_batches(opts, after_id, max_batches, %{
      batches: 0,
      scanned: 0,
      tagged_v1: 0,
      migrated: 0,
      quarantined: 0,
      blocked_active: 0,
      next_cursor: after_id,
      pass_complete: false
    })
  end

  defp do_migrate_batches(_opts, _cursor, 0, acc), do: {:ok, acc}

  defp do_migrate_batches(opts, cursor, remaining, acc) do
    batch_opts = Keyword.put(opts, :after_id, cursor)

    case migrate_batch(batch_opts) do
      {:ok, batch} ->
        acc = merge_batch(acc, batch)

        if batch.pass_complete do
          {:ok, acc}
        else
          do_migrate_batches(opts, batch.next_cursor, remaining - 1, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_batch(acc, batch) do
    %{
      batches: acc.batches + 1,
      scanned: acc.scanned + batch.scanned,
      tagged_v1: acc.tagged_v1 + batch.tagged_v1,
      migrated: acc.migrated + batch.migrated,
      quarantined: acc.quarantined + batch.quarantined,
      blocked_active: acc.blocked_active + batch.blocked_active,
      next_cursor: batch.next_cursor,
      pass_complete: batch.pass_complete
    }
  end

  defp maybe_prune(opts, %{pass_complete: true}, after_conversion)
       when after_conversion.legacy_snapshot_count == 0 and
              after_conversion.invalid_snapshot_count == 0 do
    prune_all(opts)
  end

  defp maybe_prune(_opts, _conversion, _after_conversion),
    do: {:ok, %{batches: 0, deleted: 0, complete: false, skipped: true}}

  defp prune_batch(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, limit} <- prune_batch_size(opts),
         {:ok, result} <-
           repo.query(prune_sql(), [Snapshot.retention_count(), limit],
             timeout: @query_timeout_ms
           ) do
      {:ok, %{deleted: result.num_rows}}
    end
  end

  defp do_prune_all(_opts, 0, acc), do: {:ok, Map.put(acc, :complete, false)}

  defp do_prune_all(opts, remaining, acc) do
    case prune_batch(opts) do
      {:ok, %{deleted: deleted}} ->
        acc = %{acc | batches: acc.batches + 1, deleted: acc.deleted + deleted}

        if deleted == 0 do
          {:ok, Map.put(acc, :complete, true)}
        else
          do_prune_all(opts, remaining - 1, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clean_format?(stats),
    do: stats.legacy_snapshot_count == 0 and stats.invalid_snapshot_count == 0

  defp load_rows(repo, after_id, limit, opts) do
    lock = if Keyword.get(opts, :lock?, false), do: "FOR UPDATE", else: ""
    max_stored = SnapshotFormat.max_legacy_stored_bytes()

    sql = """
    SELECT
      id,
      agent_id::text,
      sequence_num,
      state_name,
      CASE WHEN octet_length(state_data::text) <= $3 THEN state_data ELSE NULL END,
      CASE WHEN octet_length(budget::text) <= $3 THEN budget ELSE NULL END,
      schema_version,
      inserted_at,
      octet_length(state_data::text)::bigint,
      octet_length(budget::text)::bigint
    FROM snapshots
    WHERE id > $1
    ORDER BY id ASC
    LIMIT $2
    #{lock}
    """

    case repo.query(sql, [after_id, limit, max_stored], timeout: @query_timeout_ms) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &row_from_values/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row_from_values([
         id,
         agent_id,
         sequence_num,
         state_name,
         state_data,
         budget,
         schema_version,
         inserted_at,
         state_bytes,
         budget_bytes
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      sequence_num: sequence_num,
      state_name: state_name,
      state_data: state_data,
      budget: budget,
      schema_version: schema_version,
      inserted_at: inserted_at,
      state_bytes: state_bytes,
      budget_bytes: budget_bytes
    }
  end

  defp retention_stats(repo) do
    sql = """
    WITH per_agent AS (
      SELECT agent_id, count(*)::bigint AS snapshot_count
      FROM snapshots
      GROUP BY agent_id
      HAVING count(*) > $1
    )
    SELECT
      count(*)::bigint,
      COALESCE(sum(snapshot_count - $1), 0)::bigint
    FROM per_agent
    """

    case repo.query(sql, [Snapshot.retention_count()], timeout: @query_timeout_ms) do
      {:ok, %{rows: [[agents, rows]]}} ->
        {:ok, %{agents_over_retention: agents, over_retention_snapshot_count: rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp quarantine_report_stats(repo) do
    sql = """
    SELECT
      count(*) FILTER (WHERE status = 'blocked_active')::bigint,
      count(*) FILTER (WHERE status = 'quarantined')::bigint
    FROM snapshot_quarantines
    """

    case repo.query(sql, [], timeout: @query_timeout_ms) do
      {:ok, %{rows: [[blocked, quarantined]]}} ->
        {:ok,
         %{
           blocked_quarantine_report_count: blocked,
           quarantined_report_count: quarantined
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_constraint_status(repo) do
    sql = """
    SELECT count(*) > 0, COALESCE(bool_and(convalidated), false)
    FROM pg_constraint
    WHERE conrelid = 'snapshots'::regclass
      AND conname = $1
    """

    case repo.query(sql, [@format_constraint], timeout: @query_timeout_ms) do
      {:ok, %{rows: [[installed, validated]]}} ->
        {:ok,
         %{
           format_constraint_installed: installed,
           format_constraint_validated: installed and validated
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_format_constraint!(repo) do
    case constraint_definition(repo, @format_constraint) do
      {:ok, nil} ->
        query!(
          repo,
          """
          ALTER TABLE snapshots
          ADD CONSTRAINT #{@format_constraint}
          CHECK ((
            state_data ->> 'format' = '#{SnapshotFormat.format()}'
            AND state_data -> 'format_version' = '#{SnapshotFormat.version()}'::jsonb
            AND budget ->> 'format' = '#{SnapshotFormat.format()}'
            AND budget -> 'format_version' = '#{SnapshotFormat.version()}'::jsonb
          ) IS TRUE) NOT VALID
          """,
          []
        )

      {:ok, _definition} ->
        require_constraint_definition!(repo, @format_constraint)

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp require_constraint_definition!(repo, constraint) do
    expected = Map.fetch!(@constraint_definitions, constraint)

    case constraint_definition(repo, constraint) do
      {:ok, ^expected} ->
        :ok

      {:ok, nil} ->
        repo.rollback({:snapshot_constraint_missing, constraint})

      {:ok, _other} ->
        repo.rollback({:snapshot_constraint_definition_mismatch, constraint})

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp constraint_definition(repo, constraint) do
    sql = """
    SELECT pg_get_constraintdef(oid, true)
    FROM pg_constraint
    WHERE conrelid = 'snapshots'::regclass
      AND conname = $1
      AND contype = 'c'
    """

    case repo.query(sql, [constraint], timeout: @query_timeout_ms) do
      {:ok, %{rows: [[definition]]}} ->
        {:ok, String.replace_suffix(definition, " NOT VALID", "")}

      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_required_constraint!(repo, constraint) do
    # The definition was checked immediately before this statement. Quoting is
    # deliberately unnecessary because names come only from the fixed module
    # manifest above, never from operator input.
    query!(repo, "ALTER TABLE snapshots VALIDATE CONSTRAINT #{constraint}", [])
  end

  defp prune_sql do
    """
    WITH ranked AS (
      SELECT
        id,
        row_number() OVER (
          PARTITION BY agent_id
          ORDER BY sequence_num DESC, id DESC
        ) AS retention_rank
      FROM snapshots
    ),
    stale AS (
      SELECT id
      FROM ranked
      WHERE retention_rank > $1
      ORDER BY id
      LIMIT $2
    )
    DELETE FROM snapshots AS snapshot
    USING stale
    WHERE snapshot.id = stale.id
    """
  end

  defp failure_code({field, reason}) when is_atom(field) do
    "#{field}_#{Maraithon.Redaction.error_class(reason)}"
    |> String.slice(0, 255)
  end

  defp failure_code(reason),
    do: reason |> Maraithon.Redaction.error_class() |> String.slice(0, 255)

  defp as_utc_datetime(%DateTime{} = datetime), do: datetime

  defp as_utc_datetime(%NaiveDateTime{} = datetime),
    do: DateTime.from_naive!(datetime, "Etc/UTC")

  defp set_local_lock_timeout!(repo) do
    query!(repo, "SET LOCAL lock_timeout = '#{@lock_timeout_ms}ms'", [])
  end

  defp query!(repo, sql, params) do
    case repo.query(sql, params, timeout: @query_timeout_ms) do
      {:ok, result} -> result
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp batch_size(opts),
    do: bounded_option(opts, :batch_size, @default_batch_size, @max_batch_size)

  defp prune_batch_size(opts),
    do: bounded_option(opts, :prune_batch_size, @default_prune_batch_size, @max_prune_batch_size)

  defp max_batches(opts),
    do: bounded_option(opts, :max_batches, @default_max_batches, @max_max_batches)

  defp bounded_option(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 1 and value <= maximum -> {:ok, value}
      _other -> {:error, invalid_option(key)}
    end
  end

  defp invalid_option(:batch_size), do: :invalid_batch_size
  defp invalid_option(:prune_batch_size), do: :invalid_prune_batch_size
  defp invalid_option(:max_batches), do: :invalid_max_batches

  defp empty_preflight do
    %{
      total_snapshot_count: 0,
      tagged_v1_snapshot_count: 0,
      legacy_snapshot_count: 0,
      invalid_snapshot_count: 0,
      active_invalid_without_fresh_checkpoint_count: 0
    }
  end

  defp emit_preflight(stats) do
    :telemetry.execute(
      [:maraithon, :runtime, :snapshot, :migration, :preflight],
      numeric_measurements(stats),
      %{
        format_version: SnapshotFormat.version(),
        retention_count: Snapshot.retention_count(),
        format_constraint_installed: stats.format_constraint_installed,
        format_constraint_validated: stats.format_constraint_validated
      }
    )
  end

  defp numeric_measurements(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_integer(value) -> Map.put(acc, key, value)
      {key, true}, acc -> Map.put(acc, key, 1)
      {key, false}, acc -> Map.put(acc, key, 0)
      {_key, _value}, acc -> acc
    end)
  end
end
