defmodule Maraithon.DurablePayloadVerification do
  @moduledoc """
  Bounded, resumable authenticated verification of encrypted durable payloads.

  Candidate rows are selected with `FOR UPDATE SKIP LOCKED`. Ciphertext is
  decrypted and schema/bounds checked through `Maraithon.Vault`; only then does
  PostgreSQL compute and store content-free ciphertext, projection, version,
  and purge digests while the source row lock is still held. Results contain
  row identity and closed failure classes only.

  New durable-copy tables extend this module with one fixed SQL candidate/store
  pair and a `validate_row/2` clause, then attach the common invalidation
  trigger and activation manifest entry.
  """

  alias Maraithon.DurablePayload
  alias Maraithon.DurablePayloadBinding
  alias Maraithon.Effects
  alias Maraithon.Repo
  alias Maraithon.Vault

  @tables ~w(effects agent_directives events agent_run_steps)
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
             fn -> verify_locked_batch(payload_table, limit) end,
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

          {:cont, {:ok, next, progressed + batch.verified}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp verify_locked_batch(payload_table, limit) do
    rows = Repo.query!(candidate_sql(payload_table), [limit], log: false).rows

    Enum.reduce(rows, %{table: payload_table, verified: 0, failures: []}, fn row, acc ->
      id = hd(row)
      row_identity = Enum.at(row, 1)

      case safely_validate_row(payload_table, row) do
        {:ok, verification} ->
          maybe_store_binding!(payload_table, id, verification.binding)
          store_proof!(payload_table, id, row_identity, verification.key_tags)
          %{acc | verified: acc.verified + 1}

        {:error, failure} ->
          store_failure!(payload_table, row_identity, failure)
          %{acc | failures: [%{id: id, failure: failure} | acc.failures]}
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
         sequence_num,
         _row_identity,
         ciphertext,
         projection,
         1,
         nil,
         agent_id,
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

  defp ciphertext_tag(ciphertext) do
    case Cloak.Tags.Decoder.decode(ciphertext) do
      %{tag: tag} when is_binary(tag) and byte_size(tag) in 1..64 -> {:ok, tag}
      _invalid -> {:error, :ciphertext_invalid}
    end
  rescue
    _error -> {:error, :ciphertext_invalid}
  end

  defp maybe_store_binding!(_payload_table, _source_id, nil), do: :ok

  defp maybe_store_binding!(payload_table, source_id, binding) do
    Repo.query!(
      "SELECT set_config('maraithon.effect_writer_protocol', 'generation_fenced_v1', true)",
      [],
      log: false
    )

    id_cast = if payload_table == "events", do: "bigint", else: "uuid"

    %{num_rows: 1} =
      Repo.query!(
        """
        UPDATE public.#{payload_table}
        SET payload_binding_version = $2,
            payload_binding_key_tag = $3,
            payload_binding_mac = $4
        WHERE id = $1::#{id_cast}
          AND payload_binding_version IS NULL
          AND payload_binding_key_tag IS NULL
          AND payload_binding_mac IS NULL
        """,
        [source_id, binding.version, binding.key_tag, binding.mac],
        log: false
      )

    :ok
  end

  defp store_proof!(payload_table, source_id, row_identity, key_tags) do
    set_verifier_marker!()

    Repo.query!(
      """
      DELETE FROM public.durable_payload_verifications
      WHERE payload_table = $1
        AND row_identity = public.durable_payload_row_identity($1, $2)
      """,
      [payload_table, row_identity],
      log: false
    )

    Repo.query!(store_sql(payload_table), [source_id, key_tags], log: false)
    :ok
  end

  defp store_failure!(payload_table, row_identity, failure) do
    set_verifier_marker!()

    Repo.query!(
      """
      INSERT INTO public.durable_payload_verification_failures (
        payload_table, row_identity, failure_class, failed_at
      )
      VALUES (
        $1,
        public.durable_payload_row_identity($1, $2),
        $3,
        timezone('UTC', clock_timestamp())
      )
      ON CONFLICT (payload_table, row_identity) DO NOTHING
      """,
      [payload_table, row_identity, Atom.to_string(failure)],
      log: false
    )

    :ok
  end

  defp set_verifier_marker! do
    Repo.query!(
      "SELECT set_config('maraithon.durable_payload_verifier', 'VAULT_AUTHENTICATED_V1', true)",
      [],
      log: false
    )
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
          COALESCE(source.owner_user_id, ''),
          source.payload_binding_version,
          source.payload_binding_key_tag,
          source.payload_binding_mac
        """,
        "source.payload_purged_at IS NULL OR source.params_ciphertext IS NOT NULL OR source.result_ciphertext IS NOT NULL",
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
        "source.payload_purged_at IS NULL OR source.payload_ciphertext IS NOT NULL",
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
          source.payload_binding_version,
          source.payload_binding_key_tag,
          source.payload_binding_mac
        """,
        "source.payload_purged_at IS NULL",
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
        "source.payload_purged_at IS NULL",
        "source.inserted_at, source.id"
      )

  defp candidate_sql_for(table, identity_expression, select, eligible, order) do
    """
    SELECT #{select}
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
    FOR UPDATE OF source SKIP LOCKED
    """
  end

  defp store_sql(table) do
    id_cast = if table == "events", do: "bigint", else: "uuid"

    identity_expression =
      if table == "events",
        do: "source.agent_id::text || ':' || source.sequence_num::text",
        else: "source.id::text"

    """
    INSERT INTO public.durable_payload_verifications (
      payload_table,
      row_identity,
      ciphertext_digest,
      projection_digest,
      version_digest,
      purge_digest,
      key_tags,
      verified_at
    )
    SELECT
      '#{table}',
      public.durable_payload_row_identity('#{table}', #{identity_expression}),
      public.durable_payload_digest_part('#{table}', to_jsonb(source), 'ciphertext'),
      public.durable_payload_digest_part('#{table}', to_jsonb(source), 'projection'),
      public.durable_payload_digest_part('#{table}', to_jsonb(source), 'version'),
      public.durable_payload_digest_part('#{table}', to_jsonb(source), 'purge'),
      $2::text[],
      timezone('UTC', clock_timestamp())
    FROM public.#{table} AS source
    WHERE source.id = $1::#{id_cast}
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
