defmodule Maraithon.DurablePayloadVerification do
  @moduledoc """
  Bounded, resumable authenticated verification of encrypted durable payloads.

  Candidate rows are guarded by transaction-scoped advisory locks. Ciphertext
  is decrypted and schema/bounds checked through `Maraithon.Vault`; only then
  does PostgreSQL compare source digests and store content-free ciphertext,
  projection, version, and purge proofs. Source mutation triggers take the same
  advisory lock before invalidating proofs, closing the compare-and-swap race.
  Results contain
  row identity and closed failure classes only.

  New durable-copy tables extend this module with one fixed SQL candidate/store
  pair and a `validate_row/2` clause, then attach the common invalidation
  trigger and activation manifest entry.
  """

  alias Maraithon.DurablePayload
  alias Maraithon.DurablePayloadBinding
  alias Maraithon.DurablePayloadRegistry
  alias Maraithon.Effects
  alias Maraithon.Repo
  alias Maraithon.Vault

  @tables DurablePayloadRegistry.tables()
  @default_limit 25
  @max_limit 100

  @doc "Supported source-table identifiers."
  def tables, do: @tables

  @doc "Content-free count of source rows whose proof/shape is not activation-ready."
  def preflight do
    case Repo.query("SELECT public.durable_payload_proof_failures()", [], log: false) do
      {:ok, %{rows: [[count]]}} -> {:ok, %{failures: count}}
      {:error, _reason} -> {:error, :durable_payload_proof_preflight_failed}
    end
  rescue
    _error -> {:error, :durable_payload_proof_preflight_failed}
  catch
    :exit, _reason -> {:error, :durable_payload_proof_preflight_failed}
  end

  @doc "Verifies one locked, bounded batch for a fixed source table."
  def verify_batch(payload_table, opts \\ [])

  def verify_batch(payload_table, opts)
      when payload_table in @tables and is_list(opts) do
    with {:ok, limit} <- limit(opts) do
      case Repo.transaction(
             fn ->
               assume_verifier_role!()

               try do
                 verify_locked_batch(payload_table, limit)
               after
                 reset_verifier_role!()
               end
             end,
             timeout: 60_000
           ) do
        {:ok, result} -> {:ok, result}
        {:error, _reason} -> {:error, :durable_payload_verification_failed}
      end
    end
  rescue
    _error -> {:error, :durable_payload_verification_failed}
  catch
    :exit, _reason -> {:error, :durable_payload_verification_failed}
  end

  def verify_batch(_payload_table, _opts),
    do: {:error, :invalid_durable_payload_verification_options}

  @doc "Runs a bounded number of batches without ever loading a whole table."
  def verify(opts \\ [])

  def verify(opts) when is_list(opts) do
    with {:ok, limit} <- limit(opts),
         {:ok, max_batches} <- max_batches(opts),
         {:ok, tables} <- selected_tables(opts) do
      initial = %{batches: 0, verified: 0, failures: []}
      run_batches(tables, limit, max_batches, initial)
    end
  end

  def verify(_opts), do: {:error, :invalid_durable_payload_verification_options}

  defp run_batches(_tables, _limit, 0, state), do: {:ok, state}

  defp run_batches(tables, limit, remaining, state) do
    case run_table_round(tables, limit, state) do
      {:ok, next, 0} ->
        {:ok, next}

      {:ok, next, progressed} when progressed > 0 ->
        run_batches(tables, limit, remaining - 1, next)

      {:error, _reason} = error ->
        error
    end
  end

  defp run_table_round(tables, limit, state) do
    Enum.reduce_while(tables, {:ok, state, 0}, fn table, {:ok, acc, progressed} ->
      case verify_batch(table, limit: limit) do
        {:ok, batch} ->
          next = %{
            batches: acc.batches + 1,
            verified: acc.verified + batch.verified,
            failures: acc.failures ++ batch.failures
          }

          {:cont, {:ok, next, progressed + batch.verified + length(batch.failures)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp verify_locked_batch(payload_table, limit) do
    oversized = Repo.query!(oversized_candidate_sql(payload_table), [limit], log: false).rows

    oversized_result =
      Enum.reduce(oversized, %{table: payload_table, verified: 0, failures: []}, fn
        [
          id,
          row_identity,
          advisory_identity,
          ciphertext_digest,
          projection_digest,
          version_digest,
          purge_digest
        ],
        acc ->
          digests = [ciphertext_digest, projection_digest, version_digest, purge_digest]

          result =
            if row_identity == advisory_identity,
              do: store_failure!(payload_table, row_identity, :oversized, digests),
              else: :source_changed

          failure = if result == :ok, do: :oversized, else: :source_changed
          %{acc | failures: [%{id: id, failure: failure} | acc.failures]}
      end)

    remaining = limit - length(oversized)

    rows =
      if remaining > 0,
        do: Repo.query!(candidate_sql(payload_table), [remaining], log: false).rows,
        else: []

    rows
    |> Enum.reduce(oversized_result, fn enveloped_row, acc ->
      {row,
       [advisory_identity, ciphertext_digest, projection_digest, version_digest, purge_digest]} =
        Enum.split(enveloped_row, length(enveloped_row) - 5)

      id = hd(row)
      row_identity = Enum.at(row, 1)
      candidate_digests = [ciphertext_digest, projection_digest, version_digest, purge_digest]

      # The canonical identity returned in the source projection must be the
      # same value used for the advisory lock and compare-and-swap.
      if row_identity != advisory_identity do
        %{acc | failures: [%{id: id, failure: :source_changed} | acc.failures]}
      else
        case safely_validate_row(payload_table, row) do
          {:ok, verification} ->
            case store_proof!(
                   payload_table,
                   row_identity,
                   verification.key_tags,
                   candidate_digests
                 ) do
              :ok ->
                %{acc | verified: acc.verified + 1}

              :source_changed ->
                %{acc | failures: [%{id: id, failure: :source_changed} | acc.failures]}
            end

          {:error, failure} ->
            case store_failure!(payload_table, row_identity, failure, candidate_digests) do
              :ok ->
                %{acc | failures: [%{id: id, failure: failure} | acc.failures]}

              :source_changed ->
                %{acc | failures: [%{id: id, failure: :source_changed} | acc.failures]}
            end
        end
      end
    end)
    |> Map.update!(:failures, &Enum.reverse/1)
  end

  defp safely_validate_row(payload_table, row) do
    validate_row(payload_table, row)
  rescue
    _error -> {:error, :verification_exception}
  catch
    :exit, _reason -> {:error, :verification_exception}
    _kind, _reason -> {:error, :verification_exception}
  end

  # report id, stable identity, ciphertexts/projections, encryption version,
  # purge marker, row context, and persisted binding.
  defp validate_row("effects", [
         id,
         _row_identity,
         params,
         result,
         projection,
         result_projection,
         1,
         purged_at,
         agent_id,
         owner_user_id,
         binding_version,
         binding_key_tag,
         binding_mac
       ]) do
    with true <- projection == %{"redacted" => true},
         true <- is_nil(result_projection),
         {:ok, params_map, params_tag} <- decrypt_map(params),
         {:ok, _prepared} <- Effects.prepare_params(nil, params_map),
         {:ok, result_map, result_tag} <- validate_optional_effect_result(result),
         :ok <- validate_effect_purge(purged_at, params_map, result),
         {:ok, binding} <-
           verify_or_prepare_binding(
             "effects",
             DurablePayload.context_identity([id]),
             DurablePayload.context_identity([owner_user_id, agent_id]),
             [{"params", params_map}, {"result", result_map}],
             binding_version,
             binding_key_tag,
             binding_mac
           ) do
      {:ok,
       %{
         key_tags: Enum.reject([params_tag, result_tag], &is_nil/1) |> Enum.uniq() |> Enum.sort(),
         binding: binding
       }}
    else
      false -> {:error, :projection_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_row("effects", _row), do: {:error, :encryption_version_mismatch}

  defp validate_row("agent_directives", [
         id,
         _row_identity,
         ciphertext,
         projection,
         1,
         purged_at,
         agent_id,
         user_id,
         binding_version,
         binding_key_tag,
         binding_mac
       ]) do
    with true <- projection == %{"redacted" => true},
         {:ok, payload, tag} <- decrypt_map(ciphertext),
         {:ok, _canonical} <-
           DurablePayload.prepare_map(payload, 128_000,
             max_binary_bytes: 100_000,
             max_depth: 12,
             max_nodes: 20_000,
             max_map_entries: 2_000,
             max_list_items: 5_000
           ),
         :ok <- validate_directive_purge(purged_at, payload),
         {:ok, binding} <-
           verify_or_prepare_binding(
             "agent_directives",
             DurablePayload.context_identity([id]),
             DurablePayload.context_identity([user_id, agent_id]),
             [{"payload", payload}],
             binding_version,
             binding_key_tag,
             binding_mac
           ) do
      {:ok, %{key_tags: [tag], binding: binding}}
    else
      false -> {:error, :projection_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_row("agent_directives", _row),
    do: {:error, :encryption_version_mismatch}

  defp validate_row("events", [
         _id,
         _row_identity,
         ciphertext,
         projection,
         1,
         nil,
         agent_id,
         sequence_num,
         binding_version,
         binding_key_tag,
         binding_mac
       ]) do
    with true <- projection == %{},
         {:ok, payload, tag} <- decrypt_map(ciphertext),
         {:ok, _canonical} <-
           DurablePayload.prepare_map(payload, 640_000,
             max_binary_bytes: 512_000,
             max_depth: 12,
             max_nodes: 20_000,
             max_map_entries: 2_000,
             max_list_items: 2_000
           ),
         {:ok, binding} <-
           verify_or_prepare_binding(
             "events",
             DurablePayload.context_identity([agent_id, sequence_num]),
             DurablePayload.context_identity([agent_id]),
             [{"payload", payload}],
             binding_version,
             binding_key_tag,
             binding_mac
           ) do
      {:ok, %{key_tags: [tag], binding: binding}}
    else
      false -> {:error, :projection_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_row("events", _row), do: {:error, :encryption_version_mismatch}

  defp validate_row("agent_run_steps", [
         id,
         _row_identity,
         request,
         response,
         request_projection,
         response_projection,
         1,
         nil,
         agent_id,
         agent_run_id,
         binding_version,
         binding_key_tag,
         binding_mac
       ]) do
    with true <- request_projection == %{} and response_projection == %{},
         {:ok, request_map, request_tag} <- decrypt_map(request),
         {:ok, _canonical_request} <-
           DurablePayload.prepare_map(request_map, 256_000,
             max_binary_bytes: 192_000,
             max_depth: 12,
             max_nodes: 20_000,
             max_map_entries: 2_000,
             max_list_items: 2_000
           ),
         {:ok, response_map, response_tag} <- decrypt_map(response),
         {:ok, _canonical_response} <-
           DurablePayload.prepare_map(response_map, 640_000,
             max_binary_bytes: 512_000,
             max_depth: 12,
             max_nodes: 20_000,
             max_map_entries: 2_000,
             max_list_items: 2_000
           ),
         {:ok, binding} <-
           verify_or_prepare_binding(
             "agent_run_steps",
             DurablePayload.context_identity([id]),
             DurablePayload.context_identity([agent_id, agent_run_id]),
             [{"request_payload", request_map}, {"response_payload", response_map}],
             binding_version,
             binding_key_tag,
             binding_mac
           ) do
      {:ok, %{key_tags: Enum.uniq([request_tag, response_tag]) |> Enum.sort(), binding: binding}}
    else
      false -> {:error, :projection_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_row("agent_run_steps", _row),
    do: {:error, :encryption_version_mismatch}

  defp validate_row(payload_table, row) do
    with {:ok, source} <- DurablePayloadRegistry.fetch(payload_table),
         {:ok, parsed} <- parse_registered_row(source, row),
         true <- parsed.version == 1,
         true <- is_nil(parsed.purged_at),
         :ok <- validate_registered_projection(payload_table, parsed.projections),
         {:ok, values, key_tags} <- decrypt_registered_fields(source.fields, parsed.ciphertexts),
         :ok <- validate_registered_semantics(source.table, values),
         :ok <-
           verify_registered_binding(
             source,
             parsed.identity_values,
             parsed.scope_values,
             values,
             parsed.binding
           ),
         :ok <- validate_registered_authority(source, parsed, values) do
      {:ok, %{key_tags: Enum.uniq(key_tags) |> Enum.sort(), binding: nil}}
    else
      false -> {:error, :encryption_version_mismatch}
      :error -> {:error, :unsupported_payload_table}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_registered_row(source, [id, row_identity | values]) do
    field_count = length(source.fields)
    identity_count = length(source.identity)
    scope_count = length(source.scope)
    {ciphertexts, values} = Enum.split(values, field_count)
    {projections, values} = Enum.split(values, field_count)

    case values do
      [version, purged_at | context_and_binding] ->
        {identity_values, context_and_binding} = Enum.split(context_and_binding, identity_count)
        {scope_values, context_and_binding} = Enum.split(context_and_binding, scope_count)

        case context_and_binding do
          [binding_version, binding_key_tag, binding_mac | authority] ->
            {:ok,
             %{
               id: id,
               row_identity: row_identity,
               ciphertexts: ciphertexts,
               projections: projections,
               version: version,
               purged_at: purged_at,
               identity_values: identity_values,
               scope_values: scope_values,
               binding: {binding_version, binding_key_tag, binding_mac},
               authority: authority
             }}

          _invalid ->
            {:error, :payload_schema_invalid}
        end

      _invalid ->
        {:error, :payload_schema_invalid}
    end
  end

  defp parse_registered_row(_source, _row), do: {:error, :payload_schema_invalid}

  defp decrypt_registered_fields(fields, ciphertexts) do
    fields
    |> Enum.zip(ciphertexts)
    |> Enum.reduce_while({:ok, [], []}, fn
      {{name, _column, _type, _max_bytes, false}, nil}, {:ok, values, tags} ->
        {:cont, {:ok, [{Atom.to_string(name), nil} | values], tags}}

      {{_name, _column, _type, _max_bytes, true}, nil}, _acc ->
        {:halt, {:error, :ciphertext_missing}}

      {{name, _column, :map, _raw_max_bytes, _required}, ciphertext}, {:ok, values, tags} ->
        case decrypt_map(ciphertext) do
          {:ok, value, tag} ->
            {:cont, {:ok, [{Atom.to_string(name), value} | values], [tag | tags]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      {{name, _column, :binary, _raw_max_bytes, _required}, ciphertext}, {:ok, values, tags} ->
        with {:ok, value} <- decrypt_authenticated(ciphertext),
             true <- String.valid?(value),
             :nomatch <- :binary.match(value, <<0>>),
             {:ok, tag} <- ciphertext_tag(ciphertext) do
          {:cont, {:ok, [{Atom.to_string(name), value} | values], [tag | tags]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
          _invalid -> {:halt, {:error, :payload_schema_invalid}}
        end
    end)
    |> case do
      {:ok, values, tags} -> {:ok, Enum.reverse(values), Enum.reverse(tags)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_registered_semantics("telegram_conversation_turns", fields) do
    with {:ok, text} <- field(fields, "text"),
         true <-
           is_binary(text) and String.valid?(text) and
             byte_size(text) <= Maraithon.TelegramConversations.Turn.max_text_bytes(),
         {:ok, data} <- field(fields, "structured_data"),
         true <-
           Maraithon.BoundedJSON.valid?(
             data,
             Maraithon.TelegramConversations.Turn.max_structured_data_bytes(),
             Maraithon.TelegramConversations.Turn.structured_data_bounds()
           ) do
      :ok
    else
      _invalid -> {:error, :payload_schema_invalid}
    end
  end

  defp validate_registered_semantics("telegram_conversations", fields) do
    with {:ok, summary} <- field(fields, "summary"),
         {:ok, historical} <- field(fields, "historical_summary"),
         true <-
           optional_utf8?(
             summary,
             Maraithon.TelegramConversations.Conversation.max_summary_bytes()
           ),
         true <-
           optional_utf8?(
             historical,
             Maraithon.TelegramConversations.Conversation.max_summary_bytes()
           ) do
      :ok
    else
      _invalid -> {:error, :payload_schema_invalid}
    end
  end

  defp validate_registered_semantics(table, fields)
       when table in ["telegram_assistant_runs", "telegram_assistant_steps", "background_jobs"] do
    {limits, bounds} =
      case table do
        "telegram_assistant_runs" ->
          {%{
             "prompt_snapshot" => Maraithon.TelegramAssistant.Run.max_prompt_snapshot_bytes(),
             "result_summary" => Maraithon.TelegramAssistant.Run.max_result_summary_bytes()
           }, Maraithon.TelegramAssistant.Run.payload_bounds()}

        "telegram_assistant_steps" ->
          {%{
             "request_payload" => Maraithon.TelegramAssistant.Step.max_request_payload_bytes(),
             "response_payload" => Maraithon.TelegramAssistant.Step.max_response_payload_bytes()
           }, Maraithon.TelegramAssistant.Step.payload_bounds()}

        "background_jobs" ->
          {%{
             "payload" => Maraithon.Runtime.BackgroundJob.max_payload_bytes(),
             "result" => Maraithon.Runtime.BackgroundJob.max_result_bytes()
           }, Maraithon.Runtime.BackgroundJob.payload_bounds()}
      end

    validate_maps(fields, limits, bounds)
  end

  defp validate_registered_semantics("telegram_prepared_actions", fields) do
    with :ok <-
           validate_maps(
             fields,
             %{"payload" => Maraithon.TelegramAssistant.PreparedAction.max_payload_bytes()},
             Maraithon.TelegramAssistant.PreparedAction.payload_bounds()
           ),
         {:ok, preview} <- field(fields, "preview_text"),
         true <-
           is_binary(preview) and preview != "" and String.valid?(preview) and
             byte_size(preview) <= Maraithon.TelegramAssistant.PreparedAction.max_preview_bytes() do
      :ok
    else
      _invalid -> {:error, :payload_schema_invalid}
    end
  end

  defp validate_registered_semantics(table, fields)
       when table in ["agent_runs", "operator_events"] do
    {limits, bounds} =
      case table do
        "agent_runs" ->
          {%{
             "trigger" => Maraithon.Agents.AgentRun.max_trigger_bytes(),
             "metadata" => Maraithon.Agents.AgentRun.max_metadata_bytes()
           }, Maraithon.Agents.AgentRun.payload_bounds()}

        "operator_events" ->
          {%{
             "payload" => Maraithon.OperatorEvents.OperatorEvent.max_payload_bytes(),
             "metadata" => Maraithon.OperatorEvents.OperatorEvent.max_metadata_bytes()
           }, Maraithon.OperatorEvents.OperatorEvent.payload_bounds()}
      end

    validate_maps(fields, limits, bounds)
  end

  defp validate_registered_semantics("user_memory_profiles", fields) do
    with {:ok, summary} <- field(fields, "summary"),
         true <-
           is_binary(summary) and String.valid?(summary) and String.length(summary) >= 4 and
             byte_size(summary) <= Maraithon.UserMemory.Profile.max_summary_bytes(),
         :ok <-
           validate_maps(
             fields,
             %{"profile" => Maraithon.UserMemory.Profile.max_profile_bytes()},
             Maraithon.UserMemory.Profile.profile_bounds()
           ) do
      :ok
    else
      _invalid -> {:error, :payload_schema_invalid}
    end
  end

  defp validate_registered_semantics("operator_memory_summaries", fields) do
    with {:ok, content} <- field(fields, "content"),
         true <-
           is_binary(content) and String.valid?(content) and
             byte_size(content) <= Maraithon.OperatorMemory.Summary.max_content_bytes() do
      :ok
    else
      _invalid -> {:error, :payload_schema_invalid}
    end
  end

  defp validate_registered_semantics("scheduled_jobs", fields) do
    validate_maps(
      fields,
      %{"payload" => Maraithon.Runtime.ScheduledJob.max_payload_bytes()},
      Maraithon.Runtime.ScheduledJob.payload_bounds()
    )
  end

  defp validate_registered_semantics(table, fields)
       when table in ["runtime_ingress_receipts", "agent_work_results"] do
    max_bytes = if table == "runtime_ingress_receipts", do: 160_000, else: 128_000

    validate_maps(
      fields,
      %{if(table == "runtime_ingress_receipts", do: "payload", else: "result") => max_bytes},
      max_binary_bytes: max_bytes,
      max_depth: 16,
      max_nodes: 25_000,
      max_map_entries: 5_000,
      max_list_items: 5_000
    )
  end

  defp validate_registered_semantics("snapshots", fields) do
    with {:ok, state_data} <- field(fields, "state_data"),
         {:ok, budget} <- field(fields, "budget"),
         {:ok, _state, _} <- Maraithon.Runtime.SnapshotFormat.decode_stored(state_data),
         {:ok, _budget, _} <- Maraithon.Runtime.SnapshotFormat.decode_stored(budget),
         {:ok, state_json} <- Jason.encode(state_data),
         {:ok, budget_json} <- Jason.encode(budget),
         true <-
           byte_size(state_json) + byte_size(budget_json) <=
             Maraithon.Runtime.SnapshotFormat.max_encoded_bytes() do
      :ok
    else
      _invalid -> {:error, :payload_schema_invalid}
    end
  end

  defp validate_maps(fields, limits, bounds) do
    Enum.reduce_while(limits, :ok, fn {name, max_bytes}, :ok ->
      with {:ok, value} <- field(fields, name),
           {:ok, _canonical} <- DurablePayload.prepare_map(value, max_bytes, bounds) do
        {:cont, :ok}
      else
        _invalid -> {:halt, {:error, :payload_schema_invalid}}
      end
    end)
  end

  defp field(fields, name) do
    case List.keyfind(fields, name, 0) do
      {^name, value} -> {:ok, value}
      nil -> {:error, :payload_schema_invalid}
    end
  end

  defp optional_utf8?(nil, _max_bytes), do: true

  defp optional_utf8?(value, max_bytes),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= max_bytes

  defp verify_registered_binding(source, identity_values, scope_values, fields, binding) do
    {version, key_tag, mac} = binding

    DurablePayloadBinding.verify(
      source.table,
      DurablePayload.context_identity(identity_values),
      DurablePayload.context_identity(scope_values),
      fields,
      version,
      key_tag,
      mac
    )
  end

  defp validate_registered_authority(%{table: "agent_work_results"}, parsed, fields) do
    case parsed.authority do
      [version, key_tag, mac] ->
        DurablePayloadBinding.verify(
          "agent_work_result_authority",
          List.first(parsed.identity_values),
          DurablePayload.context_identity(parsed.scope_values),
          fields,
          version,
          key_tag,
          mac
        )

      _invalid ->
        {:error, :authority_digest_missing}
    end
  end

  defp validate_registered_authority(_source, %{authority: []}, _fields), do: :ok

  defp validate_registered_authority(_source, _parsed, _fields),
    do: {:error, :payload_schema_invalid}

  defp validate_registered_projection(table, projections) do
    expected =
      case table do
        "telegram_conversation_turns" -> ["[encrypted]", %{}]
        "telegram_conversations" -> [nil, nil]
        "telegram_prepared_actions" -> [%{}, nil]
        "user_memory_profiles" -> ["[encrypted]", %{}]
        "operator_memory_summaries" -> ["[encrypted]"]
        _table -> Enum.map(projections, fn _projection -> %{} end)
      end

    if projections == expected, do: :ok, else: {:error, :projection_mismatch}
  end

  defp validate_optional_effect_result(nil), do: {:ok, nil, nil}

  defp validate_optional_effect_result(ciphertext) do
    with {:ok, result, tag} <- decrypt_map(ciphertext),
         {:ok, _canonical} <- Effects.prepare_result(result) do
      {:ok, result, tag}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_or_prepare_binding(_table, _row_identity, _scope, _fields, nil, nil, nil),
    do: {:error, :binding_missing}

  defp verify_or_prepare_binding(
         table,
         row_identity,
         scope,
         fields,
         version,
         key_tag,
         mac
       )
       when not is_nil(version) and is_binary(key_tag) and is_binary(mac) do
    case DurablePayloadBinding.verify(
           table,
           row_identity,
           scope,
           fields,
           version,
           key_tag,
           mac
         ) do
      :ok -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_or_prepare_binding(_table, _row_identity, _scope, _fields, _version, _tag, _mac),
    do: {:error, :binding_incomplete}

  defp validate_effect_purge(nil, _params, _result), do: :ok

  defp validate_effect_purge(_purged_at, _params, _result),
    do: {:error, :purge_marker_inconsistent}

  defp validate_directive_purge(nil, _payload), do: :ok
  defp validate_directive_purge(_purged_at, %{"redacted" => true}), do: :ok
  defp validate_directive_purge(_purged_at, _payload), do: {:error, :purge_marker_inconsistent}

  defp decrypt_map(nil), do: {:error, :ciphertext_missing}

  defp decrypt_map(ciphertext) when is_binary(ciphertext) do
    with {:ok, plaintext} <- decrypt_authenticated(ciphertext),
         {:ok, value} when is_map(value) and not is_struct(value) <- Jason.decode(plaintext),
         {:ok, tag} <- ciphertext_tag(ciphertext) do
      {:ok, value, tag}
    else
      {:error, :authentication_failed} -> {:error, :authentication_failed}
      {:error, _reason} -> {:error, :payload_schema_invalid}
      _invalid -> {:error, :payload_schema_invalid}
    end
  end

  defp decrypt_map(_ciphertext), do: {:error, :ciphertext_invalid}

  defp decrypt_authenticated(ciphertext) do
    case Vault.decrypt(ciphertext) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
      _error -> {:error, :authentication_failed}
    end
  rescue
    _error -> {:error, :authentication_failed}
  end

  defp ciphertext_tag(ciphertext), do: Vault.ciphertext_key_tag(ciphertext)

  defp store_proof!(payload_table, row_identity, key_tags, candidate_digests) do
    set_verifier_marker!()

    case Repo.query!(
           store_sql(payload_table),
           [row_identity, key_tags | candidate_digests],
           log: false
         ).num_rows do
      1 ->
        Repo.query!(
          """
          DELETE FROM public.durable_payload_verification_failures
          WHERE payload_table = $1 AND row_identity = $2
          """,
          [payload_table, row_identity],
          log: false
        )

        :ok

      0 ->
        :source_changed
    end
  end

  defp store_failure!(payload_table, row_identity, failure, candidate_digests) do
    set_verifier_marker!()

    case Repo.query!(
           failure_store_sql(payload_table),
           [row_identity, Atom.to_string(failure) | candidate_digests],
           log: false
         ).num_rows do
      1 -> :ok
      0 -> :source_changed
    end
  end

  defp assume_verifier_role! do
    Repo.query!("SET LOCAL ROLE maraithon_payload_verifier", [], log: false)
    :ok
  end

  defp reset_verifier_role! do
    Repo.query!("RESET ROLE", [], log: false)
    :ok
  end

  defp set_verifier_marker! do
    Repo.query!(
      "SELECT set_config('maraithon.durable_payload_verifier', 'VAULT_AUTHENTICATED_V1', true)",
      [],
      log: false
    )
  end

  defp oversized_candidate_sql(table) do
    {:ok, source} = DurablePayloadRegistry.fetch(table)
    identity_expression = source.identity_sql

    oversized =
      source.fields
      |> Enum.map(fn {_field, column, _type, max_bytes, _required} ->
        "octet_length(source.#{column}) > #{max_bytes}"
      end)
      |> Enum.join(" OR ")

    """
    WITH candidates AS MATERIALIZED (
      SELECT #{source.report_sql} AS report_id,
             public.durable_payload_row_identity('#{table}', #{identity_expression}) AS row_identity,
             public.durable_payload_row_identity('#{table}', #{identity_expression}) AS advisory_identity,
             public.durable_payload_digest_part('#{table}', to_jsonb(source), 'ciphertext') AS ciphertext_digest,
             public.durable_payload_digest_part('#{table}', to_jsonb(source), 'projection') AS projection_digest,
             public.durable_payload_digest_part('#{table}', to_jsonb(source), 'version') AS version_digest,
             public.durable_payload_digest_part('#{table}', to_jsonb(source), 'purge') AS purge_digest
      FROM public.#{table} AS source
      LEFT JOIN public.durable_payload_verification_failures AS failure
        ON failure.payload_table = '#{table}'
       AND failure.row_identity = public.durable_payload_row_identity('#{table}', #{identity_expression})
       AND failure.ciphertext_digest = public.durable_payload_digest_part('#{table}', to_jsonb(source), 'ciphertext')
       AND failure.projection_digest = public.durable_payload_digest_part('#{table}', to_jsonb(source), 'projection')
       AND failure.version_digest = public.durable_payload_digest_part('#{table}', to_jsonb(source), 'version')
       AND failure.purge_digest = public.durable_payload_digest_part('#{table}', to_jsonb(source), 'purge')
      WHERE failure.row_identity IS NULL
        AND source.#{source.purge} IS NULL
        AND (#{oversized})
      ORDER BY #{source.order_sql}
      LIMIT $1
    )
    SELECT * FROM candidates
    WHERE pg_catalog.pg_try_advisory_xact_lock(
      pg_catalog.hashtextextended('#{table}:' || advisory_identity, 0)
    )
    """
  end

  defp candidate_sql("effects"),
    do:
      candidate_sql_for(
        "effects",
        "source.id::text",
        """
          source.id::text,
          source.id::text,
          source.params_ciphertext,
          source.result_ciphertext,
          source.params,
          source.result,
          source.payload_encryption_version,
          source.payload_purged_at,
          source.agent_id::text,
          source.owner_user_id,
          source.payload_binding_version,
          source.payload_binding_key_tag,
          source.payload_binding_mac
        """,
        "(source.payload_purged_at IS NULL OR source.params_ciphertext IS NOT NULL OR source.result_ciphertext IS NOT NULL) AND (source.params_ciphertext IS NULL OR octet_length(source.params_ciphertext) <= 200000) AND (source.result_ciphertext IS NULL OR octet_length(source.result_ciphertext) <= 600000)",
        "source.id"
      )

  defp candidate_sql("agent_directives"),
    do:
      candidate_sql_for(
        "agent_directives",
        "source.id::text",
        """
          source.id::text,
          source.id::text,
          source.payload_ciphertext,
          source.payload,
          source.payload_encryption_version,
          source.payload_purged_at,
          source.agent_id::text,
          source.user_id,
          source.payload_binding_version,
          source.payload_binding_key_tag,
          source.payload_binding_mac
        """,
        "(source.payload_purged_at IS NULL OR source.payload_ciphertext IS NOT NULL) AND (source.payload_ciphertext IS NULL OR octet_length(source.payload_ciphertext) <= 180000)",
        "source.id"
      )

  defp candidate_sql("events"),
    do:
      candidate_sql_for(
        "events",
        "'[' || to_json(source.agent_id::text)::text || ',' || to_json(source.sequence_num::text)::text || ']'",
        """
          source.id::text,
          '[' || to_json(source.agent_id::text)::text || ',' || to_json(source.sequence_num::text)::text || ']',
          source.payload_ciphertext,
          source.payload,
          source.payload_encryption_version,
          source.payload_purged_at,
          source.agent_id::text,
          source.sequence_num,
          source.payload_binding_version,
          source.payload_binding_key_tag,
          source.payload_binding_mac
        """,
        "source.payload_purged_at IS NULL AND octet_length(source.payload_ciphertext) <= 700000",
        "source.inserted_at, source.id"
      )

  defp candidate_sql("agent_run_steps"),
    do:
      candidate_sql_for(
        "agent_run_steps",
        "source.id::text",
        """
          source.id::text,
          source.id::text,
          source.request_payload_ciphertext,
          source.response_payload_ciphertext,
          source.request_payload,
          source.response_payload,
          source.payload_encryption_version,
          source.payload_purged_at,
          source.agent_id::text,
          source.agent_run_id::text,
          source.payload_binding_version,
          source.payload_binding_key_tag,
          source.payload_binding_mac
        """,
        "source.payload_purged_at IS NULL AND octet_length(source.request_payload_ciphertext) <= 300000 AND octet_length(source.response_payload_ciphertext) <= 700000",
        "source.inserted_at, source.id"
      )

  defp candidate_sql(table) do
    {:ok, source} = DurablePayloadRegistry.fetch(table)
    identity_expression = source.identity_sql

    ciphertexts =
      Enum.map(source.fields, fn {_field, column, _type, _max_bytes, _required} ->
        "source.#{column}"
      end)

    projections = registered_projection_sql(table, source)
    identity_values = Enum.map(source.identity, &registered_context_sql(table, &1))
    scope_values = Enum.map(source.scope, &registered_context_sql(table, &1))

    authority =
      if table == "agent_work_results" do
        ["source.result_digest_version", "source.result_digest_key_tag", "source.result_digest"]
      else
        []
      end

    select =
      [
        source.report_sql,
        identity_expression
        | ciphertexts ++
            projections ++
            ["source.#{source.version}", "source.#{source.purge}"] ++
            identity_values ++
            scope_values ++
            [
              "source.payload_binding_version",
              "source.payload_binding_key_tag",
              "source.payload_binding_mac"
            ] ++ authority
      ]
      |> Enum.join(",\n          ")

    raw_size_filter =
      source.fields
      |> Enum.map(fn {_field, column, _type, max_bytes, required} ->
        null_clause = if required, do: "source.#{column} IS NOT NULL", else: "true"

        "(#{null_clause} AND (source.#{column} IS NULL OR octet_length(source.#{column}) <= #{max_bytes}))"
      end)
      |> Enum.join(" AND ")

    candidate_sql_for(
      table,
      identity_expression,
      "          " <> select,
      "source.#{source.purge} IS NULL AND #{raw_size_filter}",
      source.order_sql
    )
  end

  defp registered_context_sql("snapshots", field)
       when field in [:id, :sequence_num, :schema_version],
       do: "source.#{field}"

  defp registered_context_sql(_table, field), do: "source.#{field}::text"

  defp registered_projection_sql("telegram_conversations", _source),
    do: ["source.summary", "source.metadata -> 'historical_summary'"]

  defp registered_projection_sql(_table, source) do
    Enum.map(source.fields, fn {field, _column, _type, _max_bytes, _required} ->
      "source.#{field}"
    end)
  end

  defp candidate_sql_for(table, identity_expression, select, eligible, order) do
    """
    WITH candidates AS MATERIALIZED (
      SELECT #{select},
             public.durable_payload_row_identity(
               '#{table}', #{identity_expression}
             ) AS advisory_identity,
             public.durable_payload_digest_part(
               '#{table}', to_jsonb(source), 'ciphertext'
             ) AS candidate_ciphertext_digest,
             public.durable_payload_digest_part(
               '#{table}', to_jsonb(source), 'projection'
             ) AS candidate_projection_digest,
             public.durable_payload_digest_part(
               '#{table}', to_jsonb(source), 'version'
             ) AS candidate_version_digest,
             public.durable_payload_digest_part(
               '#{table}', to_jsonb(source), 'purge'
             ) AS candidate_purge_digest
      FROM public.#{table} AS source
      LEFT JOIN public.durable_payload_verifications AS proof
        ON proof.payload_table = '#{table}'
       AND proof.row_identity = public.durable_payload_row_identity(
         '#{table}', #{identity_expression}
       )
      LEFT JOIN public.durable_payload_verification_failures AS failure
        ON failure.payload_table = '#{table}'
       AND failure.row_identity = public.durable_payload_row_identity(
         '#{table}', #{identity_expression}
       )
       AND failure.ciphertext_digest = public.durable_payload_digest_part('#{table}', to_jsonb(source), 'ciphertext')
       AND failure.projection_digest = public.durable_payload_digest_part('#{table}', to_jsonb(source), 'projection')
       AND failure.version_digest = public.durable_payload_digest_part('#{table}', to_jsonb(source), 'version')
       AND failure.purge_digest = public.durable_payload_digest_part('#{table}', to_jsonb(source), 'purge')
      WHERE failure.row_identity IS NULL
        AND (#{eligible})
        AND (
          proof.row_identity IS NULL OR
          proof.ciphertext_digest IS DISTINCT FROM
            public.durable_payload_digest_part('#{table}', to_jsonb(source), 'ciphertext') OR
          proof.projection_digest IS DISTINCT FROM
            public.durable_payload_digest_part('#{table}', to_jsonb(source), 'projection') OR
          proof.version_digest IS DISTINCT FROM
            public.durable_payload_digest_part('#{table}', to_jsonb(source), 'version') OR
          proof.purge_digest IS DISTINCT FROM
            public.durable_payload_digest_part('#{table}', to_jsonb(source), 'purge')
        )
      ORDER BY #{order}
      LIMIT $1
    )
    SELECT *
    FROM candidates
    WHERE pg_catalog.pg_try_advisory_xact_lock(
      pg_catalog.hashtextextended('#{table}:' || advisory_identity, 0)
    )
    """
  end

  defp store_sql(table) do
    {:ok, source} = DurablePayloadRegistry.fetch(table)
    identity_expression = source.identity_sql

    """
    WITH current_source AS MATERIALIZED (
      SELECT
        public.durable_payload_row_identity('#{table}', #{identity_expression}) AS row_identity
      FROM public.#{table} AS source
      WHERE public.durable_payload_row_identity('#{table}', #{identity_expression}) = $1
        AND public.durable_payload_digest_part('#{table}', to_jsonb(source), 'ciphertext') = $3::bytea
        AND public.durable_payload_digest_part('#{table}', to_jsonb(source), 'projection') = $4::bytea
        AND public.durable_payload_digest_part('#{table}', to_jsonb(source), 'version') = $5::bytea
        AND public.durable_payload_digest_part('#{table}', to_jsonb(source), 'purge') = $6::bytea
    ), deleted AS (
      DELETE FROM public.durable_payload_verifications AS proof
      USING current_source
      WHERE proof.payload_table = '#{table}'
        AND proof.row_identity = current_source.row_identity
    )
    INSERT INTO public.durable_payload_verifications (
      payload_table, row_identity, ciphertext_digest, projection_digest,
      version_digest, purge_digest, key_tags, verified_at
    )
    SELECT
      '#{table}', row_identity, $3::bytea, $4::bytea, $5::bytea, $6::bytea,
      $2::text[], timezone('UTC', clock_timestamp())
    FROM current_source
    """
  end

  defp failure_store_sql(table) do
    {:ok, source} = DurablePayloadRegistry.fetch(table)
    identity_expression = source.identity_sql

    """
    WITH current_source AS MATERIALIZED (
      SELECT
        public.durable_payload_row_identity('#{table}', #{identity_expression}) AS row_identity
      FROM public.#{table} AS source
      WHERE public.durable_payload_row_identity('#{table}', #{identity_expression}) = $1
        AND public.durable_payload_digest_part('#{table}', to_jsonb(source), 'ciphertext') = $3::bytea
        AND public.durable_payload_digest_part('#{table}', to_jsonb(source), 'projection') = $4::bytea
        AND public.durable_payload_digest_part('#{table}', to_jsonb(source), 'version') = $5::bytea
        AND public.durable_payload_digest_part('#{table}', to_jsonb(source), 'purge') = $6::bytea
    )
    INSERT INTO public.durable_payload_verification_failures (
      payload_table, row_identity, failure_class, ciphertext_digest,
      projection_digest, version_digest, purge_digest, failed_at
    )
    SELECT
      '#{table}', row_identity, $2, $3::bytea, $4::bytea, $5::bytea, $6::bytea,
      timezone('UTC', clock_timestamp())
    FROM current_source
    ON CONFLICT (payload_table, row_identity) DO UPDATE SET
      failure_class = EXCLUDED.failure_class,
      ciphertext_digest = EXCLUDED.ciphertext_digest,
      projection_digest = EXCLUDED.projection_digest,
      version_digest = EXCLUDED.version_digest,
      purge_digest = EXCLUDED.purge_digest,
      failed_at = EXCLUDED.failed_at
    """
  end

  defp limit(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:limit, :max_batches, :tables])) do
      case Keyword.get(opts, :limit, @default_limit) do
        value when is_integer(value) and value in 1..@max_limit -> {:ok, value}
        _invalid -> {:error, :invalid_durable_payload_verification_options}
      end
    else
      {:error, :invalid_durable_payload_verification_options}
    end
  end

  defp max_batches(opts) do
    case Keyword.get(opts, :max_batches, 20) do
      value when is_integer(value) and value in 1..1_000 -> {:ok, value}
      _invalid -> {:error, :invalid_durable_payload_verification_options}
    end
  end

  defp selected_tables(opts) do
    case Keyword.get(opts, :tables, @tables) do
      tables when is_list(tables) ->
        if tables != [] and Enum.all?(tables, &(&1 in @tables)),
          do: {:ok, Enum.uniq(tables)},
          else: {:error, :invalid_durable_payload_verification_options}

      _invalid ->
        {:error, :invalid_durable_payload_verification_options}
    end
  end
end
