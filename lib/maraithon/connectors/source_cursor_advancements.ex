defmodule Maraithon.Connectors.SourceCursorAdvancements do
  @moduledoc """
  Feature-dark Multi helper for immutable source-cursor compare-and-set proof.

  Cursor rows are locked in UUID order. A stale expected value aborts the
  caller-owned terminal transaction, so projections and work-result proof
  cannot commit without the corresponding cursor state.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Maraithon.ChiefOfStaff.AcquisitionRun
  alias Maraithon.Connectors.SourceCursor
  alias Maraithon.Connectors.SourceCursorAdvancement
  alias Maraithon.Lineage.Canonical
  alias Maraithon.Lineage.Transaction
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentWorkResult
  alias Maraithon.Runtime.AgentWorkResultAcquisition
  alias Maraithon.Runtime.DatabaseClock

  @max_acquisitions 100

  def advance_multi(%Multi{} = multi, name, result_ref, acquisition_refs)
      when is_list(acquisition_refs) do
    Multi.run(multi, name, fn _repo, changes ->
      with {:ok, result} <- resolve(changes, result_ref, AgentWorkResult),
           {:ok, acquisitions} <- resolve_acquisitions(changes, acquisition_refs) do
        advance_in_transaction(result, acquisitions)
      end
    end)
  end

  def advance_in_transaction(result_or_id, acquisitions)

  def advance_in_transaction(result_or_id, acquisitions)
      when is_list(acquisitions) and length(acquisitions) in 1..@max_acquisitions do
    with :ok <- Transaction.require(),
         {:ok, result_id} <- schema_id(result_or_id, AgentWorkResult),
         %AgentWorkResult{status: "provisional"} = result <-
           Repo.get(AgentWorkResult, result_id),
         {:ok, acquisition_ids} <- acquisition_ids(acquisitions),
         {:ok, acquisitions} <- exact_linked_acquisitions(result, acquisition_ids),
         {:ok, cursors} <- lock_cursors(acquisitions) do
      advance_all(result, acquisitions, cursors)
    else
      nil -> {:error, :work_result_not_found}
      %AgentWorkResult{} -> {:error, :work_result_not_provisional}
      {:error, reason} -> {:error, reason}
    end
  end

  def advance_in_transaction(_result_or_id, _acquisitions) do
    with :ok <- Transaction.require(), do: {:error, :invalid_cursor_advancement}
  end

  defp exact_linked_acquisitions(result, ids) do
    acquisitions =
      Repo.all(
        from(acquisition in AcquisitionRun,
          join: link in AgentWorkResultAcquisition,
          on: link.acquisition_run_id == acquisition.id,
          where: link.agent_work_result_id == ^result.id,
          where: acquisition.id in ^ids,
          where: acquisition.agent_id == ^result.agent_id,
          where: acquisition.user_id == ^result.user_id,
          where: acquisition.status == "complete",
          where: acquisition.pagination_exhausted == true,
          where: not is_nil(acquisition.sealed_at),
          where: not is_nil(acquisition.manifest_digest),
          order_by: [asc: acquisition.source_cursor_id, asc: acquisition.id]
        )
      )

    if length(acquisitions) == length(ids),
      do: {:ok, acquisitions},
      else: {:error, :cursor_acquisition_proof_mismatch}
  end

  defp lock_cursors(acquisitions) do
    cursor_ids =
      acquisitions
      |> Enum.reject(&is_nil(&1.source_cursor_id))
      |> Enum.map(& &1.source_cursor_id)
      |> Enum.uniq()
      |> Enum.sort()

    cursors =
      Repo.all(
        from(cursor in SourceCursor,
          where: cursor.id in ^cursor_ids,
          order_by: [asc: cursor.id],
          lock: "FOR UPDATE"
        )
      )

    if length(cursors) == length(cursor_ids),
      do: {:ok, Map.new(cursors, &{&1.id, &1})},
      else: {:error, :source_cursor_not_found}
  end

  defp advance_all(result, acquisitions, cursors) do
    acquisitions
    |> Enum.reduce_while({:ok, []}, fn acquisition, {:ok, advanced} ->
      case advance_one(result, acquisition, cursors) do
        {:ok, nil} -> {:cont, {:ok, advanced}}
        {:ok, receipt} -> {:cont, {:ok, [receipt | advanced]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, advanced} -> {:ok, Enum.reverse(advanced)}
      error -> error
    end
  end

  defp advance_one(
         _result,
         %AcquisitionRun{source_cursor_id: nil, proposed_cursor: nil},
         _cursors
       ),
       do: {:ok, nil}

  defp advance_one(
         _result,
         %AcquisitionRun{start_cursor: value, proposed_cursor: value},
         _cursors
       ),
       do: {:ok, nil}

  defp advance_one(result, acquisition, cursors) do
    with %SourceCursor{} = cursor <- Map.get(cursors, acquisition.source_cursor_id),
         :ok <- exact_cursor_owner(acquisition, cursor),
         true <- cursor.value == acquisition.start_cursor,
         {:ok, advance_key} <-
           Canonical.identity("source-cursor-advancement-v1", [
             result.result_key,
             acquisition.acquisition_key,
             cursor.id,
             acquisition.start_cursor,
             acquisition.proposed_cursor
           ]),
         {:ok, advance_digest} <-
           Canonical.identity("source-cursor-advance-proof-v1", [
             acquisition.user_id,
             acquisition.agent_id,
             acquisition.connected_account_id,
             acquisition.provider,
             acquisition.cursor_kind,
             acquisition.start_cursor,
             acquisition.proposed_cursor
           ]),
         now <- DatabaseClock.now!(),
         {1, _rows} <-
           compare_and_set(cursor, acquisition.start_cursor, acquisition.proposed_cursor, now),
         prepared <- %{
           id: Ecto.UUID.generate(),
           advance_key: advance_key,
           agent_work_result_id: result.id,
           acquisition_run_id: acquisition.id,
           source_cursor_id: cursor.id,
           user_id: acquisition.user_id,
           agent_id: acquisition.agent_id,
           connected_account_id: acquisition.connected_account_id,
           provider: acquisition.provider,
           cursor_kind: acquisition.cursor_kind,
           expected_value: acquisition.start_cursor,
           advanced_value: acquisition.proposed_cursor,
           advance_digest: advance_digest,
           advanced_at: now,
           inserted_at: now
         },
         {:ok, receipt} <-
           %SourceCursorAdvancement{}
           |> SourceCursorAdvancement.changeset(prepared)
           |> Repo.insert() do
      {:ok, receipt}
    else
      nil -> {:error, {:source_cursor_not_found, acquisition.source_cursor_id}}
      false -> {:error, {:cursor_conflict, acquisition.source_cursor_id}}
      {0, _rows} -> {:error, {:cursor_conflict, acquisition.source_cursor_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compare_and_set(cursor, expected, advanced, now) do
    Repo.update_all(
      from(stored in SourceCursor,
        where: stored.id == ^cursor.id,
        where: fragment("? IS NOT DISTINCT FROM ?", stored.value, ^expected)
      ),
      set: [value: advanced, updated_at: now]
    )
  end

  defp exact_cursor_owner(acquisition, cursor) do
    if cursor.user_id == acquisition.user_id and
         cursor.connected_account_id == acquisition.connected_account_id and
         cursor.provider == acquisition.provider and
         cursor.kind == acquisition.cursor_kind and
         acquisition.proposed_cursor != nil do
      :ok
    else
      {:error, :source_cursor_owner_mismatch}
    end
  end

  defp resolve_acquisitions(changes, refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn reference, {:ok, resolved} ->
      case resolve(changes, reference, AcquisitionRun) do
        {:ok, acquisition} -> {:cont, {:ok, [acquisition | resolved]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp resolve(changes, name, schema) when is_atom(name) do
    case Map.fetch(changes, name) do
      {:ok, value} -> resolve(changes, value, schema)
      :error -> {:error, {:missing_multi_value, name}}
    end
  end

  defp resolve(_changes, %{__struct__: schema} = value, schema), do: {:ok, value}

  defp resolve(_changes, value, schema) do
    with {:ok, id} <- schema_id(value, schema),
         stored when not is_nil(stored) <- Repo.get(schema, id) do
      {:ok, stored}
    else
      nil -> {:error, :lineage_record_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp acquisition_ids(acquisitions) do
    acquisitions
    |> Enum.reduce_while({:ok, []}, fn acquisition, {:ok, ids} ->
      case schema_id(acquisition, AcquisitionRun) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} ->
        ids = Enum.sort(ids)

        if length(ids) == MapSet.size(MapSet.new(ids)),
          do: {:ok, ids},
          else: {:error, :duplicate_cursor_acquisition}

      error ->
        error
    end
  end

  defp schema_id(%schema{id: id}, schema), do: uuid(id)
  defp schema_id(id, _schema), do: uuid(id)

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end
end
