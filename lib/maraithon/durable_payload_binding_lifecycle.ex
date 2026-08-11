defmodule Maraithon.DurablePayloadBindingLifecycle do
  @moduledoc false

  alias Maraithon.DurablePayload
  alias Maraithon.DurablePayloadBinding
  alias Maraithon.DurablePayloadRegistry
  alias Maraithon.Repo
  alias Maraithon.Vault

  @operation_kinds %{
    rebind: "legacy_context_rebind_v1",
    rotate: "binding_key_rotation_v1"
  }

  @doc false
  def targets, do: DurablePayloadRegistry.binding_targets()

  @doc false
  def run_target_batch(target, mode, limit, evidence)
      when mode in [:rebind, :rotate] and is_integer(limit) and limit > 0 and is_map(evidence) do
    target_tag = DurablePayloadBinding.current_key_tag()
    operation_kind = Map.fetch!(@operation_kinds, mode)
    old_tag = Map.get(evidence, :old_tag)

    oversized =
      Repo.query!(
        candidate_sql(target, mode, :oversized),
        candidate_params(mode, limit, target_tag, old_tag),
        log: false
      ).rows

    oversized_report =
      Enum.reduce(oversized, empty_report(target), fn
        [row_identity, row_ref, source_digest], report ->
          store_operation!(
            operation_kind,
            target,
            row_identity,
            source_digest,
            target_tag,
            :failed,
            :oversized,
            evidence
          )

          add_failure(report, row_ref, :oversized)
      end)

    remaining = limit - length(oversized)

    rows =
      if remaining > 0 do
        Repo.query!(
          candidate_sql(target, mode, :normal),
          candidate_params(mode, remaining, target_tag, old_tag),
          log: false
        ).rows
      else
        []
      end

    Enum.reduce(rows, oversized_report, fn row, report ->
      process_row(target, mode, target_tag, operation_kind, evidence, row, report)
    end)
    |> Map.update!(:failures, &Enum.reverse/1)
  end

  @doc false
  def old_tag_counts(old_tag) when is_binary(old_tag) do
    Enum.map(targets(), fn target ->
      %{rows: [[count]]} =
        Repo.query!(
          "SELECT COUNT(*) FROM public.#{target.table} " <>
            "WHERE #{target.binding_key_tag_column} = $1",
          [old_tag],
          log: false
        )

      %{
        table: target.table,
        binding: target.binding_name,
        old_tag_rows: count
      }
    end)
  end

  @doc false
  def lock_source_tables! do
    Repo.query!("SELECT public.lock_durable_payload_binding_sources()", [], log: false)
    :ok
  end

  @doc false
  def validate_evidence(opts) when is_list(opts) do
    id = Keyword.get(opts, :evidence_id)
    digest = Keyword.get(opts, :evidence_digest)
    operator = Keyword.get(opts, :operator)
    revision = Keyword.get(opts, :revision)

    if Keyword.keyword?(opts) and is_binary(id) and byte_size(id) in 1..128 and
         Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/, id) and
         is_binary(digest) and byte_size(digest) == 32 and is_binary(operator) and
         byte_size(operator) in 1..320 and operator == String.trim(operator) and
         is_binary(revision) and Regex.match?(~r/^[0-9a-f]{40}([0-9a-f]{24})?$/, revision) do
      {:ok, %{id: id, digest: digest, operator: operator, revision: revision}}
    else
      {:error, :payload_lifecycle_evidence_required}
    end
  end

  def validate_evidence(_opts), do: {:error, :payload_lifecycle_evidence_required}

  @doc false
  def lock_exact_protocol! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "payload lifecycle protocol fence requires a transaction")

    runtime_row =
      case Repo.query!(
             """
             SELECT mode, activation_evidence_id, activation_evidence_digest,
                    activated_by, exact_revision
             FROM public.runtime_coordination_protocols
             WHERE name = 'runtime'
             FOR SHARE
             """,
             [],
             log: false
           ).rows do
        [row] -> row
        [] -> Repo.rollback(:runtime_coordination_protocol_missing)
      end

    effect_row =
      case Repo.query!(
             """
             SELECT mode, activation_evidence_id, activation_evidence_digest,
                    activated_by, exact_revision
             FROM public.effect_execution_protocols
             WHERE name = 'effects'
             FOR SHARE
             """,
             [],
             log: false
           ).rows do
        [row] -> row
        [] -> Repo.rollback(:effect_execution_protocol_missing)
      end

    case {runtime_row, effect_row} do
      {
        ["partition_fenced_v1", id, digest, operator, revision],
        ["generation_fenced_v1", id, digest, operator, revision]
      }
      when is_binary(id) and is_binary(digest) and byte_size(digest) == 32 and
             is_binary(operator) and is_binary(revision) ->
        %{id: id, digest: digest, operator: operator, revision: revision}

      _mismatch ->
        Repo.rollback(:payload_lifecycle_protocol_pair_mismatch)
    end
  end

  @doc false
  def verify_protocol_evidence!(evidence) when is_map(evidence) do
    case lock_exact_protocol!() do
      %{id: id, digest: digest, operator: operator, revision: revision}
      when id == evidence.id and digest == evidence.digest and operator == evidence.operator and
             revision == evidence.revision ->
        :ok

      _mismatch ->
        Repo.rollback(:payload_lifecycle_evidence_mismatch)
    end
  end

  defp process_row(target, mode, target_tag, operation_kind, evidence, row, report) do
    parsed = parse_row(target, row)
    result = process_row_with_savepoint(target, mode, target_tag, parsed)

    case result do
      {:ok, :already_current, digest} ->
        store_operation!(
          operation_kind,
          target,
          parsed.row_identity,
          digest,
          target_tag,
          :already_current,
          nil,
          evidence
        )

        %{report | already_current: report.already_current + 1}

      {:ok, :migrated, digest} ->
        store_operation!(
          operation_kind,
          target,
          parsed.row_identity,
          digest,
          target_tag,
          :migrated,
          nil,
          evidence
        )

        %{report | migrated: report.migrated + 1}

      {:error, failure} ->
        failure = closed_failure(failure)

        store_operation!(
          operation_kind,
          target,
          parsed.row_identity,
          parsed.source_digest,
          target_tag,
          :failed,
          failure,
          evidence
        )

        add_failure(report, parsed.row_ref, failure)
    end
  end

  defp process_row_with_savepoint(target, mode, target_tag, parsed) do
    case Repo.transaction(
           fn ->
             with :ok <- validate_unpurged(parsed),
                  {:ok, fields} <- decrypt_fields(target.fields, parsed.ciphertexts),
                  {:ok, action} <- binding_action(target, parsed, fields, mode, target_tag) do
               apply_action(target, parsed, fields, action)
             end
           end,
           mode: :savepoint
         ) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :payload_schema_invalid}
    end
  rescue
    _error -> {:error, :payload_schema_invalid}
  catch
    :exit, _reason -> {:error, :payload_schema_invalid}
  end

  defp parse_row(target, [ctid, row_identity, row_ref, source_digest, purged_at | values]) do
    identity_count = length(target.identity)
    scope_count = length(target.scope)
    field_count = length(target.fields)
    {identity_values, values} = Enum.split(values, identity_count)
    {scope_values, values} = Enum.split(values, scope_count)
    {ciphertexts, values} = Enum.split(values, field_count)

    case values do
      [binding_version, binding_key_tag, binding_mac] ->
        %{
          ctid: ctid,
          row_identity: row_identity,
          row_ref: row_ref,
          source_digest: source_digest,
          purged_at: purged_at,
          identity_values: identity_values,
          scope_values: scope_values,
          ciphertexts: ciphertexts,
          binding: {binding_version, binding_key_tag, binding_mac}
        }

      _invalid ->
        raise ArgumentError, "invalid fixed binding candidate shape"
    end
  end

  defp validate_unpurged(%{purged_at: nil}), do: :ok

  defp validate_unpurged(%{ciphertexts: ciphertexts, binding: {nil, nil, nil}}) do
    if Enum.all?(ciphertexts, &is_nil/1),
      do: {:error, :source_changed},
      else: {:error, :purge_marker_inconsistent}
  end

  defp validate_unpurged(_parsed), do: {:error, :purge_marker_inconsistent}

  defp decrypt_fields(fields, ciphertexts) do
    fields
    |> Enum.zip(ciphertexts)
    |> Enum.reduce_while({:ok, []}, fn
      {{name, _column, _type, _max_bytes, false}, nil}, {:ok, values} ->
        {:cont, {:ok, [{Atom.to_string(name), nil} | values]}}

      {{_name, _column, _type, _max_bytes, true}, nil}, _acc ->
        {:halt, {:error, :ciphertext_missing}}

      {{name, _column, type, max_bytes, _required}, ciphertext}, {:ok, values}
      when is_binary(ciphertext) ->
        case decrypt_field(type, ciphertext, max_bytes) do
          {:ok, value} -> {:cont, {:ok, [{Atom.to_string(name), value} | values]}}
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid, _acc ->
        {:halt, {:error, :payload_schema_invalid}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp decrypt_field(type, ciphertext, max_bytes) do
    with true <- byte_size(ciphertext) <= max_bytes,
         {:ok, plaintext} when is_binary(plaintext) <- Vault.decrypt(ciphertext),
         true <- byte_size(plaintext) <= max_bytes do
      decode_plaintext(type, plaintext, max_bytes)
    else
      false -> {:error, :oversized}
      _invalid -> {:error, :authentication_failed}
    end
  rescue
    _error -> {:error, :authentication_failed}
  catch
    _kind, _reason -> {:error, :authentication_failed}
  end

  defp decode_plaintext(:binary, plaintext, _max_bytes) do
    if String.valid?(plaintext) and :binary.match(plaintext, <<0>>) == :nomatch,
      do: {:ok, plaintext},
      else: {:error, :payload_schema_invalid}
  end

  defp decode_plaintext(:map, plaintext, max_bytes) do
    with {:ok, value} when is_map(value) and not is_struct(value) <- Jason.decode(plaintext),
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= max_bytes do
      {:ok, value}
    else
      _invalid -> {:error, :payload_schema_invalid}
    end
  end

  defp binding_action(target, parsed, fields, mode, target_tag) do
    typed_identity = typed_identity(target, parsed.identity_values)
    typed_scope = DurablePayload.context_identity(parsed.scope_values)
    {version, key_tag, mac} = parsed.binding

    cond do
      {version, key_tag, mac} == {nil, nil, nil} and mode == :rebind ->
        {:ok,
         {:replace,
          DurablePayloadBinding.sign(target.binding_table, typed_identity, typed_scope, fields)}}

      {version, key_tag, mac} == {nil, nil, nil} ->
        {:error, :binding_incomplete}

      is_nil(version) or not is_binary(key_tag) or not is_binary(mac) ->
        {:error, :binding_incomplete}

      mode == :rotate and key_tag == target_tag ->
        {:ok, :already_current}

      true ->
        case DurablePayloadBinding.verify(
               target.binding_table,
               typed_identity,
               typed_scope,
               fields,
               version,
               key_tag,
               mac
             ) do
          :ok when mode == :rebind ->
            {:ok, :already_current}

          :ok when mode == :rotate ->
            {:ok,
             {:replace,
              DurablePayloadBinding.sign(
                target.binding_table,
                typed_identity,
                typed_scope,
                fields
              )}}

          {:error, :binding_mismatch} when mode == :rebind ->
            verify_legacy_and_replace(target, parsed, fields, version, key_tag, mac)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp verify_legacy_and_replace(target, parsed, fields, version, key_tag, mac) do
    legacy_identity = legacy_identity(target, parsed.identity_values)
    legacy_scope = DurablePayload.legacy_context_identity(parsed.scope_values)

    case DurablePayloadBinding.verify(
           target.binding_table,
           legacy_identity,
           legacy_scope,
           fields,
           version,
           key_tag,
           mac
         ) do
      :ok ->
        {:ok,
         {:replace,
          DurablePayloadBinding.sign(
            target.binding_table,
            typed_identity(target, parsed.identity_values),
            DurablePayload.context_identity(parsed.scope_values),
            fields
          )}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_action(_target, parsed, _fields, :already_current),
    do: {:ok, :already_current, parsed.source_digest}

  defp apply_action(target, parsed, _fields, {:replace, binding}) do
    case Repo.query!(
           update_sql(target),
           [binding.version, binding.key_tag, binding.mac, parsed.ctid, parsed.source_digest],
           log: false
         ).rows do
      [[post_digest]] -> {:ok, :migrated, post_digest}
      [] -> {:error, :source_changed}
    end
  end

  defp typed_identity(%{identity_encoding: :scalar}, [identity]) when is_binary(identity),
    do: identity

  defp typed_identity(_target, values), do: DurablePayload.context_identity(values)

  defp legacy_identity(%{identity_encoding: :scalar}, [identity]) when is_binary(identity),
    do: identity

  defp legacy_identity(_target, values), do: DurablePayload.legacy_context_identity(values)

  defp empty_report(target) do
    %{
      table: target.table,
      binding: target.binding_name,
      migrated: 0,
      already_current: 0,
      failures: []
    }
  end

  defp add_failure(report, row_ref, failure),
    do: %{report | failures: [%{row_ref: row_ref, failure: failure} | report.failures]}

  defp closed_failure(failure)
       when failure in [
              :oversized,
              :ciphertext_missing,
              :authentication_failed,
              :payload_schema_invalid,
              :binding_incomplete,
              :binding_mismatch,
              :binding_key_unavailable,
              :source_changed,
              :purge_marker_inconsistent
            ],
       do: failure

  defp closed_failure(_failure), do: :payload_schema_invalid

  defp candidate_params(:rebind, limit, target_tag, _old_tag), do: [limit, target_tag]
  defp candidate_params(:rotate, limit, target_tag, old_tag), do: [limit, target_tag, old_tag]

  defp candidate_sql(target, mode, size_class) do
    operation_kind = Map.fetch!(@operation_kinds, mode)
    source_digest = source_digest_sql(target)
    identity = target.identity_sql
    row_identity = "public.durable_payload_row_identity('#{target.table}', #{identity})"

    identity_values = Enum.map(target.identity, &context_sql(target.table, &1))
    scope_values = Enum.map(target.scope, &context_sql(target.table, &1))

    ciphertexts =
      Enum.map(target.fields, fn {_name, column, _type, _max_bytes, _required} ->
        "source.#{column}"
      end)

    oversized =
      target.fields
      |> Enum.map(fn {_name, column, _type, max_bytes, _required} ->
        "octet_length(source.#{column}) > #{max_bytes}"
      end)
      |> Enum.join(" OR ")

    sizes =
      target.fields
      |> Enum.map(fn {_name, column, _type, max_bytes, _required} ->
        "(source.#{column} IS NULL OR octet_length(source.#{column}) <= #{max_bytes})"
      end)
      |> Enum.join(" AND ")

    size_filter = if size_class == :oversized, do: "(#{oversized})", else: sizes

    mode_filter =
      case mode do
        :rebind ->
          """
          (
            source.#{target.purge} IS NULL OR
            source.#{target.binding_version_column} IS NOT NULL OR
            source.#{target.binding_key_tag_column} IS NOT NULL OR
            source.#{target.binding_mac_column} IS NOT NULL OR
            #{Enum.map_join(target.fields, " OR ", fn {_n, c, _t, _m, _r} -> "source.#{c} IS NOT NULL" end)}
          )
          """

        :rotate ->
          "source.#{target.purge} IS NULL AND source.#{target.binding_key_tag_column} = $3"
      end

    selected_payload =
      if size_class == :oversized do
        ""
      else
        ([
           "source.ctid::text",
           row_identity,
           "encode(public.digest(pg_catalog.convert_to('#{target.table}:#{target.binding_name}:' || #{row_identity}, 'UTF8'), 'sha256'), 'hex')",
           source_digest,
           "source.#{target.purge}"
         ] ++
           identity_values ++
           scope_values ++
           ciphertexts ++
           [
             "source.#{target.binding_version_column}",
             "source.#{target.binding_key_tag_column}",
             "source.#{target.binding_mac_column}"
           ])
        |> Enum.join(",\n             ")
      end

    select =
      if size_class == :oversized do
        """
        #{row_identity},
        encode(public.digest(pg_catalog.convert_to(
          '#{target.table}:#{target.binding_name}:' || #{row_identity}, 'UTF8'
        ), 'sha256'), 'hex'),
        #{source_digest}
        """
      else
        selected_payload
      end

    """
    SELECT #{select}
    FROM public.#{target.table} AS source
    LEFT JOIN public.durable_payload_binding_operations AS progress
      ON progress.operation_kind = '#{operation_kind}'
     AND progress.payload_table = '#{target.table}'
     AND progress.binding_name = '#{target.binding_name}'
     AND progress.row_identity = #{row_identity}
     AND progress.target_key_tag = $2
     AND progress.source_digest = #{source_digest}
    WHERE progress.row_identity IS NULL
      AND #{mode_filter}
      AND #{size_filter}
    ORDER BY #{target.order_sql}
    LIMIT $1
    FOR UPDATE OF source SKIP LOCKED
    """
  end

  defp update_sql(target) do
    digest = source_digest_sql(target)

    """
    UPDATE public.#{target.table} AS source
    SET #{target.binding_version_column} = $1,
        #{target.binding_key_tag_column} = $2,
        #{target.binding_mac_column} = $3
    WHERE source.ctid = $4::tid
      AND #{digest} = $5
    RETURNING #{digest}
    """
  end

  defp source_digest_sql(target) do
    identity_values = Enum.map(target.identity, &context_sql(target.table, &1))
    scope_values = Enum.map(target.scope, &context_sql(target.table, &1))

    values =
      [
        "'maraithon:durable-payload-binding-source:v1'",
        "'#{target.table}'",
        "'#{target.binding_name}'",
        "public.durable_payload_digest_part('#{target.table}', to_jsonb(source), 'ciphertext')",
        "public.durable_payload_digest_part('#{target.table}', to_jsonb(source), 'purge')"
      ] ++
        identity_values ++
        scope_values ++
        [
          "source.#{target.binding_version_column}",
          "source.#{target.binding_key_tag_column}",
          "source.#{target.binding_mac_column}"
        ]

    "public.digest(pg_catalog.convert_to(jsonb_build_array(#{Enum.join(values, ", ")})::text, 'UTF8'), 'sha256')"
  end

  defp context_sql("snapshots", field) when field in [:id, :sequence_num, :schema_version],
    do: "source.#{field}"

  defp context_sql(_table, field), do: "source.#{field}::text"

  defp store_operation!(
         operation_kind,
         target,
         row_identity,
         source_digest,
         target_tag,
         status,
         failure,
         evidence
       ) do
    Repo.query!(
      """
      INSERT INTO public.durable_payload_binding_operations (
        operation_kind, payload_table, binding_name, row_identity, source_digest,
        target_key_tag, status, failure_class, evidence_id, evidence_digest,
        evidence_operator, exact_revision, attempted_at
      ) VALUES (
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
        timezone('UTC', clock_timestamp())
      )
      ON CONFLICT (operation_kind, payload_table, binding_name, row_identity, target_key_tag)
      DO UPDATE SET source_digest = EXCLUDED.source_digest,
                    status = EXCLUDED.status,
                    failure_class = EXCLUDED.failure_class,
                    evidence_id = EXCLUDED.evidence_id,
                    evidence_digest = EXCLUDED.evidence_digest,
                    evidence_operator = EXCLUDED.evidence_operator,
                    exact_revision = EXCLUDED.exact_revision,
                    attempted_at = EXCLUDED.attempted_at
      """,
      [
        operation_kind,
        target.table,
        target.binding_name,
        row_identity,
        source_digest,
        target_tag,
        Atom.to_string(status),
        if(failure, do: Atom.to_string(failure), else: nil),
        evidence.id,
        evidence.digest,
        evidence.operator,
        evidence.revision
      ],
      log: false
    )

    :ok
  end
end
