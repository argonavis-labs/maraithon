defmodule Maraithon.ChiefOfStaff.AcquisitionStore do
  @moduledoc """
  Feature-dark store for bounded Chief acquisition pages and immutable provider revisions.

  Sealing computes completeness from persisted pages and envelope associations.
  It never changes `source_cursors`; incomplete acquisitions cannot be read by
  the semantic context.
  """

  import Ecto.Query

  alias Maraithon.ChiefOfStaff.AcquisitionEnvelope
  alias Maraithon.ChiefOfStaff.AcquisitionPage
  alias Maraithon.ChiefOfStaff.AcquisitionRun
  alias Maraithon.ChiefOfStaff.SourceEnvelope
  alias Maraithon.Connectors.SourceCursor
  alias Maraithon.Lineage.Canonical
  alias Maraithon.Lineage.Transaction
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.IngressReceipt

  @max_page_items 5_000
  @max_raw_bytes 256_000
  @max_normalized_bytes 128_000
  @max_provenance_bytes 12_000
  @max_continuation_bytes 12_000

  def begin_run(attrs) when is_map(attrs) do
    transact(fn -> begin_run_in_transaction(attrs) end)
  end

  def begin_run(_attrs), do: {:error, :invalid_acquisition}

  def begin_run_in_transaction(attrs) when is_map(attrs) do
    with :ok <- Transaction.require(),
         {:ok, identity} <- acquisition_identity(attrs),
         {:ok, directive} <- exact_directive(identity),
         {:ok, receipt} <- exact_receipt(identity),
         identity <- Map.put(identity, :provider_account_key, receipt.provider_account_key),
         {:ok, cursor} <- exact_cursor(identity),
         {:ok, start_cursor} <- start_cursor(cursor),
         {:ok, request_fingerprint} <-
           acquisition_fingerprint(identity, directive, receipt, start_cursor),
         {:ok, acquisition_key} <-
           Canonical.identity("chief-acquisition-v1", [
             receipt.receipt_key,
             directive.dedupe_key,
             identity.request_key,
             identity.provider_account_key,
             identity.source,
             identity.scope_key,
             identity.contract_version
           ]) do
      now = DatabaseClock.now!()

      prepared =
        identity
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          acquisition_key: acquisition_key,
          request_fingerprint: request_fingerprint,
          start_cursor: start_cursor,
          status: "fetching",
          continuation: nil,
          pagination_exhausted: false,
          page_count: 0,
          item_count: 0,
          started_at: now,
          inserted_at: now,
          updated_at: now
        })

      case insert_run(prepared) do
        {:ok, run, disposition} -> {:ok, run, disposition}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def begin_run_in_transaction(_attrs) do
    with :ok <- Transaction.require(), do: {:error, :invalid_acquisition}
  end

  def record_page(run_or_id, page_attrs, envelope_attrs)

  def record_page(run_or_id, page_attrs, envelope_attrs)
      when is_map(page_attrs) and is_list(envelope_attrs) and
             length(envelope_attrs) <= @max_page_items do
    transact(fn -> record_page_in_transaction(run_or_id, page_attrs, envelope_attrs) end)
  end

  def record_page(_run_or_id, _page_attrs, _envelope_attrs),
    do: {:error, :invalid_acquisition_page}

  def record_page_in_transaction(run_or_id, page_attrs, envelope_attrs)
      when is_map(page_attrs) and is_list(envelope_attrs) and
             length(envelope_attrs) <= @max_page_items do
    with :ok <- Transaction.require() do
      with_savepoint(fn ->
        with {:ok, run_id} <- schema_id(run_or_id, AcquisitionRun),
             %AcquisitionRun{} = run <- lock_run(run_id),
             :ok <- fetching(run),
             {:ok, page_identity} <- page_identity(run, page_attrs, envelope_attrs),
             {:ok, prepared_envelopes} <- prepare_envelopes(run, envelope_attrs) do
          case page_by_ordinal(run.id, page_identity.ordinal) do
            nil ->
              with :ok <- pagination_open(run) do
                insert_page(run, page_identity, prepared_envelopes)
              end

            page ->
              compare_page(page, page_identity, prepared_envelopes)
          end
        else
          nil -> {:error, :acquisition_not_found}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  def record_page_in_transaction(_run_or_id, _page_attrs, _envelope_attrs) do
    with :ok <- Transaction.require(), do: {:error, :invalid_acquisition_page}
  end

  def mark_incomplete(run_or_id, failure_code, continuation) do
    transact(fn -> mark_incomplete_in_transaction(run_or_id, failure_code, continuation) end)
  end

  def mark_incomplete_in_transaction(run_or_id, failure_code, continuation) do
    with :ok <- Transaction.require(),
         {:ok, run_id} <- schema_id(run_or_id, AcquisitionRun),
         %AcquisitionRun{} = run <- lock_run(run_id),
         :ok <- fetching(run),
         :ok <- pagination_open(run),
         {:ok, failure_code} <- failure_code(failure_code),
         {:ok, continuation, encoded, _digest} <-
           Canonical.object(continuation, @max_continuation_bytes,
             max_binary_bytes: 4_096,
             max_depth: 6,
             max_nodes: 1_000,
             max_map_entries: 100,
             max_list_items: 100
           ),
         true <- map_size(continuation) > 0,
         {:ok, manifest_digest} <- manifest_digest(run, [failure_code, encoded]) do
      now = DatabaseClock.now!()

      update_run(run, %{
        status: "incomplete",
        proposed_cursor: nil,
        continuation: continuation,
        pagination_exhausted: false,
        failure_code: failure_code,
        manifest_digest: manifest_digest,
        sealed_at: now,
        updated_at: now
      })
    else
      nil -> {:error, :acquisition_not_found}
      false -> {:error, :invalid_continuation}
      {:error, :invalid_lineage_payload} -> {:error, :invalid_continuation}
      {:error, reason} -> {:error, reason}
    end
  end

  def seal_complete(run_or_id, proposed_cursor) do
    transact(fn -> seal_complete_in_transaction(run_or_id, proposed_cursor) end)
  end

  def seal_complete_in_transaction(run_or_id, proposed_cursor) do
    with :ok <- Transaction.require(),
         {:ok, run_id} <- schema_id(run_or_id, AcquisitionRun),
         %AcquisitionRun{} = run <- lock_run(run_id),
         :ok <- fetching(run),
         {:ok, proposed_cursor} <- proposed_cursor(run, proposed_cursor),
         :ok <- complete_page_proof(run),
         {:ok, manifest_digest} <- manifest_digest(run, [proposed_cursor]) do
      now = DatabaseClock.now!()

      update_run(run, %{
        status: "complete",
        proposed_cursor: proposed_cursor,
        continuation: nil,
        pagination_exhausted: true,
        failure_code: nil,
        manifest_digest: manifest_digest,
        sealed_at: now,
        updated_at: now
      })
    else
      nil -> {:error, :acquisition_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_complete(id) do
    case schema_id(id, AcquisitionRun) do
      {:ok, run_id} ->
        Repo.one(
          from(run in AcquisitionRun,
            where: run.id == ^run_id,
            where: run.status == "complete",
            where: run.pagination_exhausted == true,
            where: not is_nil(run.sealed_at) and not is_nil(run.manifest_digest)
          )
        )

      _error ->
        nil
    end
  end

  def list_complete_envelopes(run_or_id) do
    case schema_id(run_or_id, AcquisitionRun) do
      {:ok, run_id} ->
        if get_complete(run_id) do
          Repo.all(
            from(envelope in SourceEnvelope,
              join: association in AcquisitionEnvelope,
              on: association.source_envelope_id == envelope.id,
              join: page in AcquisitionPage,
              on: page.id == association.acquisition_page_id,
              where: association.acquisition_run_id == ^run_id,
              order_by: [asc: page.ordinal, asc: association.item_ordinal],
              select: envelope
            )
          )
        else
          {:error, :acquisition_not_complete}
        end

      _error ->
        {:error, :acquisition_not_found}
    end
  end

  def list_incomplete(limit \\ 100)

  def list_incomplete(limit) when is_integer(limit) and limit in 1..500 do
    Repo.all(
      from(run in AcquisitionRun,
        where: run.status == "incomplete",
        order_by: [asc: run.updated_at, asc: run.id],
        limit: ^limit
      )
    )
  end

  def list_incomplete(_limit), do: []

  defp insert_page(run, page_identity, prepared_envelopes) do
    if page_identity.ordinal != run.page_count do
      {:error, :noncontiguous_acquisition_page}
    else
      with :ok <- expected_request_cursor(run, page_identity),
           now <- DatabaseClock.now!(),
           page_attrs <-
             Map.merge(page_identity, %{
               id: Ecto.UUID.generate(),
               acquisition_run_id: run.id,
               item_count: length(prepared_envelopes),
               fetched_at: now,
               inserted_at: now
             }),
           {:ok, page} <- insert_page_row(page_attrs),
           {:ok, envelopes} <- insert_envelopes(run, page, prepared_envelopes, now),
           {:ok, _run} <- advance_page_counts(run, page, now) do
        {:ok, page, envelopes, :inserted}
      end
    end
  end

  defp insert_page_row(attrs) do
    case %AcquisitionPage{} |> AcquisitionPage.changeset(attrs) |> Repo.insert() do
      {:ok, page} -> {:ok, page}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp insert_envelopes(run, page, prepared_envelopes, now) do
    prepared_envelopes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {prepared, ordinal}, {:ok, inserted} ->
      with {:ok, envelope} <- insert_or_compare_envelope(prepared),
           {:ok, provenance, _encoded, _digest} <-
             Canonical.object(prepared.provenance, @max_provenance_bytes,
               max_binary_bytes: 4_096,
               max_depth: 6,
               max_nodes: 1_000,
               max_map_entries: 100,
               max_list_items: 100
             ),
           link_attrs <- %{
             acquisition_run_id: run.id,
             source_envelope_id: envelope.id,
             acquisition_page_id: page.id,
             user_id: run.user_id,
             connected_account_id: run.connected_account_id,
             provider: run.provider,
             provider_account_key: run.provider_account_key,
             item_ordinal: ordinal,
             provenance: provenance,
             inserted_at: now
           },
           {:ok, _link} <-
             %AcquisitionEnvelope{}
             |> AcquisitionEnvelope.changeset(link_attrs)
             |> Repo.insert() do
        {:cont, {:ok, [envelope | inserted]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, inserted} -> {:ok, Enum.reverse(inserted)}
      error -> error
    end
  end

  defp insert_or_compare_envelope(prepared) do
    case Repo.insert_all(SourceEnvelope, [Map.delete(prepared, :provenance)],
           on_conflict: :nothing,
           conflict_target: [:envelope_key],
           returning: [:id]
         ) do
      {1, _rows} ->
        {:ok, Repo.get!(SourceEnvelope, prepared.id)}

      {0, _rows} ->
        existing = Repo.get_by!(SourceEnvelope, envelope_key: prepared.envelope_key)

        if envelope_same?(existing, prepared),
          do: {:ok, existing},
          else: {:error, :source_envelope_idempotency_conflict}
    end
  end

  defp envelope_same?(existing, prepared) do
    existing.envelope_key == prepared.envelope_key and
      existing.user_id == prepared.user_id and
      existing.connected_account_id == prepared.connected_account_id and
      existing.provider == prepared.provider and
      existing.provider_account_key == prepared.provider_account_key and
      existing.source == prepared.source and
      existing.scope_key == prepared.scope_key and
      existing.source_item_key == prepared.source_item_key and
      existing.source_revision_key == prepared.source_revision_key and
      existing.raw_payload == prepared.raw_payload and
      existing.normalized_payload == prepared.normalized_payload and
      existing.raw_digest == prepared.raw_digest and
      existing.normalized_digest == prepared.normalized_digest and
      existing.occurred_at == prepared.occurred_at
  end

  defp advance_page_counts(run, page, now) do
    continuation =
      if page.terminal,
        do: nil,
        else: %{"next_cursor" => page.next_cursor}

    update_run(run, %{
      page_count: run.page_count + 1,
      item_count: run.item_count + page.item_count,
      continuation: continuation,
      pagination_exhausted: page.terminal,
      updated_at: now
    })
  end

  defp compare_page(page, page_identity, prepared_envelopes) do
    associated =
      Repo.all(
        from(association in AcquisitionEnvelope,
          join: envelope in SourceEnvelope,
          on: envelope.id == association.source_envelope_id,
          where: association.acquisition_page_id == ^page.id,
          order_by: [asc: association.item_ordinal],
          select: {association, envelope}
        )
      )

    same_links? =
      length(associated) == length(prepared_envelopes) and
        associated
        |> Enum.zip(prepared_envelopes)
        |> Enum.with_index()
        |> Enum.all?(fn {{{association, existing}, prepared}, ordinal} ->
          association.acquisition_run_id == page.acquisition_run_id and
            association.acquisition_page_id == page.id and
            association.source_envelope_id == existing.id and
            association.user_id == prepared.user_id and
            association.connected_account_id == prepared.connected_account_id and
            association.provider == prepared.provider and
            association.provider_account_key == prepared.provider_account_key and
            association.item_ordinal == ordinal and
            association.provenance == prepared.provenance and
            envelope_same?(existing, prepared)
        end)

    envelopes = Enum.map(associated, &elem(&1, 1))
    expected_keys = Enum.map(prepared_envelopes, & &1.envelope_key)

    if page.item_count == length(prepared_envelopes) and
         page.request_cursor == page_identity.request_cursor and
         page.next_cursor == page_identity.next_cursor and
         page.terminal == page_identity.terminal and
         page.request_fingerprint == page_identity.request_fingerprint and
         page.response_digest == page_identity.response_digest and
         Enum.map(envelopes, & &1.envelope_key) == expected_keys and same_links? do
      {:ok, page, envelopes, :duplicate}
    else
      {:error, :acquisition_page_idempotency_conflict}
    end
  end

  defp page_identity(run, attrs, envelopes) do
    with {:ok, ordinal} <- nonnegative_integer(value(attrs, :ordinal)),
         {:ok, request_cursor} <- optional_cursor(value(attrs, :request_cursor)),
         {:ok, next_cursor} <- optional_cursor(value(attrs, :next_cursor)),
         {:ok, terminal} <- boolean(value(attrs, :terminal)),
         :ok <- terminal_cursor(terminal, next_cursor),
         {:ok, _request, _encoded_request, request_fingerprint} <-
           Canonical.object(value(attrs, :request, %{}), 32_000,
             max_binary_bytes: 16_000,
             max_depth: 8,
             max_nodes: 5_000,
             max_map_entries: 500,
             max_list_items: 1_000
           ),
         {:ok, _response, encoded_response, _response_payload_digest} <-
           Canonical.object(value(attrs, :response_proof, %{}), 32_000,
             max_binary_bytes: 16_000,
             max_depth: 8,
             max_nodes: 5_000,
             max_map_entries: 500,
             max_list_items: 1_000
           ),
         {:ok, response_digest} <-
           Canonical.identity("chief-acquisition-page-response-v1", [
             run.acquisition_key,
             ordinal,
             encoded_response,
             length(envelopes)
           ]) do
      page = %{
        ordinal: ordinal,
        request_cursor: request_cursor,
        next_cursor: next_cursor,
        terminal: terminal,
        request_fingerprint: request_fingerprint,
        response_digest: response_digest
      }

      {:ok, page}
    end
  end

  defp prepare_envelopes(run, attrs) do
    attrs
    |> Enum.reduce_while({:ok, []}, fn envelope_attrs, {:ok, prepared} ->
      case prepare_envelope(run, envelope_attrs) do
        {:ok, envelope} -> {:cont, {:ok, [envelope | prepared]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, prepared} ->
        prepared = Enum.reverse(prepared)

        if unique_envelope_keys?(prepared),
          do: {:ok, prepared},
          else: {:error, :duplicate_source_envelope_in_page}

      error ->
        error
    end
  end

  defp prepare_envelope(run, attrs) when is_map(attrs) do
    with {:ok, source_item_key} <-
           Canonical.string(value(attrs, :source_item_key), 512),
         {:ok, source_revision_key} <-
           Canonical.string(value(attrs, :source_revision_key), 255),
         {:ok, raw_payload, _raw_encoded, raw_digest} <-
           Canonical.object(value(attrs, :raw_payload, %{}), @max_raw_bytes,
             max_binary_bytes: 200_000,
             max_depth: 16,
             max_nodes: 30_000,
             max_map_entries: 4_000,
             max_list_items: 10_000
           ),
         {:ok, normalized_payload, _normalized_encoded, normalized_digest} <-
           Canonical.object(value(attrs, :normalized_payload, %{}), @max_normalized_bytes,
             max_binary_bytes: 100_000,
             max_depth: 12,
             max_nodes: 20_000,
             max_map_entries: 2_000,
             max_list_items: 5_000
           ),
         {:ok, envelope_key} <-
           Canonical.identity("chief-source-envelope-v1", [
             run.user_id,
             run.connected_account_id,
             run.provider,
             run.provider_account_key,
             run.source,
             run.scope_key,
             source_item_key,
             source_revision_key
           ]),
         {:ok, occurred_at} <- optional_datetime(value(attrs, :occurred_at)),
         {:ok, provenance} <- provenance(value(attrs, :provenance, %{})) do
      now = DatabaseClock.now!()

      prepared = %{
        id: Ecto.UUID.generate(),
        envelope_key: envelope_key,
        user_id: run.user_id,
        connected_account_id: run.connected_account_id,
        provider: run.provider,
        provider_account_key: run.provider_account_key,
        source: run.source,
        scope_key: run.scope_key,
        source_item_key: source_item_key,
        source_revision_key: source_revision_key,
        raw_payload: raw_payload,
        normalized_payload: normalized_payload,
        raw_digest: raw_digest,
        normalized_digest: normalized_digest,
        occurred_at: occurred_at,
        received_at: now,
        inserted_at: now,
        provenance: provenance
      }

      changeset = SourceEnvelope.changeset(%SourceEnvelope{}, Map.delete(prepared, :provenance))
      if changeset.valid?, do: {:ok, prepared}, else: {:error, changeset}
    else
      {:error, :invalid_lineage_payload} -> {:error, :invalid_source_envelope_payload}
      {:error, _reason} -> {:error, :invalid_source_envelope}
    end
  end

  defp prepare_envelope(_run, _attrs), do: {:error, :invalid_source_envelope}

  defp acquisition_identity(attrs) do
    with {:ok, user_id} <- Canonical.string(value(attrs, :user_id), 320, allow_whitespace: false),
         {:ok, agent_id} <- uuid(value(attrs, :agent_id)),
         {:ok, agent_directive_id} <- uuid(value(attrs, :agent_directive_id)),
         {:ok, runtime_ingress_receipt_id} <- uuid(value(attrs, :runtime_ingress_receipt_id)),
         {:ok, connected_account_id} <- positive_integer(value(attrs, :connected_account_id)),
         {:ok, provider} <-
           Canonical.string(value(attrs, :provider), 80, allow_whitespace: false),
         {:ok, source} <- Canonical.string(value(attrs, :source), 80, allow_whitespace: false),
         {:ok, scope_key} <- Canonical.string(value(attrs, :scope_key), 255),
         {:ok, request_key} <- Canonical.string(value(attrs, :request_key), 255),
         {:ok, contract_version} <- contract_version(value(attrs, :contract_version, 1)),
         {:ok, cursor} <- cursor_identity(attrs) do
      {:ok,
       Map.merge(cursor, %{
         user_id: user_id,
         agent_id: agent_id,
         agent_directive_id: agent_directive_id,
         runtime_ingress_receipt_id: runtime_ingress_receipt_id,
         connected_account_id: connected_account_id,
         provider: provider,
         source: source,
         scope_key: scope_key,
         request_key: request_key,
         contract_version: contract_version
       })}
    else
      _error -> {:error, :invalid_acquisition}
    end
  end

  defp cursor_identity(attrs) do
    case {value(attrs, :source_cursor_id), value(attrs, :cursor_kind)} do
      {nil, nil} ->
        {:ok, %{source_cursor_id: nil, cursor_kind: nil}}

      {id, kind} ->
        with {:ok, id} <- uuid(id),
             {:ok, kind} <- Canonical.string(kind, 80) do
          {:ok, %{source_cursor_id: id, cursor_kind: kind}}
        end
    end
  end

  defp exact_directive(identity) do
    case Repo.one(
           from(directive in AgentDirective,
             where: directive.id == ^identity.agent_directive_id,
             where: directive.agent_id == ^identity.agent_id,
             where: directive.user_id == ^identity.user_id,
             lock: "FOR SHARE"
           )
         ) do
      nil -> {:error, :directive_owner_mismatch}
      directive -> {:ok, directive}
    end
  end

  defp exact_receipt(identity) do
    case Repo.one(
           from(receipt in IngressReceipt,
             where: receipt.id == ^identity.runtime_ingress_receipt_id,
             where: receipt.agent_id == ^identity.agent_id,
             where: receipt.user_id == ^identity.user_id,
             where: receipt.connected_account_id == ^identity.connected_account_id,
             where: receipt.provider == ^identity.provider,
             lock: "FOR SHARE"
           )
         ) do
      nil -> {:error, :ingress_owner_mismatch}
      receipt -> {:ok, receipt}
    end
  end

  defp exact_cursor(%{source_cursor_id: nil}), do: {:ok, nil}

  defp exact_cursor(identity) do
    case Repo.one(
           from(cursor in SourceCursor,
             where: cursor.id == ^identity.source_cursor_id,
             where: cursor.connected_account_id == ^identity.connected_account_id,
             where: cursor.user_id == ^identity.user_id,
             where: cursor.provider == ^identity.provider,
             where: cursor.kind == ^identity.cursor_kind,
             lock: "FOR SHARE"
           )
         ) do
      nil -> {:error, :source_cursor_owner_mismatch}
      cursor -> {:ok, cursor}
    end
  end

  defp start_cursor(nil), do: {:ok, nil}
  defp start_cursor(%SourceCursor{value: value}), do: {:ok, value}

  defp acquisition_fingerprint(identity, directive, receipt, start_cursor) do
    Canonical.identity("chief-acquisition-request-v1", [
      directive.dedupe_key,
      receipt.receipt_key,
      identity.provider,
      identity.provider_account_key,
      identity.source,
      identity.scope_key,
      identity.request_key,
      identity.contract_version,
      identity.source_cursor_id,
      identity.cursor_kind,
      start_cursor
    ])
  end

  defp insert_run(prepared) do
    changeset = AcquisitionRun.changeset(%AcquisitionRun{}, prepared)

    if changeset.valid? do
      case Repo.insert_all(AcquisitionRun, [prepared],
             on_conflict: :nothing,
             conflict_target: [:agent_directive_id, :request_key],
             returning: [:id]
           ) do
        {1, _rows} ->
          {:ok, Repo.get!(AcquisitionRun, prepared.id), :inserted}

        {0, _rows} ->
          existing =
            Repo.get_by!(AcquisitionRun,
              agent_directive_id: prepared.agent_directive_id,
              request_key: prepared.request_key
            )

          if run_same?(existing, prepared),
            do: {:ok, existing, :duplicate},
            else: {:error, :acquisition_idempotency_conflict}
      end
    else
      {:error, changeset}
    end
  end

  defp run_same?(existing, prepared) do
    existing.acquisition_key == prepared.acquisition_key and
      existing.user_id == prepared.user_id and
      existing.agent_id == prepared.agent_id and
      existing.agent_directive_id == prepared.agent_directive_id and
      existing.runtime_ingress_receipt_id == prepared.runtime_ingress_receipt_id and
      existing.connected_account_id == prepared.connected_account_id and
      existing.source_cursor_id == prepared.source_cursor_id and
      existing.cursor_kind == prepared.cursor_kind and
      existing.provider == prepared.provider and
      existing.provider_account_key == prepared.provider_account_key and
      existing.source == prepared.source and
      existing.scope_key == prepared.scope_key and
      existing.request_key == prepared.request_key and
      existing.request_fingerprint == prepared.request_fingerprint and
      existing.contract_version == prepared.contract_version and
      existing.start_cursor == prepared.start_cursor
  end

  defp expected_request_cursor(run, page) do
    expected =
      if page.ordinal == 0 do
        run.start_cursor
      else
        previous = page_by_ordinal(run.id, page.ordinal - 1)
        if previous, do: previous.next_cursor, else: :missing
      end

    if expected != :missing and expected == page.request_cursor,
      do: :ok,
      else: {:error, :acquisition_page_cursor_mismatch}
  end

  defp complete_page_proof(run) do
    pages =
      Repo.all(
        from(page in AcquisitionPage,
          where: page.acquisition_run_id == ^run.id,
          order_by: [asc: page.ordinal]
        )
      )

    ordinals = Enum.map(pages, & &1.ordinal)
    expected_ordinals = if pages == [], do: [], else: Enum.to_list(0..(length(pages) - 1))
    item_count = Enum.sum(Enum.map(pages, & &1.item_count))
    association_ordinals = association_ordinals(run.id)
    association_count = association_ordinals |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    cond do
      pages == [] ->
        {:error, :acquisition_terminal_page_required}

      ordinals != expected_ordinals ->
        {:error, :noncontiguous_acquisition_pages}

      run.page_count != length(pages) ->
        {:error, :acquisition_page_count_mismatch}

      run.item_count != item_count or item_count != association_count ->
        {:error, :acquisition_item_count_mismatch}

      not exact_page_item_ordinals?(pages, association_ordinals) ->
        {:error, :acquisition_item_ordinal_mismatch}

      not complete_cursor_chain?(pages, run.start_cursor) ->
        {:error, :acquisition_pagination_incomplete}

      not run.pagination_exhausted or not is_nil(run.continuation) ->
        {:error, :acquisition_pagination_incomplete}

      true ->
        :ok
    end
  end

  defp complete_cursor_chain?([first | rest], start_cursor) do
    first.request_cursor == start_cursor and
      Enum.reduce_while(rest, first, fn page, previous ->
        if not previous.terminal and page.request_cursor == previous.next_cursor,
          do: {:cont, page},
          else: {:halt, false}
      end)
      |> case do
        false -> false
        last -> last.terminal
      end
  end

  defp complete_cursor_chain?([], _start_cursor), do: false

  defp exact_page_item_ordinals?(pages, association_ordinals) do
    Enum.all?(pages, fn page ->
      actual = Map.get(association_ordinals, page.id, [])
      expected = if page.item_count == 0, do: [], else: Enum.to_list(0..(page.item_count - 1))
      actual == expected
    end)
  end

  defp association_ordinals(run_id) do
    Repo.all(
      from(association in AcquisitionEnvelope,
        join: page in AcquisitionPage,
        on: page.id == association.acquisition_page_id,
        where: association.acquisition_run_id == ^run_id,
        order_by: [asc: page.ordinal, asc: association.item_ordinal],
        select: {page.id, association.item_ordinal}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp manifest_digest(run, suffix) do
    pages =
      Repo.all(
        from(page in AcquisitionPage,
          where: page.acquisition_run_id == ^run.id,
          order_by: [asc: page.ordinal],
          select: {page.ordinal, page.request_fingerprint, page.response_digest, page.terminal}
        )
      )

    envelopes =
      Repo.all(
        from(association in AcquisitionEnvelope,
          join: page in AcquisitionPage,
          on: page.id == association.acquisition_page_id,
          join: envelope in SourceEnvelope,
          on: envelope.id == association.source_envelope_id,
          where: association.acquisition_run_id == ^run.id,
          order_by: [asc: page.ordinal, asc: association.item_ordinal],
          select: envelope.envelope_key
        )
      )

    page_parts =
      Enum.flat_map(pages, fn {ordinal, request_digest, response_digest, terminal} ->
        [
          ordinal,
          request_digest,
          response_digest,
          if(terminal, do: "terminal", else: "continued")
        ]
      end)

    Canonical.identity(
      "chief-acquisition-manifest-v1",
      [run.acquisition_key, run.start_cursor, length(pages), length(envelopes)] ++
        page_parts ++ envelopes ++ suffix
    )
  end

  defp update_run(run, attrs) do
    case run |> AcquisitionRun.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp lock_run(id) do
    Repo.one(from(run in AcquisitionRun, where: run.id == ^id, lock: "FOR UPDATE"))
  end

  defp page_by_ordinal(run_id, ordinal) do
    Repo.get_by(AcquisitionPage, acquisition_run_id: run_id, ordinal: ordinal)
  end

  defp proposed_cursor(%AcquisitionRun{source_cursor_id: nil}, nil), do: {:ok, nil}

  defp proposed_cursor(%AcquisitionRun{source_cursor_id: nil}, _value),
    do: {:error, :cursorless_acquisition_has_proposed_cursor}

  defp proposed_cursor(%AcquisitionRun{}, value), do: Canonical.string(value, 4096)

  defp fetching(%AcquisitionRun{status: "fetching"}), do: :ok
  defp fetching(%AcquisitionRun{}), do: {:error, :acquisition_sealed}

  defp pagination_open(%AcquisitionRun{pagination_exhausted: true}),
    do: {:error, :acquisition_pagination_exhausted}

  defp pagination_open(%AcquisitionRun{} = run) do
    terminal_exists? =
      Repo.exists?(
        from(page in AcquisitionPage,
          where: page.acquisition_run_id == ^run.id and page.terminal == true
        )
      )

    if terminal_exists?, do: {:error, :acquisition_pagination_exhausted}, else: :ok
  end

  defp failure_code(value) when is_atom(value), do: failure_code(Atom.to_string(value))

  defp failure_code(value) when is_binary(value) do
    if value in AcquisitionRun.failure_codes(),
      do: {:ok, value},
      else: {:error, :invalid_failure_code}
  end

  defp failure_code(_value), do: {:error, :invalid_failure_code}

  defp terminal_cursor(true, nil), do: :ok
  defp terminal_cursor(false, value) when is_binary(value), do: :ok
  defp terminal_cursor(_terminal, _next_cursor), do: {:error, :invalid_page_cursor}

  defp provenance(value) do
    case Canonical.object(value, @max_provenance_bytes,
           max_binary_bytes: 4_096,
           max_depth: 6,
           max_nodes: 1_000,
           max_map_entries: 100,
           max_list_items: 100
         ) do
      {:ok, canonical, _encoded, _digest} -> {:ok, canonical}
      _error -> {:error, :invalid_source_provenance}
    end
  end

  defp unique_envelope_keys?(envelopes) do
    keys = Enum.map(envelopes, & &1.envelope_key)
    length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp schema_id(%schema{id: id}, schema), do: uuid(id)
  defp schema_id(id, _schema), do: uuid(id)

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_account_id}

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp nonnegative_integer(_value), do: {:error, :invalid_ordinal}

  defp contract_version(value) when is_integer(value) and value in 1..100, do: {:ok, value}
  defp contract_version(_value), do: {:error, :invalid_contract_version}

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: {:error, :invalid_boolean}

  defp optional_cursor(nil), do: {:ok, nil}
  defp optional_cursor(value), do: Canonical.string(value, 4096)

  defp optional_datetime(nil), do: {:ok, nil}

  defp optional_datetime(%DateTime{} = value),
    do: {:ok, DateTime.truncate(value, :microsecond)}

  defp optional_datetime(_value), do: {:error, :invalid_datetime}

  defp with_savepoint(fun) do
    savepoint = "chief_record_page_#{System.unique_integer([:positive])}"
    Repo.query!("SAVEPOINT " <> savepoint)

    try do
      result = fun.()

      case result do
        {:error, _reason} -> rollback_savepoint(savepoint)
        _success -> Repo.query!("RELEASE SAVEPOINT " <> savepoint)
      end

      result
    rescue
      exception ->
        rollback_savepoint(savepoint)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        rollback_savepoint(savepoint)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp rollback_savepoint(savepoint) do
    Repo.query!("ROLLBACK TO SAVEPOINT " <> savepoint)
    Repo.query!("RELEASE SAVEPOINT " <> savepoint)
    :ok
  end

  defp transact(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, _one, _two, _three} = result -> result
             {:ok, _one, _two} = result -> result
             {:ok, _one} = result -> result
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
