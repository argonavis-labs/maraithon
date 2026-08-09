defmodule Maraithon.Runtime.AgentWorkResults do
  @moduledoc """
  Feature-dark primitives for an exact terminal Agent work-result transaction.

  A provisional row is intentionally forbidden from surviving commit by a
  deferred database constraint. Callers must use these functions inside the
  future single terminal transaction, link at least one sealed acquisition,
  write all projection/cursor receipts, terminalize the exact Directive and
  AgentRun, then call `finalize_in_transaction/1`.

  No inverse nullable columns are added to AgentRun, Directive, or Snapshot in
  this slice; the future terminal coordinator will wire those models atomically.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Maraithon.Agents.AgentRun
  alias Maraithon.ChiefOfStaff.AcquisitionRun
  alias Maraithon.Lineage.Canonical
  alias Maraithon.Lineage.Transaction
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentWorkResult
  alias Maraithon.Runtime.AgentWorkResultAcquisition
  alias Maraithon.Runtime.DatabaseClock

  @max_result_bytes 128_000
  @max_acquisitions 100

  def provisional_multi(%Multi{} = multi, name, attrs, acquisition_refs)
      when is_map(attrs) and is_list(acquisition_refs) do
    Multi.run(multi, name, fn _repo, changes ->
      with {:ok, acquisitions} <- resolve_acquisitions(changes, acquisition_refs) do
        insert_provisional_in_transaction(attrs, acquisitions)
      end
    end)
  end

  def finalize_multi(%Multi{} = multi, name, result_ref) do
    Multi.run(multi, name, fn _repo, changes ->
      with {:ok, result} <- resolve(changes, result_ref, AgentWorkResult) do
        finalize_in_transaction(result)
      end
    end)
  end

  def insert_provisional_in_transaction(attrs, acquisitions)

  def insert_provisional_in_transaction(attrs, acquisitions)
      when is_map(attrs) and is_list(acquisitions) and
             length(acquisitions) in 1..@max_acquisitions do
    with :ok <- Transaction.require(),
         {:ok, proof} <- exact_proof(attrs),
         :ok <- AgentLeases.fence_owner!(proof.agent_id, proof.claim_generation),
         %AgentDirective{} = directive <- lock_exact_active_directive(proof),
         %AgentRun{} = run <- lock_exact_active_run(proof),
         {:ok, acquisitions} <- exact_acquisitions(proof, acquisitions),
         {:ok, outcome} <- outcome(value(attrs, :outcome)),
         {:ok, terminal_event} <-
           Canonical.string(value(attrs, :terminal_event), 80, allow_whitespace: false),
         true <- Regex.match?(~r/^[a-z0-9_]+$/, terminal_event),
         {:ok, result, _encoded, result_digest} <-
           Canonical.object(value(attrs, :result, %{}), @max_result_bytes,
             max_binary_bytes: 100_000,
             max_depth: 12,
             max_nodes: 20_000,
             max_map_entries: 2_000,
             max_list_items: 5_000
           ),
         {:ok, result_key} <- result_key(directive, acquisitions, outcome, terminal_event) do
      now = DatabaseClock.now!()

      prepared = %{
        result_key: result_key,
        agent_directive_id: directive.id,
        agent_id: directive.agent_id,
        user_id: directive.user_id,
        agent_run_id: run.id,
        claim_generation: proof.claim_generation,
        claim_token: proof.claim_token,
        status: "provisional",
        outcome: outcome,
        terminal_event: terminal_event,
        result: result,
        result_digest: result_digest,
        provisional_at: now,
        committed_at: nil,
        inserted_at: now,
        updated_at: now
      }

      with {:ok, work_result} <-
             %AgentWorkResult{}
             |> AgentWorkResult.changeset(prepared)
             |> Repo.insert(),
           :ok <- insert_acquisition_links(work_result, acquisitions, now) do
        {:ok, work_result}
      end
    else
      nil -> {:error, :terminal_proof_not_found}
      false -> {:error, :invalid_terminal_event}
      {:error, :invalid_lineage_payload} -> {:error, :invalid_work_result_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  def insert_provisional_in_transaction(_attrs, _acquisitions) do
    with :ok <- Transaction.require(), do: {:error, :invalid_agent_work_result}
  end

  def finalize_in_transaction(result_or_id) do
    with :ok <- Transaction.require(),
         {:ok, result_id} <- schema_id(result_or_id, AgentWorkResult),
         %AgentWorkResult{status: "provisional"} = result <-
           Repo.one(
             from(result in AgentWorkResult,
               where: result.id == ^result_id,
               lock: "FOR UPDATE"
             )
           ) do
      now = DatabaseClock.now!()

      case result
           |> AgentWorkResult.changeset(%{
             status: "committed",
             committed_at: now,
             updated_at: now
           })
           |> Repo.update() do
        {:ok, committed} -> {:ok, committed}
        {:error, changeset} -> {:error, changeset}
      end
    else
      nil -> {:error, :work_result_not_found}
      %AgentWorkResult{} -> {:error, :work_result_not_provisional}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_for_directive(directive_id) do
    case uuid(directive_id) do
      {:ok, id} -> Repo.get_by(AgentWorkResult, agent_directive_id: id)
      _error -> nil
    end
  end

  defp exact_proof(attrs) do
    with {:ok, agent_directive_id} <- uuid(value(attrs, :agent_directive_id)),
         {:ok, agent_id} <- uuid(value(attrs, :agent_id)),
         {:ok, user_id} <-
           Canonical.string(value(attrs, :user_id), 320, allow_whitespace: false),
         {:ok, agent_run_id} <- uuid(value(attrs, :agent_run_id)),
         {:ok, claim_generation} <- uuid(value(attrs, :claim_generation)),
         {:ok, claim_token} <- uuid(value(attrs, :claim_token)) do
      {:ok,
       %{
         agent_directive_id: agent_directive_id,
         agent_id: agent_id,
         user_id: user_id,
         agent_run_id: agent_run_id,
         claim_generation: claim_generation,
         claim_token: claim_token
       }}
    else
      _error -> {:error, :invalid_terminal_proof}
    end
  end

  defp lock_exact_active_directive(proof) do
    now = DatabaseClock.now!()

    Repo.one(
      from(directive in AgentDirective,
        where: directive.id == ^proof.agent_directive_id,
        where: directive.agent_id == ^proof.agent_id,
        where: directive.user_id == ^proof.user_id,
        where: directive.status == "processing",
        where: directive.claimed_by_generation == ^proof.claim_generation,
        where: directive.claim_token == ^proof.claim_token,
        where: directive.claim_expires_at > ^now,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_exact_active_run(proof) do
    Repo.one(
      from(run in AgentRun,
        where: run.id == ^proof.agent_run_id,
        where: run.agent_id == ^proof.agent_id,
        where: run.user_id == ^proof.user_id,
        where: run.status == "running",
        lock: "FOR UPDATE"
      )
    )
  end

  defp exact_acquisitions(proof, acquisitions) do
    with {:ok, ids} <- acquisition_ids(acquisitions) do
      stored =
        Repo.all(
          from(acquisition in AcquisitionRun,
            where: acquisition.id in ^ids,
            where: acquisition.agent_id == ^proof.agent_id,
            where: acquisition.user_id == ^proof.user_id,
            where: acquisition.agent_directive_id == ^proof.agent_directive_id,
            where: acquisition.status == "complete",
            where: acquisition.pagination_exhausted == true,
            where: not is_nil(acquisition.sealed_at),
            where: not is_nil(acquisition.manifest_digest),
            order_by: [asc: acquisition.id],
            lock: "FOR UPDATE"
          )
        )

      if length(stored) == length(ids),
        do: {:ok, stored},
        else: {:error, :acquisition_proof_incomplete}
    end
  end

  defp insert_acquisition_links(work_result, acquisitions, now) do
    entries =
      Enum.map(acquisitions, fn acquisition ->
        %{
          agent_work_result_id: work_result.id,
          acquisition_run_id: acquisition.id,
          user_id: work_result.user_id,
          agent_id: work_result.agent_id,
          inserted_at: now
        }
      end)

    case Repo.insert_all(AgentWorkResultAcquisition, entries) do
      {count, _rows} when count == length(entries) -> :ok
      _other -> {:error, :acquisition_proof_insert_failed}
    end
  end

  defp result_key(directive, acquisitions, outcome, terminal_event) do
    acquisition_keys =
      acquisitions
      |> Enum.sort_by(& &1.acquisition_key)
      |> Enum.map(& &1.acquisition_key)

    Canonical.identity(
      "agent-work-result-v1",
      [
        directive.user_id,
        directive.agent_id,
        directive.dedupe_key,
        outcome,
        terminal_event,
        length(acquisition_keys)
      ] ++ acquisition_keys
    )
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
          else: {:error, :duplicate_acquisition_proof}

      error ->
        error
    end
  end

  defp outcome(value) when is_atom(value), do: outcome(Atom.to_string(value))

  defp outcome(value) when is_binary(value) do
    if value in AgentWorkResult.outcomes(),
      do: {:ok, value},
      else: {:error, :invalid_work_result_outcome}
  end

  defp outcome(_value), do: {:error, :invalid_work_result_outcome}

  defp schema_id(%schema{id: id}, schema), do: uuid(id)
  defp schema_id(id, _schema), do: uuid(id)

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
