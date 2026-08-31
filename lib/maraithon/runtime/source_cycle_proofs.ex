defmodule Maraithon.Runtime.SourceCycleProofs do
  @moduledoc """
  Transactional, privacy-safe storage for exact source fan-out coverage proofs.

  Cycles are inserted once with their complete source and todo snapshot sets.
  Decision receipts are append-only and idempotent. Call the `_in_transaction`
  variants from the same exact settlement transaction as the todo or cursor
  mutation they prove.
  """

  import Ecto.Query

  alias Maraithon.Lineage.Canonical
  alias Maraithon.Lineage.Transaction
  alias Maraithon.Repo
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.SourceCycle
  alias Maraithon.Runtime.SourceCycleItem
  alias Maraithon.Runtime.SourceDecisionReceipt
  alias Maraithon.Runtime.TodoClosureReceipt
  alias Maraithon.Runtime.TodoSnapshotItem

  @max_source_items 50_000
  @max_todo_snapshots 20_000
  @max_reason_jobs 20_000

  @source_item_fields [
    :id,
    :cycle_id,
    :user_id,
    :connected_account_id,
    :provider,
    :ordinal,
    :source_ref_digest,
    :source_identity_digest,
    :source_revision_digest,
    :provider_occurred_at,
    :ingress_sequence,
    :inserted_at
  ]
  @todo_snapshot_fields [
    :id,
    :cycle_id,
    :user_id,
    :connected_account_id,
    :provider,
    :ordinal,
    :todo_id,
    :eligible_status,
    :todo_state_digest,
    :todo_updated_at,
    :inserted_at
  ]
  @source_decision_fields [
    :id,
    :cycle_id,
    :user_id,
    :connected_account_id,
    :provider,
    :source_ref_digest,
    :reason_job_id,
    :action,
    :todo_id,
    :todo_state_digest,
    :evaluator,
    :reason_code,
    :evidence_digest,
    :decision_digest,
    :decided_at,
    :inserted_at
  ]
  @todo_closure_fields [
    :id,
    :cycle_id,
    :user_id,
    :connected_account_id,
    :provider,
    :todo_id,
    :reason_job_id,
    :todo_before_digest,
    :todo_after_digest,
    :outcome,
    :evaluator,
    :reason_code,
    :evidence_digest,
    :decision_digest,
    :decided_at,
    :inserted_at
  ]

  @doc "Returns the SHA-256 identity stored for a canonical source reference."
  def reference_digest(reference) when is_binary(reference) and byte_size(reference) in 1..4096,
    do: :crypto.hash(:sha256, reference)

  def reference_digest(_reference), do: nil

  @doc "Returns source reference/revision pairs already sealed for an account role."
  def settled_revision_pairs(account_id, role, proof_items)
      when is_integer(account_id) and account_id > 0 and role in ["discovery", "closure"] and
             is_list(proof_items) do
    ref_digests =
      proof_items
      |> Enum.map(&value(&1, :source_ref_digest))
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) == 32))
      |> Enum.uniq()

    if ref_digests == [] do
      MapSet.new()
    else
      base =
        from(item in SourceCycleItem,
          join: cycle in SourceCycle,
          on: cycle.id == item.cycle_id,
          where:
            cycle.connected_account_id == ^account_id and cycle.role == ^role and
              item.source_ref_digest in ^ref_digests,
          select: {item.source_ref_digest, item.source_revision_digest}
        )

      query =
        if role == "discovery" do
          from([item, cycle] in base,
            join: receipt in SourceDecisionReceipt,
            on:
              receipt.cycle_id == cycle.id and
                receipt.source_ref_digest == item.source_ref_digest
          )
        else
          base
        end

      query
      |> Repo.all()
      |> MapSet.new()
    end
  end

  def settled_revision_pairs(_account_id, _role, _proof_items), do: MapSet.new()

  @doc "Returns a privacy-safe exact proof audit for a bounded half-open time window."
  def verify_window(%DateTime{} = since, %DateTime{} = until_time) do
    if DateTime.compare(since, until_time) == :lt,
      do: verify_valid_window(since, until_time),
      else: {:error, :invalid_source_cycle_window}
  end

  def verify_window(_since, _until_time), do: {:error, :invalid_source_cycle_window}

  defp verify_valid_window(since, until_time) do
    cycles =
      SourceCycle
      |> where([cycle], cycle.captured_at >= ^since and cycle.captured_at < ^until_time)
      |> order_by(
        [cycle],
        asc: cycle.connected_account_id,
        asc: cycle.role,
        asc: cycle.cursor_kind,
        asc: cycle.captured_at,
        asc: cycle.id
      )
      |> Repo.all()

    audited = Enum.map(cycles, &audit_cycle/1)
    chain_errors = cursor_chain_errors(cycles)
    errors = Enum.flat_map(audited, & &1.errors) ++ chain_errors
    job_ids = Enum.flat_map(cycles, &cycle_job_ids/1)
    visible_jobs = activity_visible_job_ids(job_ids)

    %{
      healthy?: errors == [] and length(visible_jobs) == length(Enum.uniq(job_ids)),
      since: DateTime.to_iso8601(since),
      until: DateTime.to_iso8601(until_time),
      cycles: length(cycles),
      exact_cycles: Enum.count(audited, &(&1.errors == [])),
      cycle_coverage_percent: percent(Enum.count(audited, &(&1.errors == [])), length(cycles)),
      source_items: Enum.sum(Enum.map(audited, & &1.source_items)),
      source_decisions: Enum.sum(Enum.map(audited, & &1.source_decisions)),
      todo_snapshots: Enum.sum(Enum.map(audited, & &1.todo_snapshots)),
      todo_closures: Enum.sum(Enum.map(audited, & &1.todo_closures)),
      expected_activity_rows: length(Enum.uniq(job_ids)),
      visible_activity_rows: length(visible_jobs),
      activity_coverage_percent: percent(length(visible_jobs), length(Enum.uniq(job_ids))),
      cursor_chain_errors: length(chain_errors),
      roles: Enum.frequencies_by(cycles, & &1.role),
      providers:
        cycles
        |> Enum.map(fn cycle ->
          if String.starts_with?(cycle.provider, "slack:"), do: "slack", else: "gmail"
        end)
        |> Enum.frequencies(),
      error_codes: Enum.frequencies(errors),
      failures: Enum.reject(audited, &(&1.errors == []))
    }
  end

  def create_cycle(attrs, source_items, todo_snapshots)
      when is_map(attrs) and is_list(source_items) and is_list(todo_snapshots) do
    transact(fn -> create_cycle_in_transaction(attrs, source_items, todo_snapshots) end)
  end

  def create_cycle(_attrs, _source_items, _todo_snapshots),
    do: {:error, :invalid_source_cycle}

  def create_cycle_in_transaction(attrs, source_items, todo_snapshots)
      when is_map(attrs) and is_list(source_items) and is_list(todo_snapshots) and
             length(source_items) <= @max_source_items and
             length(todo_snapshots) <= @max_todo_snapshots do
    with :ok <- Transaction.require(),
         {:ok, identity} <- cycle_identity(attrs),
         {:ok, items} <- prepare_source_items(identity, source_items),
         {:ok, snapshots} <- prepare_todo_snapshots(identity, todo_snapshots),
         {:ok, cycle_attrs} <- prepare_cycle(identity, items, snapshots),
         {:ok, cycle} <- Repo.insert(SourceCycle.changeset(%SourceCycle{}, cycle_attrs)),
         :ok <- insert_source_items(cycle, items),
         :ok <- insert_todo_snapshots(cycle, snapshots) do
      {:ok, cycle}
    end
  end

  def create_cycle_in_transaction(_attrs, _source_items, _todo_snapshots) do
    with :ok <- Transaction.require(), do: {:error, :source_cycle_bounds_exceeded}
  end

  def record_source_decisions(cycle_or_id, receipts) when is_list(receipts) do
    transact(fn -> record_source_decisions_in_transaction(cycle_or_id, receipts) end)
  end

  def record_source_decisions(_cycle_or_id, _receipts),
    do: {:error, :invalid_source_decisions}

  def record_source_decisions_in_transaction(cycle_or_id, receipts)
      when is_list(receipts) and length(receipts) <= @max_source_items do
    with :ok <- Transaction.require(),
         %SourceCycle{role: "discovery"} = cycle <- get_cycle(cycle_or_id),
         {:ok, prepared} <- prepare_source_decisions(cycle, receipts),
         {:ok, dispositions} <- insert_or_compare_all(SourceDecisionReceipt, prepared) do
      {:ok, dispositions}
    else
      nil -> {:error, :source_cycle_not_found}
      %SourceCycle{} -> {:error, :source_cycle_role_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def record_source_decisions_in_transaction(_cycle_or_id, _receipts) do
    with :ok <- Transaction.require(), do: {:error, :source_decision_bounds_exceeded}
  end

  def record_todo_closures(cycle_or_id, receipts) when is_list(receipts) do
    transact(fn -> record_todo_closures_in_transaction(cycle_or_id, receipts) end)
  end

  def record_todo_closures(_cycle_or_id, _receipts),
    do: {:error, :invalid_todo_closures}

  def record_todo_closures_in_transaction(cycle_or_id, receipts)
      when is_list(receipts) and length(receipts) <= @max_todo_snapshots do
    with :ok <- Transaction.require(),
         %SourceCycle{role: "closure"} = cycle <- get_cycle(cycle_or_id),
         {:ok, prepared} <- prepare_todo_closures(cycle, receipts),
         {:ok, dispositions} <- insert_or_compare_all(TodoClosureReceipt, prepared) do
      {:ok, dispositions}
    else
      nil -> {:error, :source_cycle_not_found}
      %SourceCycle{} -> {:error, :source_cycle_role_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def record_todo_closures_in_transaction(_cycle_or_id, _receipts) do
    with :ok <- Transaction.require(), do: {:error, :todo_closure_bounds_exceeded}
  end

  def verify_complete(cycle_or_id) do
    transact(fn -> verify_complete_in_transaction(cycle_or_id) end)
  end

  def verify_complete_in_transaction(cycle_or_id) do
    with :ok <- Transaction.require(),
         %SourceCycle{} = cycle <- get_cycle(cycle_or_id),
         :ok <- verify_job_visibility(cycle),
         counts <- proof_counts(cycle),
         :ok <- verify_counts(cycle, counts) do
      {:ok, Map.put(counts, :cycle_id, cycle.id)}
    else
      nil -> {:error, :source_cycle_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cycle_identity(attrs) do
    reason_job_ids = value(attrs, :reason_job_ids, [])

    with user_id when is_binary(user_id) <- value(attrs, :user_id),
         connected_account_id when is_integer(connected_account_id) and connected_account_id > 0 <-
           value(attrs, :connected_account_id),
         provider when is_binary(provider) <- value(attrs, :provider),
         role when role in ["discovery", "closure"] <- value(attrs, :role),
         cursor_kind when is_binary(cursor_kind) <- value(attrs, :cursor_kind),
         lower_cursor when is_nil(lower_cursor) or is_binary(lower_cursor) <-
           value(attrs, :lower_cursor),
         upper_cursor when is_binary(upper_cursor) <- value(attrs, :upper_cursor),
         boundary when is_binary(boundary) <- value(attrs, :boundary),
         true <- boundary in SourceCycle.boundaries(),
         {:ok, acquisition_job_id} <- uuid(value(attrs, :acquisition_job_id)),
         true <- is_list(reason_job_ids) and length(reason_job_ids) <= @max_reason_jobs,
         {:ok, reason_job_ids} <- uuids(reason_job_ids),
         {:ok, finalizer_job_id} <- optional_uuid(value(attrs, :finalizer_job_id)),
         :ok <- fanout_shape(reason_job_ids, finalizer_job_id) do
      {:ok,
       %{
         id: Ecto.UUID.generate(),
         user_id: user_id,
         connected_account_id: connected_account_id,
         provider: provider,
         role: role,
         cursor_kind: cursor_kind,
         lower_cursor: lower_cursor,
         upper_cursor: upper_cursor,
         boundary: boundary,
         acquisition_job_id: acquisition_job_id,
         reason_job_ids: Enum.sort(reason_job_ids),
         finalizer_job_id: finalizer_job_id,
         captured_at: value(attrs, :captured_at)
       }}
    else
      _invalid -> {:error, :invalid_source_cycle}
    end
  end

  defp prepare_source_items(identity, items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, ordinal}, {:ok, prepared} ->
      with true <- is_map(attrs),
           {:ok, source_ref_digest} <- digest(value(attrs, :source_ref_digest)),
           {:ok, source_identity_digest} <- digest(value(attrs, :source_identity_digest)),
           {:ok, source_revision_digest} <- digest(value(attrs, :source_revision_digest)),
           {:ok, provider_occurred_at} <- optional_datetime(value(attrs, :provider_occurred_at)),
           {:ok, ingress_sequence} <- optional_nonnegative(value(attrs, :ingress_sequence)) do
        item = %{
          ordinal: ordinal,
          source_ref_digest: source_ref_digest,
          source_identity_digest: source_identity_digest,
          source_revision_digest: source_revision_digest,
          provider_occurred_at: provider_occurred_at,
          ingress_sequence: ingress_sequence
        }

        {:cont, {:ok, [item | prepared]}}
      else
        _invalid -> {:halt, {:error, :invalid_source_cycle_item}}
      end
    end)
    |> reverse_ok()
    |> reject_duplicate(:source_ref_digest, :duplicate_source_cycle_item)
    |> ensure_item_owner(identity)
  end

  defp prepare_todo_snapshots(identity, snapshots) do
    snapshots
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, ordinal}, {:ok, prepared} ->
      with true <- is_map(attrs),
           {:ok, todo_id} <- uuid(value(attrs, :todo_id)),
           eligible_status when is_binary(eligible_status) <- value(attrs, :eligible_status),
           true <- eligible_status in TodoSnapshotItem.eligible_statuses(),
           {:ok, todo_state_digest} <- digest(value(attrs, :todo_state_digest)),
           %DateTime{} = todo_updated_at <- value(attrs, :todo_updated_at) do
        snapshot = %{
          ordinal: ordinal,
          todo_id: todo_id,
          eligible_status: eligible_status,
          todo_state_digest: todo_state_digest,
          todo_updated_at: todo_updated_at
        }

        {:cont, {:ok, [snapshot | prepared]}}
      else
        _invalid -> {:halt, {:error, :invalid_todo_snapshot}}
      end
    end)
    |> reverse_ok()
    |> reject_duplicate(:todo_id, :duplicate_todo_snapshot)
    |> ensure_snapshot_role(identity)
  end

  defp prepare_cycle(identity, items, snapshots) do
    now = DatabaseClock.now!()
    captured_at = identity.captured_at || now

    job_ids =
      [identity.acquisition_job_id | identity.reason_job_ids] ++
        List.wrap(identity.finalizer_job_id)

    job_digest = joined_digest(job_ids)
    source_digest = source_manifest_digest(items)
    todo_digest = todo_manifest_digest(snapshots)

    with {:ok, cycle_key} <-
           Canonical.identity("source-cycle-v2", [
             identity.user_id,
             identity.connected_account_id,
             identity.provider,
             identity.role,
             identity.cursor_kind,
             identity.lower_cursor,
             identity.upper_cursor,
             identity.boundary,
             identity.acquisition_job_id,
             identity.finalizer_job_id,
             hex(job_digest),
             hex(source_digest),
             hex(todo_digest)
           ]) do
      attrs =
        identity
        |> Map.drop([:captured_at])
        |> Map.merge(%{
          cycle_key: cycle_key,
          proof_version: 2,
          reason_job_count: length(identity.reason_job_ids),
          job_manifest_digest: job_digest,
          source_item_count: length(items),
          source_manifest_digest: source_digest,
          todo_snapshot_count: length(snapshots),
          todo_snapshot_manifest_digest: todo_digest,
          captured_at: captured_at,
          sealed_at: now,
          inserted_at: now
        })

      changeset = SourceCycle.changeset(%SourceCycle{}, attrs)
      if changeset.valid?, do: {:ok, attrs}, else: {:error, changeset}
    end
  end

  defp insert_source_items(cycle, items) do
    now = cycle.inserted_at

    rows =
      Enum.map(items, fn item ->
        attrs =
          Map.merge(item, %{
            id: Ecto.UUID.generate(),
            cycle_id: cycle.id,
            user_id: cycle.user_id,
            connected_account_id: cycle.connected_account_id,
            provider: cycle.provider,
            inserted_at: now
          })

        validated_map(SourceCycleItem.changeset(%SourceCycleItem{}, attrs), @source_item_fields)
      end)

    insert_validated_rows(SourceCycleItem, rows)
  end

  defp insert_todo_snapshots(cycle, snapshots) do
    now = cycle.inserted_at

    rows =
      Enum.map(snapshots, fn snapshot ->
        attrs =
          Map.merge(snapshot, %{
            id: Ecto.UUID.generate(),
            cycle_id: cycle.id,
            user_id: cycle.user_id,
            connected_account_id: cycle.connected_account_id,
            provider: cycle.provider,
            inserted_at: now
          })

        validated_map(
          TodoSnapshotItem.changeset(%TodoSnapshotItem{}, attrs),
          @todo_snapshot_fields
        )
      end)

    insert_validated_rows(TodoSnapshotItem, rows)
  end

  defp prepare_source_decisions(cycle, receipts) do
    now = DatabaseClock.now!()

    receipts
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, prepared} ->
      with true <- is_map(attrs),
           {:ok, source_ref_digest} <- digest(value(attrs, :source_ref_digest)),
           {:ok, reason_job_id} <- uuid(value(attrs, :reason_job_id)),
           true <- reason_job_id in cycle.reason_job_ids,
           action when is_binary(action) <- value(attrs, :action),
           true <- action in SourceDecisionReceipt.actions(),
           {:ok, todo_id} <- optional_uuid(value(attrs, :todo_id)),
           {:ok, todo_state_digest} <- optional_digest(value(attrs, :todo_state_digest)),
           evaluator when is_binary(evaluator) <- value(attrs, :evaluator),
           true <- evaluator in SourceDecisionReceipt.evaluators(),
           reason_code when is_binary(reason_code) <- value(attrs, :reason_code),
           {:ok, evidence_digest} <- optional_digest(value(attrs, :evidence_digest)) do
        decision_digest =
          joined_digest([
            cycle.id,
            hex(source_ref_digest),
            reason_job_id,
            action,
            todo_id,
            hex(todo_state_digest),
            evaluator,
            reason_code,
            hex(evidence_digest)
          ])

        receipt = %{
          id: Ecto.UUID.generate(),
          cycle_id: cycle.id,
          user_id: cycle.user_id,
          connected_account_id: cycle.connected_account_id,
          provider: cycle.provider,
          source_ref_digest: source_ref_digest,
          reason_job_id: reason_job_id,
          action: action,
          todo_id: todo_id,
          todo_state_digest: todo_state_digest,
          evaluator: evaluator,
          reason_code: reason_code,
          evidence_digest: evidence_digest,
          decision_digest: decision_digest,
          decided_at: now,
          inserted_at: now
        }

        changeset = SourceDecisionReceipt.changeset(%SourceDecisionReceipt{}, receipt)

        if changeset.valid?,
          do: {:cont, {:ok, [Map.take(receipt, @source_decision_fields) | prepared]}},
          else: {:halt, {:error, changeset}}
      else
        _invalid -> {:halt, {:error, :invalid_source_decision}}
      end
    end)
    |> reverse_ok()
    |> reject_duplicate(:source_ref_digest, :duplicate_source_decision)
  end

  defp prepare_todo_closures(cycle, receipts) do
    now = DatabaseClock.now!()

    receipts
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, prepared} ->
      with true <- is_map(attrs),
           {:ok, todo_id} <- uuid(value(attrs, :todo_id)),
           {:ok, reason_job_id} <- uuid(value(attrs, :reason_job_id)),
           true <- reason_job_id in cycle.reason_job_ids,
           {:ok, todo_before_digest} <- digest(value(attrs, :todo_before_digest)),
           {:ok, todo_after_digest} <- digest(value(attrs, :todo_after_digest)),
           outcome when is_binary(outcome) <- value(attrs, :outcome),
           true <- outcome in TodoClosureReceipt.outcomes(),
           evaluator when is_binary(evaluator) <- value(attrs, :evaluator),
           true <- evaluator in TodoClosureReceipt.evaluators(),
           reason_code when is_binary(reason_code) <- value(attrs, :reason_code),
           {:ok, evidence_digest} <- optional_digest(value(attrs, :evidence_digest)) do
        decision_digest =
          joined_digest([
            cycle.id,
            todo_id,
            reason_job_id,
            hex(todo_before_digest),
            hex(todo_after_digest),
            outcome,
            evaluator,
            reason_code,
            hex(evidence_digest)
          ])

        receipt = %{
          id: Ecto.UUID.generate(),
          cycle_id: cycle.id,
          user_id: cycle.user_id,
          connected_account_id: cycle.connected_account_id,
          provider: cycle.provider,
          todo_id: todo_id,
          reason_job_id: reason_job_id,
          todo_before_digest: todo_before_digest,
          todo_after_digest: todo_after_digest,
          outcome: outcome,
          evaluator: evaluator,
          reason_code: reason_code,
          evidence_digest: evidence_digest,
          decision_digest: decision_digest,
          decided_at: now,
          inserted_at: now
        }

        changeset = TodoClosureReceipt.changeset(%TodoClosureReceipt{}, receipt)

        if changeset.valid?,
          do: {:cont, {:ok, [Map.take(receipt, @todo_closure_fields) | prepared]}},
          else: {:halt, {:error, changeset}}
      else
        _invalid -> {:halt, {:error, :invalid_todo_closure}}
      end
    end)
    |> reverse_ok()
    |> reject_duplicate(:todo_id, :duplicate_todo_closure)
  end

  defp insert_or_compare_all(schema, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, dispositions} ->
      conflict_target =
        case schema do
          SourceDecisionReceipt -> [:cycle_id, :source_ref_digest]
          TodoClosureReceipt -> [:cycle_id, :todo_id]
        end

      case Repo.insert_all(schema, [row], on_conflict: :nothing, conflict_target: conflict_target) do
        {1, _rows} ->
          {:cont, {:ok, [:inserted | dispositions]}}

        {0, _rows} ->
          stored = Repo.get_by(schema, Enum.map(conflict_target, &{&1, Map.fetch!(row, &1)}))

          if same_receipt?(stored, row, Map.keys(row) -- [:id, :inserted_at, :decided_at]) do
            {:cont, {:ok, [:duplicate | dispositions]}}
          else
            {:halt, {:error, :source_cycle_receipt_idempotency_conflict}}
          end
      end
    end)
    |> reverse_ok()
  end

  defp same_receipt?(nil, _row, _fields), do: false

  defp same_receipt?(stored, row, fields) do
    Enum.all?(fields, &(Map.get(stored, &1) == Map.get(row, &1)))
  end

  defp verify_job_visibility(cycle) do
    expected_ids =
      [cycle.acquisition_job_id | cycle.reason_job_ids] ++ List.wrap(cycle.finalizer_job_id)

    visible_count =
      Repo.aggregate(
        from(job in Maraithon.Runtime.BackgroundJob,
          where: job.id in ^expected_ids and job.user_id == ^cycle.user_id
        ),
        :count
      )

    if visible_count == length(expected_ids),
      do: :ok,
      else: {:error, :source_cycle_activity_incomplete}
  end

  defp proof_counts(cycle) do
    %{
      source_items: count(SourceCycleItem, cycle.id),
      source_decisions: count(SourceDecisionReceipt, cycle.id),
      todo_snapshots: count(TodoSnapshotItem, cycle.id),
      todo_closures: count(TodoClosureReceipt, cycle.id),
      expected_jobs: 1 + cycle.reason_job_count + if(cycle.finalizer_job_id, do: 1, else: 0)
    }
  end

  defp verify_counts(%SourceCycle{role: "discovery"} = cycle, counts) do
    if counts.source_items == cycle.source_item_count and
         counts.source_decisions == cycle.source_item_count and
         counts.todo_snapshots == 0 and counts.todo_closures == 0 do
      :ok
    else
      {:error, :source_cycle_incomplete}
    end
  end

  defp verify_counts(%SourceCycle{role: "closure"} = cycle, counts) do
    if counts.source_items == cycle.source_item_count and
         counts.source_decisions == 0 and
         counts.todo_snapshots == cycle.todo_snapshot_count and
         counts.todo_closures == cycle.todo_snapshot_count do
      :ok
    else
      {:error, :source_cycle_incomplete}
    end
  end

  defp audit_cycle(cycle) do
    counts = proof_counts(cycle)

    errors =
      []
      |> maybe_error(verify_job_visibility(cycle), :activity_job_missing)
      |> maybe_error(verify_counts(cycle, counts), :receipt_count_mismatch)

    counts
    |> Map.put(:cycle_reference, String.slice(cycle.id, 0, 8))
    |> Map.put(:account_id, cycle.connected_account_id)
    |> Map.put(:role, cycle.role)
    |> Map.put(:errors, errors)
  end

  defp maybe_error(errors, :ok, _code), do: errors
  defp maybe_error(errors, {:error, _reason}, code), do: errors ++ [code]

  defp cursor_chain_errors(cycles) do
    cycles
    |> Enum.group_by(&{&1.connected_account_id, &1.role, &1.cursor_kind})
    |> Enum.flat_map(fn {_identity, account_cycles} ->
      account_cycles
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [previous, current] ->
        if current.lower_cursor == previous.upper_cursor,
          do: [],
          else: [:cursor_chain_gap]
      end)
    end)
  end

  defp cycle_job_ids(cycle) do
    [cycle.acquisition_job_id | cycle.reason_job_ids] ++ List.wrap(cycle.finalizer_job_id)
  end

  defp activity_visible_job_ids([]), do: []

  defp activity_visible_job_ids(job_ids) do
    Maraithon.Runtime.BackgroundJob
    |> where([job], job.id in ^Enum.uniq(job_ids))
    |> select([job], job.id)
    |> Repo.all()
  end

  defp percent(_part, 0), do: 100.0
  defp percent(part, total), do: Float.round(part * 100.0 / total, 2)

  defp count(schema, cycle_id) do
    Repo.aggregate(from(row in schema, where: row.cycle_id == ^cycle_id), :count)
  end

  defp get_cycle(%SourceCycle{id: id}) when is_binary(id), do: Repo.get(SourceCycle, id)

  defp get_cycle(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, normalized} -> Repo.get(SourceCycle, normalized)
      :error -> nil
    end
  end

  defp get_cycle(_other), do: nil

  defp source_manifest_digest(items) do
    items
    |> Enum.map(fn item ->
      Enum.join(
        [
          hex(item.source_ref_digest),
          hex(item.source_identity_digest),
          hex(item.source_revision_digest)
        ],
        ":"
      )
    end)
    |> joined_digest()
  end

  defp todo_manifest_digest(snapshots) do
    snapshots
    |> Enum.map(fn snapshot -> "#{snapshot.todo_id}:#{hex(snapshot.todo_state_digest)}" end)
    |> joined_digest()
  end

  defp joined_digest(parts) do
    parts
    |> Enum.map(fn
      nil -> ""
      part when is_binary(part) -> part
    end)
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp validated_map(changeset, fields) do
    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, struct} -> Map.take(struct, fields)
      {:error, invalid} -> {:error, invalid}
    end
  end

  defp insert_validated_rows(_schema, []), do: :ok

  defp insert_validated_rows(schema, rows) do
    case Enum.find(rows, &match?({:error, _changeset}, &1)) do
      {:error, changeset} ->
        {:error, changeset}

      nil ->
        case Repo.insert_all(schema, rows) do
          {count, _rows} when count == length(rows) -> :ok
          _other -> {:error, :source_cycle_insert_incomplete}
        end
    end
  end

  defp ensure_item_owner({:ok, items}, _identity), do: {:ok, items}
  defp ensure_item_owner(error, _identity), do: error

  defp ensure_snapshot_role({:ok, []}, _identity), do: {:ok, []}
  defp ensure_snapshot_role({:ok, snapshots}, %{role: "closure"}), do: {:ok, snapshots}

  defp ensure_snapshot_role({:ok, _snapshots}, _identity),
    do: {:error, :invalid_todo_snapshot_role}

  defp ensure_snapshot_role(error, _identity), do: error

  defp reject_duplicate({:ok, rows}, field, reason) do
    values = Enum.map(rows, &Map.fetch!(&1, field))
    if length(values) == length(Enum.uniq(values)), do: {:ok, rows}, else: {:error, reason}
  end

  defp reject_duplicate(error, _field, _reason), do: error

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error

  defp fanout_shape([], nil), do: :ok
  defp fanout_shape([_first | _rest], finalizer) when is_binary(finalizer), do: :ok
  defp fanout_shape(_reason_jobs, _finalizer), do: {:error, :invalid_source_cycle_fanout}

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp uuids(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, ids} ->
      case uuid(value) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_ok()
    |> case do
      {:ok, ids} ->
        if length(ids) == length(Enum.uniq(ids)),
          do: {:ok, ids},
          else: {:error, :duplicate_reason_job}

      error ->
        error
    end
  end

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: uuid(value)

  defp digest(value) when is_binary(value) and byte_size(value) == 32, do: {:ok, value}
  defp digest(_value), do: {:error, :invalid_digest}

  defp optional_digest(nil), do: {:ok, nil}
  defp optional_digest(value), do: digest(value)

  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(%DateTime{} = value), do: {:ok, value}
  defp optional_datetime(_value), do: {:error, :invalid_datetime}

  defp optional_nonnegative(nil), do: {:ok, nil}
  defp optional_nonnegative(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp optional_nonnegative(_value), do: {:error, :invalid_ingress_sequence}

  defp hex(nil), do: ""
  defp hex(value) when is_binary(value), do: Base.encode16(value, case: :lower)

  defp transact(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, _value} = result -> result
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
