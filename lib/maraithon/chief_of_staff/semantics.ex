defmodule Maraithon.ChiefOfStaff.Semantics do
  @moduledoc """
  Feature-dark creation of immutable, deterministic semantic effects.

  Effects are accepted only from a sealed complete acquisition, and their key
  includes the sorted immutable source-envelope identities. There is no update
  or UUID fallback path for semantic identity.
  """

  import Ecto.Query

  alias Maraithon.ChiefOfStaff.AcquisitionEnvelope
  alias Maraithon.ChiefOfStaff.AcquisitionRun
  alias Maraithon.ChiefOfStaff.SemanticEffect
  alias Maraithon.ChiefOfStaff.SemanticEffectSource
  alias Maraithon.ChiefOfStaff.SourceEnvelope
  alias Maraithon.Lineage.Canonical
  alias Maraithon.Lineage.Transaction
  alias Maraithon.Repo
  alias Maraithon.Runtime.DatabaseClock

  @max_effect_sources 1_000
  @max_payload_bytes 128_000

  def put_effect(attrs, source_envelope_ids)

  def put_effect(attrs, source_envelope_ids)
      when is_map(attrs) and is_list(source_envelope_ids) and
             length(source_envelope_ids) in 1..@max_effect_sources do
    case Repo.transaction(fn ->
           case put_effect_in_transaction(attrs, source_envelope_ids) do
             {:ok, _effect, _disposition} = result -> result
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def put_effect(_attrs, _source_envelope_ids), do: {:error, :invalid_semantic_effect}

  def put_effect_in_transaction(attrs, source_envelope_ids)
      when is_map(attrs) and is_list(source_envelope_ids) and
             length(source_envelope_ids) in 1..@max_effect_sources do
    with :ok <- Transaction.require(),
         {:ok, acquisition_run_id} <- uuid(value(attrs, :acquisition_run_id)),
         %AcquisitionRun{} = acquisition <- complete_acquisition(acquisition_run_id),
         {:ok, kind} <- effect_kind(value(attrs, :kind)),
         {:ok, subject_key} <- Canonical.string(value(attrs, :subject_key), 1024),
         {:ok, contract_version} <- contract_version(value(attrs, :contract_version, 1)),
         {:ok, extractor_version} <-
           Canonical.string(value(attrs, :extractor_version), 80, allow_whitespace: false),
         {:ok, payload, _encoded_payload, payload_digest} <-
           Canonical.object(value(attrs, :payload, %{}), @max_payload_bytes,
             max_binary_bytes: 100_000,
             max_depth: 12,
             max_nodes: 20_000,
             max_map_entries: 2_000,
             max_list_items: 5_000
           ),
         {:ok, envelopes} <- exact_source_envelopes(acquisition, source_envelope_ids),
         {:ok, effect_key} <-
           effect_key(acquisition, kind, subject_key, contract_version, envelopes) do
      now = DatabaseClock.now!()

      prepared = %{
        id: Ecto.UUID.generate(),
        effect_key: effect_key,
        user_id: acquisition.user_id,
        agent_id: acquisition.agent_id,
        agent_directive_id: acquisition.agent_directive_id,
        acquisition_run_id: acquisition.id,
        kind: kind,
        subject_key: subject_key,
        contract_version: contract_version,
        extractor_version: extractor_version,
        payload: payload,
        payload_digest: payload_digest,
        inserted_at: now
      }

      insert_or_compare(prepared, envelopes, now)
    else
      nil -> {:error, :acquisition_not_complete}
      {:error, :invalid_lineage_payload} -> {:error, :invalid_semantic_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  def put_effect_in_transaction(_attrs, _source_envelope_ids) do
    with :ok <- Transaction.require(), do: {:error, :invalid_semantic_effect}
  end

  def list_sources(effect_or_id) do
    with {:ok, effect_id} <- schema_id(effect_or_id, SemanticEffect) do
      Repo.all(
        from(envelope in SourceEnvelope,
          join: source in SemanticEffectSource,
          on: source.source_envelope_id == envelope.id,
          where: source.semantic_effect_id == ^effect_id,
          order_by: [asc: envelope.envelope_key],
          select: envelope
        )
      )
    else
      _error -> []
    end
  end

  defp insert_or_compare(prepared, envelopes, now) do
    changeset = SemanticEffect.changeset(%SemanticEffect{}, prepared)

    if changeset.valid? do
      case Repo.insert_all(SemanticEffect, [prepared],
             on_conflict: :nothing,
             conflict_target: [:user_id, :effect_key],
             returning: [:id]
           ) do
        {1, _rows} ->
          effect = Repo.get!(SemanticEffect, prepared.id)

          case insert_sources(effect, envelopes, now) do
            :ok -> {:ok, effect, :inserted}
            {:error, reason} -> {:error, reason}
          end

        {0, _rows} ->
          existing =
            Repo.get_by!(SemanticEffect,
              user_id: prepared.user_id,
              effect_key: prepared.effect_key
            )

          compare_existing(existing, prepared, envelopes)
      end
    else
      {:error, changeset}
    end
  end

  defp insert_sources(effect, envelopes, now) do
    entries =
      Enum.map(envelopes, fn envelope ->
        %{
          semantic_effect_id: effect.id,
          acquisition_run_id: effect.acquisition_run_id,
          source_envelope_id: envelope.id,
          inserted_at: now
        }
      end)

    case Repo.insert_all(SemanticEffectSource, entries) do
      {count, _rows} when count == length(entries) -> :ok
      _other -> {:error, :semantic_source_insert_failed}
    end
  end

  defp compare_existing(existing, prepared, envelopes) do
    existing_source_ids =
      Repo.all(
        from(source in SemanticEffectSource,
          where: source.semantic_effect_id == ^existing.id,
          order_by: [asc: source.source_envelope_id],
          select: source.source_envelope_id
        )
      )

    requested_source_ids = envelopes |> Enum.map(& &1.id) |> Enum.sort()

    if existing.acquisition_run_id == prepared.acquisition_run_id and
         existing.kind == prepared.kind and
         existing.subject_key == prepared.subject_key and
         existing.contract_version == prepared.contract_version and
         existing.extractor_version == prepared.extractor_version and
         existing.payload_digest == prepared.payload_digest and
         existing_source_ids == requested_source_ids do
      {:ok, existing, :duplicate}
    else
      {:error, :semantic_effect_idempotency_conflict}
    end
  end

  defp complete_acquisition(id) do
    Repo.one(
      from(acquisition in AcquisitionRun,
        where: acquisition.id == ^id,
        where: acquisition.status == "complete",
        where: acquisition.pagination_exhausted == true,
        where: not is_nil(acquisition.sealed_at),
        where: not is_nil(acquisition.manifest_digest),
        lock: "FOR SHARE"
      )
    )
  end

  defp exact_source_envelopes(acquisition, ids) do
    with {:ok, ids} <- unique_uuids(ids) do
      envelopes =
        Repo.all(
          from(envelope in SourceEnvelope,
            join: association in AcquisitionEnvelope,
            on: association.source_envelope_id == envelope.id,
            where: association.acquisition_run_id == ^acquisition.id,
            where: envelope.id in ^ids,
            order_by: [asc: envelope.envelope_key],
            select: envelope
          )
        )

      if length(envelopes) == length(ids),
        do: {:ok, envelopes},
        else: {:error, :semantic_source_not_in_acquisition}
    end
  end

  defp effect_key(acquisition, kind, subject_key, contract_version, envelopes) do
    source_keys = Enum.map(envelopes, & &1.envelope_key)

    Canonical.identity(
      "chief-semantic-effect-v1",
      [
        acquisition.user_id,
        acquisition.agent_id,
        contract_version,
        kind,
        subject_key,
        length(source_keys)
      ] ++ source_keys
    )
  end

  defp unique_uuids(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, cast} ->
      case uuid(value) do
        {:ok, id} -> {:cont, {:ok, [id | cast]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} ->
        ids = Enum.sort(ids)

        if length(ids) == MapSet.size(MapSet.new(ids)),
          do: {:ok, ids},
          else: {:error, :duplicate_semantic_source}

      error ->
        error
    end
  end

  defp effect_kind(value) when is_atom(value), do: effect_kind(Atom.to_string(value))

  defp effect_kind(value) when is_binary(value) do
    if value in SemanticEffect.kinds(),
      do: {:ok, value},
      else: {:error, :invalid_effect_kind}
  end

  defp effect_kind(_value), do: {:error, :invalid_effect_kind}

  defp contract_version(value) when is_integer(value) and value in 1..100, do: {:ok, value}
  defp contract_version(_value), do: {:error, :invalid_contract_version}

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
