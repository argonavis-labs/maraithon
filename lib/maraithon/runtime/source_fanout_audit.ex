defmodule Maraithon.Runtime.SourceFanoutAudit do
  @moduledoc """
  Verifies the durable source-account fan-out graph over a bounded time window.

  The audit is intentionally count- and identity-based. It never returns source
  payloads, but it does prove that every referenced child exists, covers the
  exact source-item identity set, and reached the cursor-advancing finalizer.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.OAuth.Token
  alias Maraithon.Repo
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobs, SourceAccountDiscovery}
  alias Maraithon.Todos.Todo

  @discovery_acquire "runtime_partition:source_account_discovery"
  @discovery_reason "runtime_partition:source_account_discovery_reason"
  @discovery_finalize "runtime_partition:source_account_discovery_finalize"
  @closure_acquire "runtime_partition:source_account_closure_acquire"
  @closure_reason "runtime_partition:source_account_closure_reason"
  @closure_finalize "runtime_partition:source_account_closure_finalize"
  @active_statuses ~w(pending running)
  @default_settlement_grace_seconds 600

  @doc "Returns a PII-free exact-coverage audit for source cycles since `since`."
  def verify_since(%DateTime{} = since, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    grace_seconds =
      Keyword.get(opts, :settlement_grace_seconds, @default_settlement_grace_seconds)

    cutoff = DateTime.add(now, -grace_seconds, :second)

    jobs = load_jobs(since, now)
    jobs_by_id = Map.new(jobs, &{&1.id, &1})
    expected_accounts = expected_accounts()

    acquisition_jobs =
      jobs
      |> Enum.filter(&(&1.job_type in [@discovery_acquire, @closure_acquire]))

    cycles =
      acquisition_jobs
      |> Enum.filter(&cycle_ready_for_audit?(&1, jobs_by_id, cutoff))
      |> Enum.map(&audit_cycle(&1, jobs_by_id))

    stalled_cycles =
      acquisition_jobs
      |> Enum.filter(fn job ->
        DateTime.compare(job.inserted_at, cutoff) != :gt and cycle_in_flight?(job, jobs_by_id)
      end)

    current_cycles = latest_cycles_by_account(cycles)

    discovery =
      role_summary(
        cycles,
        current_cycles,
        "discovery",
        expected_accounts.discovery,
        jobs,
        cutoff
      )

    closure =
      role_summary(cycles, current_cycles, "closure", expected_accounts.closure, jobs, cutoff)

    errors =
      Enum.flat_map(current_cycles, & &1.errors) ++
        if(stalled_cycles == [],
          do: [],
          else: List.duplicate(:stalled_cycle, length(stalled_cycles))
        )

    activity = activity_summary(jobs, cycles, cutoff)

    closure_covered? =
      closure.expected_account_count == 0 or
        (closure.cycles > 0 and closure.missing_account_ids == [])

    %{
      healthy?:
        errors == [] and discovery.missing_account_ids == [] and discovery.cycles > 0 and
          closure_covered? and stalled_cycles == [] and activity.every_fanout_visible?,
      since: DateTime.to_iso8601(since),
      until: DateTime.to_iso8601(now),
      settlement_grace_seconds: grace_seconds,
      in_flight_cycles: Enum.count(acquisition_jobs, &cycle_in_flight?(&1, jobs_by_id)),
      stalled_cycles: length(stalled_cycles),
      discovery: discovery,
      closure: closure,
      activity: activity,
      error_codes: errors |> Enum.map(&Atom.to_string/1) |> Enum.frequencies()
    }
  end

  defp cycle_ready_for_audit?(job, jobs_by_id, cutoff) do
    DateTime.compare(job.inserted_at, cutoff) != :gt and not cycle_in_flight?(job, jobs_by_id)
  end

  defp cycle_in_flight?(%BackgroundJob{status: status}, _jobs_by_id)
       when status in @active_statuses,
       do: true

  defp cycle_in_flight?(%BackgroundJob{status: "completed", result: result}, jobs_by_id) do
    if map_string(result, "outcome") == "fanout_ready" do
      result
      |> referenced_fanout_job_ids()
      |> Enum.map(&Map.get(jobs_by_id, &1))
      |> Enum.any?(&match?(%BackgroundJob{status: status} when status in @active_statuses, &1))
    else
      false
    end
  end

  defp cycle_in_flight?(_job, _jobs_by_id), do: false

  defp referenced_fanout_job_ids(result) do
    map_string_list(result, "reason_job_ids") ++
      case map_string(result, "finalizer_job_id") do
        id when is_binary(id) -> [id]
        _missing -> []
      end
  end

  defp latest_cycles_by_account(cycles) do
    cycles
    |> Enum.group_by(&{&1.role, &1.account_id})
    |> Enum.map(fn {_identity, account_cycles} ->
      Enum.max_by(account_cycles, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
    end)
  end

  defp load_jobs(since, until_time) do
    job_types = BackgroundJobs.source_account_job_types()

    BackgroundJob
    |> where(
      [job],
      job.job_type in ^job_types and job.inserted_at >= ^since and
        job.inserted_at < ^until_time
    )
    |> order_by([job], asc: job.inserted_at, asc: job.id)
    |> Repo.all()
    |> Enum.map(&BackgroundJob.hydrate_payloads/1)
  end

  defp expected_accounts do
    discovery =
      ConnectedAccount
      |> join(:inner, [account], token in Token,
        on: token.user_id == account.user_id and token.provider == account.provider
      )
      |> where(
        [account, _token],
        account.status == "connected" and
          (like(account.provider, "google%") or
             fragment("? ~ '^slack:[^:]+$'", account.provider))
      )
      |> distinct([account, _token], account.id)
      |> select([account, _token], {account.id, account.provider})
      |> Repo.all()

    open_todo_user_ids =
      Todo
      |> where([todo], todo.status in ["open", "snoozed"])
      |> distinct([todo], todo.user_id)
      |> select([todo], todo.user_id)

    closure =
      ConnectedAccount
      |> join(:inner, [account], token in Token,
        on: token.user_id == account.user_id and token.provider == account.provider
      )
      |> where(
        [account, _token],
        account.user_id in subquery(open_todo_user_ids) and account.status == "connected" and
          (like(account.provider, "google%") or
             fragment("? ~ '^slack:[^:]+$'", account.provider))
      )
      |> distinct([account, _token], account.id)
      |> select([account, _token], {account.id, account.provider})
      |> Repo.all()

    %{discovery: discovery, closure: closure}
  end

  defp audit_cycle(acquisition, jobs_by_id) do
    role = if acquisition.job_type == @discovery_acquire, do: "discovery", else: "closure"
    reason_type = if role == "discovery", do: @discovery_reason, else: @closure_reason
    finalize_type = if role == "discovery", do: @discovery_finalize, else: @closure_finalize
    result = acquisition.result || %{}
    account_id = map_integer(acquisition.payload, "account_id")
    outcome = map_string(result, "outcome")

    base = %{
      id: acquisition.id,
      inserted_at: acquisition.inserted_at,
      role: role,
      account_id: account_id,
      acquisition_reference: String.slice(acquisition.id, 0, 8),
      status: acquisition.status,
      outcome: outcome,
      source_items: map_integer(result, "source_items"),
      todo_count: map_integer(result, "todo_count"),
      decision_count: 0,
      fanout_count: 0,
      model_calls: 0,
      reason_job_ids: [],
      exact?: false,
      errors: []
    }

    cond do
      acquisition.status != "completed" ->
        %{base | errors: [:acquisition_not_completed]}

      outcome == "empty_delta" and base.source_items == 0 and
          map_integer(result, "advanced_watermarks") == 1 ->
        %{base | exact?: true}

      role == "closure" and outcome == "no_open_todos" and
          map_integer(result, "advanced_watermarks") == 1 ->
        %{base | exact?: true}

      outcome == "fanout_ready" ->
        audit_fanout_cycle(base, acquisition, jobs_by_id, reason_type, finalize_type)

      true ->
        %{base | errors: [:invalid_acquisition_result]}
    end
  end

  defp audit_fanout_cycle(base, acquisition, jobs_by_id, reason_type, finalize_type) do
    result = acquisition.result || %{}
    reason_ids = map_string_list(result, "reason_job_ids")
    finalizer_id = map_string(result, "finalizer_job_id")
    expected_fanouts = map_integer(result, "fanout_count")
    expected_items = map_integer(result, "source_items")
    reasons = Enum.map(reason_ids, &Map.get(jobs_by_id, &1))
    finalizer = Map.get(jobs_by_id, finalizer_id)

    child_indexes =
      reasons
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&map_integer(&1.payload, "fanout_index"))
      |> Enum.sort()

    child_results =
      reasons
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&(&1.result || %{}))

    raw_decision_refs = Enum.flat_map(child_results, &map_string_list(&1, "decision_refs"))

    {decision_refs, decision_count} =
      if base.role == "closure" do
        unique_refs = Enum.uniq(raw_decision_refs)
        {unique_refs, length(unique_refs)}
      else
        {raw_decision_refs, Enum.sum(Enum.map(child_results, &map_integer(&1, "decision_count")))}
      end

    model_calls = Enum.sum(Enum.map(child_results, &map_integer(&1, "model_calls")))

    expected_decisions =
      if base.role == "closure", do: map_integer(result, "todo_count"), else: expected_items

    errors =
      []
      |> require_error(expected_fanouts > 0 and expected_items > 0, :invalid_expected_counts)
      |> require_error(length(reason_ids) == expected_fanouts, :reason_reference_count_mismatch)
      |> require_error(Enum.all?(reasons, &match?(%BackgroundJob{}, &1)), :reason_job_missing)
      |> require_error(
        Enum.all?(reasons, &(&1 && &1.job_type == reason_type && &1.status == "completed")),
        :reason_job_not_completed
      )
      |> require_error(
        Enum.all?(
          reasons,
          &(&1 && map_string(&1.payload, "acquisition_job_id") == acquisition.id)
        ),
        :reason_acquisition_mismatch
      )
      |> require_error(child_indexes == Enum.to_list(1..max(expected_fanouts, 1)), :fanout_gap)
      |> require_coverage(
        base.role,
        child_results,
        finalizer,
        expected_items,
        expected_decisions,
        decision_count,
        decision_refs
      )
      |> require_error(
        finalizer_valid?(finalizer, finalize_type, acquisition.id),
        :finalizer_invalid
      )
      |> require_error(
        finalizer_reason_ids(finalizer) == reason_ids,
        :finalizer_reason_reference_mismatch
      )
      |> require_error(
        decision_digest_valid?(decision_refs, finalizer, base.role),
        :decision_reference_digest_mismatch
      )
      |> require_error(
        finalized_counts_valid?(
          finalizer,
          expected_items,
          expected_decisions,
          expected_fanouts
        ),
        :finalized_count_mismatch
      )

    %{
      base
      | source_items: expected_items,
        todo_count: expected_decisions,
        decision_count: decision_count,
        fanout_count: expected_fanouts,
        model_calls: model_calls,
        reason_job_ids: reason_ids,
        exact?: errors == [],
        errors: errors
    }
  end

  defp require_coverage(
         errors,
         "discovery",
         child_results,
         _finalizer,
         expected_items,
         expected_decisions,
         decision_count,
         decision_refs
       ) do
    child_items = Enum.sum(Enum.map(child_results, &map_integer(&1, "source_items")))

    errors
    |> require_error(child_items == expected_items, :source_item_count_mismatch)
    |> require_decision_manifest(expected_decisions, decision_count, decision_refs)
    |> require_error(
      discovery_action_manifest_valid?(child_results, decision_refs),
      :source_decision_action_manifest_invalid
    )
  end

  defp require_coverage(
         errors,
         "closure",
         child_results,
         finalizer,
         expected_items,
         expected_decisions,
         decision_count,
         decision_refs
       ) do
    expected_source_digest =
      map_string(finalizer && finalizer.payload, "expected_source_refs_digest")

    source_partition_count =
      map_integer(finalizer && finalizer.payload, "expected_source_partitions")

    todo_batch_count = map_integer(finalizer && finalizer.payload, "expected_todo_batches")

    coordinates =
      Enum.map(child_results, fn result ->
        {map_integer(result, "todo_batch_index"), map_integer(result, "source_partition_index")}
      end)

    expected_coordinates =
      for todo_batch <- 1..max(todo_batch_count, 1),
          source_partition <- 1..max(source_partition_count, 1),
          do: {todo_batch, source_partition}

    source_coverage? =
      source_partition_count > 0 and todo_batch_count > 0 and
        Enum.all?(1..todo_batch_count, fn todo_batch_index ->
          refs =
            child_results
            |> Enum.filter(&(map_integer(&1, "todo_batch_index") == todo_batch_index))
            |> Enum.sort_by(&map_integer(&1, "source_partition_index"))
            |> Enum.flat_map(&map_string_list(&1, "source_item_refs"))

          length(refs) == expected_items and length(Enum.uniq(refs)) == expected_items and
            SourceAccountDiscovery.refs_digest(refs) == expected_source_digest
        end)

    todo_coverage? =
      source_partition_count > 0 and todo_batch_count > 0 and
        Enum.all?(1..source_partition_count, fn source_partition_index ->
          refs =
            child_results
            |> Enum.filter(&(map_integer(&1, "source_partition_index") == source_partition_index))
            |> Enum.sort_by(&map_integer(&1, "todo_batch_index"))
            |> Enum.flat_map(&map_string_list(&1, "decision_refs"))

          length(refs) == expected_decisions and
            length(Enum.uniq(refs)) == expected_decisions
        end)

    errors
    |> require_error(
      length(child_results) == source_partition_count * todo_batch_count and
        Enum.sort(coordinates) == Enum.sort(expected_coordinates),
      :fanout_matrix_mismatch
    )
    |> require_error(source_coverage?, :source_item_count_mismatch)
    |> require_error(todo_coverage?, :todo_decision_coverage_mismatch)
    |> require_error(
      is_binary(expected_source_digest),
      :source_reference_digest_mismatch
    )
    |> require_decision_manifest(expected_decisions, decision_count, decision_refs)
    |> require_error(
      closure_action_manifest_valid?(child_results, decision_refs),
      :todo_decision_action_manifest_invalid
    )
  end

  defp require_decision_manifest(errors, expected, decision_count, decision_refs) do
    errors
    |> require_error(expected > 0, :invalid_expected_decision_count)
    |> require_error(decision_count == expected, :decision_count_mismatch)
    |> require_error(length(decision_refs) == expected, :decision_reference_count_mismatch)
    |> require_error(length(Enum.uniq(decision_refs)) == expected, :duplicate_decision_reference)
  end

  defp finalizer_valid?(%BackgroundJob{} = job, type, acquisition_id) do
    job.job_type == type and job.status == "completed" and
      map_string(job.payload, "acquisition_job_id") == acquisition_id and
      map_string(job.result, "outcome") == "finalized"
  end

  defp finalizer_valid?(_job, _type, _acquisition_id), do: false

  defp finalizer_reason_ids(%BackgroundJob{} = job),
    do: map_string_list(job.payload, "reason_job_ids")

  defp finalizer_reason_ids(_job), do: []

  defp decision_digest_valid?(refs, %BackgroundJob{} = finalizer, role) do
    key =
      if role == "closure", do: "expected_todo_refs_digest", else: "expected_source_refs_digest"

    expected = map_string(finalizer.payload, key)
    is_binary(expected) and SourceAccountDiscovery.refs_digest(refs) == expected
  end

  defp decision_digest_valid?(_refs, _finalizer, _role), do: false

  defp finalized_counts_valid?(%BackgroundJob{} = finalizer, source_items, decisions, fanouts) do
    map_integer(finalizer.result, "source_items") == source_items and
      map_integer(finalizer.result, "decision_count") == decisions and
      map_integer(finalizer.result, "fanout_count") == fanouts and
      map_integer(finalizer.result, "advanced_watermarks") == 1
  end

  defp finalized_counts_valid?(_finalizer, _source_items, _decisions, _fanouts), do: false

  defp role_summary(cycles, current_cycles, role, expected_accounts, jobs, cutoff) do
    selected = Enum.filter(cycles, &(&1.role == role))
    exact = Enum.filter(selected, & &1.exact?)
    current = Enum.filter(current_cycles, &(&1.role == role))
    current_exact = Enum.filter(current, & &1.exact?)

    covered_ids =
      current_exact |> Enum.map(& &1.account_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    expected_ids = expected_accounts |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    source_items = Enum.sum(Enum.map(selected, & &1.source_items))
    todo_count = Enum.sum(Enum.map(selected, & &1.todo_count))
    decisions = Enum.sum(Enum.map(selected, & &1.decision_count))
    model_calls = Enum.sum(Enum.map(selected, & &1.model_calls))
    reason_type = if role == "discovery", do: @discovery_reason, else: @closure_reason

    %{
      cycles: length(selected),
      exact_cycles: length(exact),
      current_cycles: length(current),
      current_exact_cycles: length(current_exact),
      empty_delta_cycles: Enum.count(exact, &(&1.outcome == "empty_delta")),
      fanout_cycles: Enum.count(exact, &(&1.outcome == "fanout_ready")),
      failed_cycles: length(selected) - length(exact),
      cycle_coverage_percent: percent(length(exact), length(selected)),
      source_items: source_items,
      todo_count: todo_count,
      decisions: decisions,
      item_coverage_percent:
        percent(decisions, if(role == "closure", do: todo_count, else: source_items)),
      fanout_workers:
        Enum.count(
          jobs,
          &(&1.job_type == reason_type and DateTime.compare(&1.inserted_at, cutoff) != :gt)
        ),
      model_calls: model_calls,
      source_items_per_model_call: ratio(source_items, model_calls),
      expected_account_count: length(expected_ids),
      covered_account_count: length(covered_ids),
      missing_account_ids: expected_ids -- covered_ids,
      providers: provider_counts(expected_accounts),
      failures:
        selected
        |> Enum.reject(& &1.exact?)
        |> Enum.map(fn cycle ->
          %{
            account_id: cycle.account_id,
            acquisition_reference: cycle.acquisition_reference,
            errors: Enum.map(cycle.errors, &Atom.to_string/1)
          }
        end),
      current_failures:
        current
        |> Enum.reject(& &1.exact?)
        |> Enum.map(fn cycle ->
          %{
            account_id: cycle.account_id,
            acquisition_reference: cycle.acquisition_reference,
            errors: Enum.map(cycle.errors, &Atom.to_string/1)
          }
        end)
    }
  end

  defp activity_summary(jobs, _cycles, cutoff) do
    settled_jobs = Enum.filter(jobs, &(DateTime.compare(&1.inserted_at, cutoff) != :gt))
    expected_job_ids = Enum.map(jobs, & &1.id)
    visible_ids = activity_visible_ids(expected_job_ids)

    %{
      rows: length(settled_jobs),
      rows_by_type: Enum.frequencies_by(settled_jobs, & &1.job_type),
      expected_fanout_rows: length(expected_job_ids),
      visible_fanout_rows: Enum.count(expected_job_ids, &MapSet.member?(visible_ids, &1)),
      every_fanout_visible?: Enum.all?(expected_job_ids, &MapSet.member?(visible_ids, &1)),
      active_retry_rows: Enum.count(jobs, &(&1.status in @active_statuses)),
      active_recent_rows:
        Enum.count(
          jobs,
          &(&1.status in @active_statuses and DateTime.compare(&1.inserted_at, cutoff) == :gt)
        )
    }
  end

  defp activity_visible_ids([]), do: MapSet.new()

  defp activity_visible_ids(expected_job_ids) do
    visible_ids =
      BackgroundJob
      |> where(
        [job],
        job.id in ^expected_job_ids and job.job_type in ^BackgroundJobs.source_account_job_types() and
          not is_nil(job.user_id) and not is_nil(job.dedupe_key)
      )
      |> select([job], job.id)
      |> Repo.all()

    MapSet.new(visible_ids)
  end

  defp provider_counts(accounts) do
    accounts
    |> Enum.map(fn {_id, provider} ->
      if String.starts_with?(provider, "slack:"), do: "slack", else: "gmail"
    end)
    |> Enum.frequencies()
  end

  defp discovery_action_manifest_valid?(child_results, decision_refs) do
    manifests = Enum.flat_map(child_results, &map_list(&1, "decision_manifest"))
    manifest_refs = Enum.map(manifests, &map_string(&1, "source_ref"))

    length(manifests) == length(decision_refs) and
      Enum.sort(manifest_refs) == Enum.sort(decision_refs) and
      Enum.all?(manifests, fn manifest ->
        action = map_string(manifest, "action")
        persisted_todo_id = map_string(manifest, "persisted_todo_id")

        action in ["create", "update", "skip"] and
          if(action == "skip", do: is_nil(persisted_todo_id), else: is_binary(persisted_todo_id))
      end)
  end

  defp closure_action_manifest_valid?(child_results, decision_refs) do
    manifests = Enum.flat_map(child_results, &map_list(&1, "todo_decision_manifest"))
    manifest_refs = Enum.map(manifests, &map_string(&1, "todo_ref"))

    Enum.all?(child_results, fn result ->
      result_refs = map_string_list(result, "decision_refs")
      result_manifests = map_list(result, "todo_decision_manifest")
      result_manifest_refs = Enum.map(result_manifests, &map_string(&1, "todo_ref"))

      length(result_manifests) == length(result_refs) and
        Enum.sort(result_manifest_refs) == Enum.sort(result_refs) and
        Enum.all?(result_manifests, fn manifest ->
          map_string(manifest, "action") in ["evaluated", "superseded"]
        end)
    end) and Enum.sort(Enum.uniq(manifest_refs)) == Enum.sort(decision_refs)
  end

  defp require_error(errors, true, _error), do: errors
  defp require_error(errors, false, error), do: errors ++ [error]

  defp percent(_part, 0), do: 100.0
  defp percent(part, total), do: Float.round(part * 100.0 / total, 2)
  defp ratio(_part, 0), do: nil
  defp ratio(part, total), do: Float.round(part / total, 2)

  defp map_string(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, key_atom(key))) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp map_string(_map, _key), do: nil

  defp map_integer(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, key_atom(key), 0)) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp map_integer(_map, _key), do: 0

  defp map_string_list(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, key_atom(key), [])) do
      values when is_list(values) -> Enum.filter(values, &(is_binary(&1) and &1 != ""))
      _other -> []
    end
  end

  defp map_string_list(_map, _key), do: []

  defp map_list(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, key_atom(key), [])) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp map_list(_map, _key), do: []

  defp key_atom("account_id"), do: :account_id
  defp key_atom("acquisition_job_id"), do: :acquisition_job_id
  defp key_atom("decision_count"), do: :decision_count
  defp key_atom("decision_refs"), do: :decision_refs
  defp key_atom("decision_manifest"), do: :decision_manifest
  defp key_atom("action"), do: :action
  defp key_atom("persisted_todo_id"), do: :persisted_todo_id
  defp key_atom("source_ref"), do: :source_ref
  defp key_atom("advanced_watermarks"), do: :advanced_watermarks
  defp key_atom("expected_source_refs_digest"), do: :expected_source_refs_digest
  defp key_atom("expected_todo_refs_digest"), do: :expected_todo_refs_digest
  defp key_atom("fanout_count"), do: :fanout_count
  defp key_atom("fanout_index"), do: :fanout_index
  defp key_atom("finalizer_job_id"), do: :finalizer_job_id
  defp key_atom("model_calls"), do: :model_calls
  defp key_atom("outcome"), do: :outcome
  defp key_atom("reason_job_ids"), do: :reason_job_ids
  defp key_atom("source_items"), do: :source_items
  defp key_atom("source_item_refs"), do: :source_item_refs
  defp key_atom("source_partition_count"), do: :source_partition_count
  defp key_atom("source_partition_index"), do: :source_partition_index
  defp key_atom("source_refs_digest"), do: :source_refs_digest
  defp key_atom("todo_batch_count"), do: :todo_batch_count
  defp key_atom("todo_batch_index"), do: :todo_batch_index
  defp key_atom("todo_decision_manifest"), do: :todo_decision_manifest
  defp key_atom("todo_ref"), do: :todo_ref
  defp key_atom("todo_count"), do: :todo_count
  defp key_atom(_key), do: :__missing__
end
