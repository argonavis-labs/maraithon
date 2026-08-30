defmodule Maraithon.Runtime.SourceAccountClosure do
  @moduledoc """
  Runs one source-account closure worker as a durable provider/model handoff.

  The provider lane reads only the account's closure delta. Empty deltas move
  the closure cursor without model work. A non-empty delta is sealed once and
  handed to small todo batches, so each quick worker sees the complete later
  evidence while every open todo is evaluated exactly once. A finalizer moves
  the cursor only after the complete todo manifest is proven.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.SourceAccountDiscovery
  alias Maraithon.Runtime.TodoCompletionSweep
  alias Maraithon.Todos.Todo

  @todo_batch_size 10
  @allowed_watermark_kinds ~w(gmail_closure_watermark slack_closure_watermark)

  def acquire(account, opts \\ [])

  def acquire(%ConnectedAccount{status: "connected"} = account, opts) when is_list(opts) do
    with {:ok, bundle, proposals} <- TodoCompletionSweep.acquire_account_delta(account, opts),
         watermarks <- serialize_watermarks(proposals, account.id),
         :ok <- validate_watermarks(watermarks),
         {:ok, source_partitions} <- SourceAccountDiscovery.partition_bundle(bundle),
         source_items <-
           Enum.sum(Enum.map(source_partitions, &SourceAccountDiscovery.source_item_count/1)),
         source_refs <- SourceAccountDiscovery.source_item_refs(bundle),
         true <- length(source_refs) == source_items,
         todo_ids <- TodoCompletionSweep.open_todo_ids_for_account(account, opts) do
      cond do
        source_items == 0 ->
          settle_without_fanout(account, watermarks, "empty_delta", 0, opts)

        todo_ids == [] ->
          settle_without_fanout(account, watermarks, "no_open_todos", source_items, opts)

        true ->
          build_fanout(account, bundle, watermarks, source_refs, todo_ids, opts)
      end
    else
      false -> {:error, :source_closure_source_identity_mismatch}
      nil -> {:error, :invalid_source_bundle}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_closure_result}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def acquire(%ConnectedAccount{}, _opts), do: {:skip, :account_not_connected}
  def acquire(_account, _opts), do: {:error, :invalid_source_account}

  defp settle_without_fanout(account, watermarks, outcome, source_items, opts) do
    with {:ok, watermark_result} <- settle_watermarks(account, watermarks, opts) do
      {:ok,
       Map.merge(
         %{
           outcome: outcome,
           account_id: account.id,
           source_items: source_items,
           todo_decision_count: 0,
           model_calls: 0
         },
         watermark_result
       )}
    end
  end

  defp build_fanout(account, bundle, watermarks, source_refs, todo_ids, opts) do
    case SourceAccountDiscovery.compact_bundle(bundle) do
      compact when is_map(compact) ->
        todo_batches = Enum.chunk_every(todo_ids, @todo_batch_size)
        fanout_count = length(todo_batches)
        source_items = length(source_refs)
        source_refs_digest = SourceAccountDiscovery.refs_digest(source_refs)

        with {:ok, handoffs} <-
               build_bounded_handoffs(
                 todo_batches,
                 account,
                 compact,
                 source_refs,
                 source_refs_digest,
                 fanout_count,
                 opts
               ) do
          {:ok,
           %{
             outcome: "fanout_ready",
             account_id: account.id,
             source_items: source_items,
             todo_count: length(todo_ids),
             fanout_count: fanout_count,
             handoffs: handoffs,
             finalizer: %{
               "account_id" => account.id,
               "acquisition_job_id" => Keyword.get(opts, :acquisition_job_id),
               "expected_fanouts" => fanout_count,
               "expected_source_items" => source_items,
               "expected_source_refs_digest" => source_refs_digest,
               "expected_todo_count" => length(todo_ids),
               "expected_todo_refs_digest" => SourceAccountDiscovery.refs_digest(todo_ids),
               "watermarks" => watermarks
             }
           }}
        end

      nil ->
        {:error, :source_closure_delta_too_large}
    end
  end

  defp build_bounded_handoffs(
         todo_batches,
         account,
         compact,
         source_refs,
         source_refs_digest,
         fanout_count,
         opts
       ) do
    source_items = length(source_refs)

    todo_batches
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], compact}, fn
      {todo_batch, fanout_index}, {:ok, handoffs, prepared_bundle} ->
        handoff = %{
          "account_id" => account.id,
          "acquisition_job_id" => Keyword.get(opts, :acquisition_job_id),
          "fanout_index" => fanout_index,
          "fanout_count" => fanout_count,
          "source_items" => source_items,
          "source_item_refs" => source_refs,
          "source_refs_digest" => source_refs_digest,
          "source_bundle" => prepared_bundle,
          "todo_ids" => todo_batch,
          "todo_count" => length(todo_batch),
          "watermarks" => []
        }

        case SourceAccountDiscovery.bound_handoff(handoff) do
          {:ok, bounded_handoff} ->
            {:cont,
             {:ok, [bounded_handoff | handoffs], Map.fetch!(bounded_handoff, "source_bundle")}}

          {:error, _reason} ->
            {:halt, {:error, :source_closure_handoff_payload_too_large}}
        end
    end)
    |> case do
      {:ok, handoffs, _prepared_bundle} -> {:ok, Enum.reverse(handoffs)}
      {:error, _reason} = error -> error
    end
  end

  def reason(account, payload, opts \\ [])

  def reason(%ConnectedAccount{} = account, payload, opts)
      when is_map(payload) and is_list(opts) do
    with true <- read_integer(payload, "account_id") == account.id,
         {:ok, bundle} <- fetch_map(payload, "source_bundle"),
         {:ok, bundle} <- SourceAccountDiscovery.restore_partition_bundle(bundle),
         fanout_index when is_integer(fanout_index) and fanout_index > 0 <-
           read_integer(payload, "fanout_index"),
         fanout_count when is_integer(fanout_count) and fanout_count >= fanout_index <-
           read_integer(payload, "fanout_count"),
         expected_source_items
         when is_integer(expected_source_items) and expected_source_items > 0 <-
           read_integer(payload, "source_items"),
         {:ok, source_item_refs} <- fetch_list(payload, "source_item_refs"),
         expected_source_refs_digest when is_binary(expected_source_refs_digest) <-
           read_string(payload, "source_refs_digest"),
         {:ok, todo_ids} <- fetch_list(payload, "todo_ids"),
         expected_todo_count when is_integer(expected_todo_count) and expected_todo_count > 0 <-
           read_integer(payload, "todo_count"),
         true <- length(todo_ids) == expected_todo_count,
         true <- length(Enum.uniq(todo_ids)) == expected_todo_count,
         ^expected_source_items <- SourceAccountDiscovery.source_item_count(bundle),
         ^source_item_refs <- SourceAccountDiscovery.source_item_refs(bundle),
         true <-
           SourceAccountDiscovery.refs_digest(source_item_refs) == expected_source_refs_digest,
         result when is_map(result) <-
           TodoCompletionSweep.run_for_account(
             account,
             opts
             |> Keyword.put(:exact_source_delta, true)
             |> Keyword.put(:skip_deterministic_completion, true)
             |> Keyword.put(:source_bundle, bundle)
             |> Keyword.put(:source_item_refs, source_item_refs)
             |> Keyword.put(:todo_ids, todo_ids)
           ),
         true <- settled_result?(result),
         {:ok, todo_manifest} <-
           TodoCompletionSweep.resolve_todo_decision_manifest(
             account,
             todo_ids,
             Map.get(result, :todo_decision_refs, [])
           ) do
      {:ok,
       %{
         outcome: "evaluated",
         account_id: account.id,
         source_items: expected_source_items,
         source_refs_digest: expected_source_refs_digest,
         decision_count: expected_todo_count,
         decision_refs: todo_manifest.decision_refs,
         todo_decision_count: expected_todo_count,
         todo_decision_refs: todo_manifest.decision_refs,
         evaluated_todo_decision_count: length(todo_manifest.evaluated_refs),
         evaluated_todo_decision_refs: todo_manifest.evaluated_refs,
         superseded_todo_decision_count: length(todo_manifest.superseded_refs),
         superseded_todo_decision_refs: todo_manifest.superseded_refs,
         todo_decision_manifest:
           Enum.map(todo_manifest.evaluated_refs, &%{todo_ref: &1, action: "evaluated"}) ++
             Enum.map(todo_manifest.superseded_refs, &%{todo_ref: &1, action: "superseded"}),
         model_calls: Map.get(result, :model_calls, 0),
         fanout_index: fanout_index,
         fanout_count: fanout_count,
         result: result
       }}
    else
      false -> {:error, :source_closure_unsettled_or_identity_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_closure_payload}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def reason(_account, _payload, _opts), do: {:error, :invalid_source_closure_payload}

  @doc "Advances a closure cursor only after all source partitions prove complete."
  def finalize(account, payload, child_results, opts \\ [])

  def finalize(%ConnectedAccount{} = account, payload, child_results, opts)
      when is_map(payload) and is_list(child_results) and is_list(opts) do
    with true <- read_integer(payload, "account_id") == account.id,
         {:ok, watermarks} <- fetch_list(payload, "watermarks"),
         expected_fanouts when is_integer(expected_fanouts) and expected_fanouts > 0 <-
           read_integer(payload, "expected_fanouts"),
         expected_source_items
         when is_integer(expected_source_items) and expected_source_items > 0 <-
           read_integer(payload, "expected_source_items"),
         expected_source_refs_digest when is_binary(expected_source_refs_digest) <-
           read_string(payload, "expected_source_refs_digest"),
         expected_todo_count when is_integer(expected_todo_count) and expected_todo_count > 0 <-
           read_integer(payload, "expected_todo_count"),
         expected_todo_refs_digest when is_binary(expected_todo_refs_digest) <-
           read_string(payload, "expected_todo_refs_digest"),
         :ok <-
           validate_child_results(
             account,
             child_results,
             expected_fanouts,
             expected_source_items,
             expected_source_refs_digest,
             expected_todo_count,
             expected_todo_refs_digest
           ),
         {:ok, watermark_result} <- settle_watermarks(account, watermarks, opts) do
      {:ok,
       Map.merge(
         %{
           outcome: "finalized",
           account_id: account.id,
           fanout_count: expected_fanouts,
           source_items: expected_source_items,
           todo_count: expected_todo_count,
           decision_count: expected_todo_count,
           todo_decision_count: expected_todo_count,
           model_calls: Enum.sum(Enum.map(child_results, &result_integer(&1, "model_calls")))
         },
         watermark_result
       )}
    else
      false -> {:error, :source_closure_finalizer_identity_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_closure_finalizer}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def finalize(_account, _payload, _child_results, _opts),
    do: {:error, :invalid_source_closure_finalizer}

  defp settled_result?(%{
         errors: 0,
         fetch_errors: 0,
         coverage_complete?: true,
         cross_source: cross_source
       })
       when is_map(cross_source),
       do: true

  defp settled_result?(_result), do: false

  defp validate_child_results(
         account,
         child_results,
         expected_fanouts,
         expected_source_items,
         expected_source_refs_digest,
         expected_todo_count,
         expected_todo_refs_digest
       ) do
    indexes = child_results |> Enum.map(&result_integer(&1, "fanout_index")) |> Enum.sort()
    source_item_counts = Enum.map(child_results, &result_integer(&1, "source_items"))
    decision_count = Enum.sum(Enum.map(child_results, &result_integer(&1, "decision_count")))
    decision_refs = Enum.flat_map(child_results, &result_string_list(&1, "decision_refs"))
    source_digests = Enum.map(child_results, &result_string(&1, "source_refs_digest"))
    decision_manifests = Enum.flat_map(child_results, &result_list(&1, "todo_decision_manifest"))

    evaluated_refs =
      Enum.flat_map(child_results, &result_string_list(&1, "evaluated_todo_decision_refs"))

    superseded_refs =
      Enum.flat_map(child_results, &result_string_list(&1, "superseded_todo_decision_refs"))

    todo_decision_count =
      Enum.sum(Enum.map(child_results, &result_integer(&1, "todo_decision_count")))

    if length(child_results) == expected_fanouts and indexes == Enum.to_list(1..expected_fanouts) and
         Enum.all?(source_item_counts, &(&1 == expected_source_items)) and
         Enum.all?(source_digests, &(&1 == expected_source_refs_digest)) and
         decision_count == expected_todo_count and length(decision_refs) == expected_todo_count and
         length(Enum.uniq(decision_refs)) == expected_todo_count and
         SourceAccountDiscovery.refs_digest(decision_refs) == expected_todo_refs_digest and
         todo_decision_count == expected_todo_count and
         valid_closure_decision_manifest?(
           account,
           decision_manifests,
           decision_refs,
           evaluated_refs,
           superseded_refs
         ) do
      :ok
    else
      {:error, :source_closure_incomplete_decisions}
    end
  end

  defp result_integer(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, existing_atom(key), 0)) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp result_integer(_result, _key), do: 0

  defp result_string_list(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, existing_atom(key), [])) do
      values when is_list(values) -> Enum.filter(values, &(is_binary(&1) and &1 != ""))
      _other -> []
    end
  end

  defp result_string_list(_result, _key), do: []

  defp result_string(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, existing_atom(key))) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp result_string(_result, _key), do: nil

  defp result_list(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, existing_atom(key), [])) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp result_list(_result, _key), do: []

  defp valid_closure_decision_manifest?(
         account,
         manifests,
         decision_refs,
         evaluated_refs,
         superseded_refs
       ) do
    manifest_entries =
      Enum.map(manifests, fn manifest ->
        {result_string(manifest, "todo_ref"), result_string(manifest, "action")}
      end)

    manifest_refs = Enum.map(manifest_entries, &elem(&1, 0))

    manifest_evaluated_refs =
      for {todo_ref, "evaluated"} <- manifest_entries, do: todo_ref

    manifest_superseded_refs =
      for {todo_ref, "superseded"} <- manifest_entries, do: todo_ref

    length(manifests) == length(decision_refs) and
      Enum.all?(manifest_entries, fn
        {todo_ref, action}
        when is_binary(todo_ref) and action in ["evaluated", "superseded"] ->
          true

        _invalid ->
          false
      end) and
      Enum.sort(manifest_refs) == Enum.sort(decision_refs) and
      Enum.sort(manifest_evaluated_refs) == Enum.sort(evaluated_refs) and
      Enum.sort(manifest_superseded_refs) == Enum.sort(superseded_refs) and
      length(Enum.uniq(evaluated_refs ++ superseded_refs)) == length(decision_refs) and
      persisted_todos_exist?(account, decision_refs)
  end

  defp persisted_todos_exist?(account, todo_ids) do
    persisted_count =
      Todo
      |> where(
        [todo],
        todo.user_id == ^account.user_id and todo.source_account_id == ^account.id and
          todo.id in ^todo_ids
      )
      |> select([todo], count(todo.id))
      |> Repo.one()

    persisted_count == length(todo_ids)
  end

  defp serialize_watermarks(proposals, account_id) when is_list(proposals) do
    proposals
    |> Enum.flat_map(fn
      %{
        account: %ConnectedAccount{id: ^account_id},
        kind: kind,
        value: value
      }
      when kind in @allowed_watermark_kinds and is_binary(value) ->
        [%{"account_id" => account_id, "kind" => kind, "value" => value}]

      _other ->
        []
    end)
    |> Enum.uniq_by(&{&1["kind"], &1["value"]})
  end

  defp serialize_watermarks(_proposals, _account_id), do: []

  defp validate_watermarks([%{"account_id" => account_id, "kind" => kind, "value" => value}])
       when is_integer(account_id) and kind in @allowed_watermark_kinds and is_binary(value) and
              value != "",
       do: :ok

  defp validate_watermarks(_watermarks), do: {:error, :source_closure_watermark_invalid}

  defp advance_watermarks(account, watermarks) do
    Enum.reduce_while(watermarks, :ok, fn watermark, :ok ->
      with true <- read_integer(watermark, "account_id") == account.id,
           kind when kind in @allowed_watermark_kinds <- read_string(watermark, "kind"),
           value when is_binary(value) <- read_string(watermark, "value"),
           {:ok, _cursor} <- SourceCursors.put(account, kind, %{"value" => value}) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :source_closure_watermark_account_mismatch}}
        nil -> {:halt, {:error, :invalid_source_closure_watermark}}
        {:error, reason} -> {:halt, {:error, {:source_closure_cursor_advance_failed, reason}}}
        _other -> {:halt, {:error, :invalid_source_closure_watermark}}
      end
    end)
  end

  defp settle_watermarks(account, watermarks, opts)
       when is_list(watermarks) and is_list(opts) do
    if Keyword.get(opts, :defer_watermark_commit, false) do
      {:ok, %{advanced_watermarks: 0, deferred_watermarks: watermarks}}
    else
      with :ok <- advance_watermarks(account, watermarks) do
        {:ok, %{advanced_watermarks: length(watermarks)}}
      end
    end
  end

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _other -> {:error, {:missing_map_payload, key}}
    end
  end

  defp fetch_list(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      _other -> {:error, {:missing_list_payload, key}}
    end
  end

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp read_integer(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp existing_atom("fanout_index"), do: :fanout_index
  defp existing_atom("source_items"), do: :source_items
  defp existing_atom("decision_count"), do: :decision_count
  defp existing_atom("decision_refs"), do: :decision_refs
  defp existing_atom("source_refs_digest"), do: :source_refs_digest
  defp existing_atom("todo_decision_count"), do: :todo_decision_count
  defp existing_atom("todo_decision_manifest"), do: :todo_decision_manifest
  defp existing_atom("evaluated_todo_decision_refs"), do: :evaluated_todo_decision_refs
  defp existing_atom("superseded_todo_decision_refs"), do: :superseded_todo_decision_refs
  defp existing_atom("todo_ref"), do: :todo_ref
  defp existing_atom("action"), do: :action
  defp existing_atom("model_calls"), do: :model_calls
  defp existing_atom(_key), do: :__missing__
end
