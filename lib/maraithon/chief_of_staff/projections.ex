defmodule Maraithon.ChiefOfStaff.Projections do
  @moduledoc """
  Feature-dark Multi builders for immutable Todo/Decision projection proof.

  These helpers never create or mutate Todos and never call SurfaceQuality.
  A future terminal coordinator must persist an already-quality-gated Todo or
  deterministic Chief decision, then add its receipt in the same transaction
  as the provisional work result and cursor compare-and-set.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Maraithon.ChiefOfStaff.Decision
  alias Maraithon.ChiefOfStaff.ProjectionReceipt
  alias Maraithon.ChiefOfStaff.SemanticEffect
  alias Maraithon.Lineage.Canonical
  alias Maraithon.Lineage.Transaction
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentWorkResult
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Todos.Todo

  @max_payload_bytes 128_000
  @max_attrs_bytes 64_000

  def put_decision(effect_or_id, attrs) when is_map(attrs) do
    case Repo.transaction(fn ->
           case put_decision_in_transaction(effect_or_id, attrs) do
             {:ok, _decision, _disposition} = result -> result
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def put_decision(_effect_or_id, _attrs), do: {:error, :invalid_chief_decision}

  def put_decision_multi(%Multi{} = multi, name, effect_ref, attrs) when is_map(attrs) do
    Multi.run(multi, name, fn _repo, changes ->
      with {:ok, effect} <- resolve(changes, effect_ref, SemanticEffect) do
        put_decision_in_transaction(effect, attrs)
      end
    end)
  end

  def put_decision_in_transaction(effect_or_id, attrs) when is_map(attrs) do
    with :ok <- Transaction.require(),
         {:ok, effect_id} <- schema_id(effect_or_id, SemanticEffect),
         %SemanticEffect{kind: "decision"} = effect <- Repo.get(SemanticEffect, effect_id),
         {:ok, identity} <- Canonical.string(value(attrs, :decision_identity), 512),
         {:ok, kind} <- decision_kind(value(attrs, :kind)),
         {:ok, payload, _encoded, payload_digest} <-
           Canonical.object(value(attrs, :payload, %{}), @max_payload_bytes,
             max_binary_bytes: 100_000,
             max_depth: 12,
             max_nodes: 20_000,
             max_map_entries: 2_000,
             max_list_items: 5_000
           ),
         {:ok, decision_key} <-
           Canonical.identity("chief-decision-v1", [effect.effect_key, identity]) do
      now = DatabaseClock.now!()

      prepared = %{
        id: Ecto.UUID.generate(),
        decision_key: decision_key,
        decision_identity: identity,
        user_id: effect.user_id,
        agent_id: effect.agent_id,
        semantic_effect_id: effect.id,
        kind: kind,
        payload: payload,
        payload_digest: payload_digest,
        inserted_at: now
      }

      insert_or_compare_decision(prepared)
    else
      nil -> {:error, :semantic_effect_not_found}
      %SemanticEffect{} -> {:error, :decision_requires_decision_effect}
      {:error, :invalid_lineage_payload} -> {:error, :invalid_decision_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  def put_decision_in_transaction(_effect_or_id, _attrs) do
    with :ok <- Transaction.require(), do: {:error, :invalid_chief_decision}
  end

  def receipt_multi(%Multi{} = multi, name, work_result_ref, effect_ref, target_ref, attrs)
      when is_map(attrs) do
    Multi.run(multi, name, fn _repo, changes ->
      with {:ok, result} <- resolve(changes, work_result_ref, AgentWorkResult),
           {:ok, effect} <- resolve(changes, effect_ref, SemanticEffect),
           {:ok, target} <- resolve_target(changes, target_ref) do
        record_receipt_in_transaction(result, effect, target, attrs)
      end
    end)
  end

  def record_receipt_in_transaction(work_result_or_id, effect_or_id, target, attrs)
      when is_map(attrs) do
    with :ok <- Transaction.require(),
         {:ok, result_id} <- schema_id(work_result_or_id, AgentWorkResult),
         {:ok, effect_id} <- schema_id(effect_or_id, SemanticEffect),
         %AgentWorkResult{status: "provisional"} = result <-
           Repo.get(AgentWorkResult, result_id),
         %SemanticEffect{} = effect <- Repo.get(SemanticEffect, effect_id),
         :ok <- same_owner(result, effect),
         {:ok, target_fields} <- exact_target(result, effect, target),
         {:ok, _attrs, _encoded, attrs_digest} <-
           Canonical.object(attrs, @max_attrs_bytes,
             max_binary_bytes: 32_000,
             max_depth: 10,
             max_nodes: 10_000,
             max_map_entries: 1_000,
             max_list_items: 2_000
           ),
         {:ok, receipt_key} <-
           Canonical.identity("chief-projection-receipt-v1", [
             effect.effect_key,
             target_fields.projection_kind,
             target_fields.projection_key
           ]) do
      now = DatabaseClock.now!()

      prepared =
        target_fields
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          receipt_key: receipt_key,
          agent_work_result_id: result.id,
          semantic_effect_id: effect.id,
          user_id: result.user_id,
          agent_id: result.agent_id,
          attrs_digest: attrs_digest,
          projected_at: now,
          inserted_at: now
        })

      insert_or_compare_receipt(prepared)
    else
      nil -> {:error, :projection_lineage_not_found}
      %AgentWorkResult{} -> {:error, :work_result_not_provisional}
      {:error, :invalid_lineage_payload} -> {:error, :invalid_projection_attrs}
      {:error, reason} -> {:error, reason}
    end
  end

  def record_receipt_in_transaction(_work_result, _effect, _target, _attrs) do
    with :ok <- Transaction.require(), do: {:error, :invalid_projection_receipt}
  end

  defp insert_or_compare_decision(prepared) do
    changeset = Decision.changeset(%Decision{}, prepared)

    if changeset.valid? do
      case Repo.insert_all(Decision, [prepared],
             on_conflict: :nothing,
             conflict_target: [:semantic_effect_id],
             returning: [:id]
           ) do
        {1, _rows} ->
          {:ok, Repo.get!(Decision, prepared.id), :inserted}

        {0, _rows} ->
          existing = Repo.get_by!(Decision, semantic_effect_id: prepared.semantic_effect_id)

          if existing.decision_key == prepared.decision_key and
               existing.decision_identity == prepared.decision_identity and
               existing.kind == prepared.kind and
               existing.payload_digest == prepared.payload_digest,
             do: {:ok, existing, :duplicate},
             else: {:error, :decision_idempotency_conflict}
      end
    else
      {:error, changeset}
    end
  end

  defp insert_or_compare_receipt(prepared) do
    changeset = ProjectionReceipt.changeset(%ProjectionReceipt{}, prepared)

    if changeset.valid? do
      case Repo.insert_all(ProjectionReceipt, [prepared],
             on_conflict: :nothing,
             conflict_target: [:semantic_effect_id, :projection_kind, :projection_key],
             returning: [:id]
           ) do
        {1, _rows} ->
          {:ok, Repo.get!(ProjectionReceipt, prepared.id), :inserted}

        {0, _rows} ->
          existing =
            Repo.get_by!(ProjectionReceipt,
              semantic_effect_id: prepared.semantic_effect_id,
              projection_kind: prepared.projection_kind,
              projection_key: prepared.projection_key
            )

          if existing.receipt_key == prepared.receipt_key and
               existing.agent_work_result_id == prepared.agent_work_result_id and
               existing.todo_id == prepared.todo_id and
               existing.decision_id == prepared.decision_id and
               existing.attrs_digest == prepared.attrs_digest,
             do: {:ok, existing, :duplicate},
             else: {:error, :projection_idempotency_conflict}
      end
    else
      {:error, changeset}
    end
  end

  defp exact_target(result, %SemanticEffect{kind: "todo"}, {:todo, target}) do
    with {:ok, todo_id} <- schema_id(target, Todo),
         %Todo{} = todo <-
           Repo.one(
             from(todo in Todo,
               where: todo.id == ^todo_id,
               where: todo.user_id == ^result.user_id,
               lock: "FOR SHARE"
             )
           ),
         {:ok, projection_key} <- Canonical.string(todo.dedupe_key, 512) do
      {:ok,
       %{
         projection_kind: "todo",
         projection_key: projection_key,
         todo_id: todo.id,
         decision_id: nil
       }}
    else
      nil -> {:error, :todo_owner_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_target(result, %SemanticEffect{kind: "decision"} = effect, {:decision, target}) do
    with {:ok, decision_id} <- schema_id(target, Decision),
         %Decision{} = decision <-
           Repo.one(
             from(decision in Decision,
               where: decision.id == ^decision_id,
               where: decision.user_id == ^result.user_id,
               where: decision.agent_id == ^result.agent_id,
               where: decision.semantic_effect_id == ^effect.id,
               lock: "FOR SHARE"
             )
           ) do
      projection_key = "chief:decision:" <> Base.encode16(decision.decision_key, case: :lower)

      {:ok,
       %{
         projection_kind: "decision",
         projection_key: projection_key,
         todo_id: nil,
         decision_id: decision.id
       }}
    else
      nil -> {:error, :decision_owner_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_target(_result, _effect, _target), do: {:error, :projection_kind_mismatch}

  defp same_owner(result, effect) do
    if result.agent_id == effect.agent_id and result.user_id == effect.user_id,
      do: :ok,
      else: {:error, :projection_owner_mismatch}
  end

  defp resolve(changes, name, schema) when is_atom(name) do
    case Map.fetch(changes, name) do
      {:ok, value} -> resolve(changes, value, schema)
      :error -> {:error, {:missing_multi_value, name}}
    end
  end

  defp resolve(_changes, %schema{} = value, schema), do: {:ok, value}

  defp resolve(_changes, value, schema) do
    with {:ok, id} <- schema_id(value, schema),
         %^schema{} = stored <- Repo.get(schema, id) do
      {:ok, stored}
    else
      nil -> {:error, :lineage_record_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_target(changes, {kind, reference}) when kind in [:todo, :decision] do
    schema = if kind == :todo, do: Todo, else: Decision

    case resolve(changes, reference, schema) do
      {:ok, target} -> {:ok, {kind, target}}
      error -> error
    end
  end

  defp resolve_target(_changes, _target), do: {:error, :invalid_projection_target}

  defp decision_kind(value) when is_atom(value), do: decision_kind(Atom.to_string(value))

  defp decision_kind(value) when is_binary(value) do
    if value in Decision.kinds(),
      do: {:ok, value},
      else: {:error, :invalid_decision_kind}
  end

  defp decision_kind(_value), do: {:error, :invalid_decision_kind}

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
