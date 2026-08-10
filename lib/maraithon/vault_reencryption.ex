defmodule Maraithon.VaultReencryption do
  @moduledoc """
  Bounded, resumable global Vault re-encryption and old-tag retirement proof.

  Every query is built from `Maraithon.VaultCiphertextRegistry`; caller table
  names never become SQL. Rows are locked with `FOR UPDATE SKIP LOCKED`, and
  reports contain only target names, counts, closed failure classes, and a
  SHA-256 row-reference digest.
  """

  alias Maraithon.Repo
  alias Maraithon.Vault
  alias Maraithon.VaultCiphertextRegistry

  @default_limit 25
  @max_limit 100
  @default_max_batches 20
  @max_batches 1_000

  @doc "Counts an old tag across every Vault-encrypted column in PostgreSQL."
  def preflight(old_tag) do
    with {:ok, prefix} <- tag_prefix(old_tag) do
      counts =
        Enum.map(VaultCiphertextRegistry.all(), fn target ->
          %{rows: [[count, oversized]]} =
            Repo.query!(
              """
              SELECT COUNT(*),
                     COUNT(*) FILTER (WHERE octet_length(#{target.column}) > $3)
              FROM public.#{target.table}
              WHERE #{target.column} IS NOT NULL
                AND substring(#{target.column} FROM 1 FOR $1) = $2
              """,
              [byte_size(prefix), prefix, target.max_bytes],
              log: false
            )

          %{
            table: target.table,
            column: target.column,
            old_tag_rows: count,
            oversized_rows: oversized
          }
        end)

      {:ok,
       %{
         old_tag: old_tag,
         total: Enum.sum(Enum.map(counts, & &1.old_tag_rows)),
         oversized: Enum.sum(Enum.map(counts, & &1.oversized_rows)),
         targets: counts
       }}
    end
  rescue
    _error -> {:error, :vault_old_tag_preflight_failed}
  catch
    :exit, _reason -> {:error, :vault_old_tag_preflight_failed}
  end

  @doc "Succeeds only when the old tag count is globally zero."
  def retirement_preflight(old_tag) do
    case preflight(old_tag) do
      {:ok, %{total: 0, oversized: 0} = report} -> {:ok, report}
      {:ok, report} -> {:error, {:vault_old_tag_still_present, report}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Re-encrypts bounded locked batches from one configured old read tag."
  def reencrypt(old_tag, opts \\ [])

  def reencrypt(old_tag, opts) when is_list(opts) do
    with :ok <- validate_old_tag(old_tag),
         {:ok, limit} <- bounded_option(opts, :limit, @default_limit, 1..@max_limit),
         {:ok, max_batches} <-
           bounded_option(opts, :max_batches, @default_max_batches, 1..@max_batches),
         {:ok, targets} <- selected_targets(opts) do
      state = %{batches: 0, reencrypted: 0, failures: []}
      run_rounds(old_tag, targets, limit, max_batches, state)
    end
  end

  def reencrypt(_old_tag, _opts), do: {:error, :invalid_vault_reencryption_options}

  defp run_rounds(_old_tag, _targets, _limit, 0, state), do: {:ok, state}

  defp run_rounds(old_tag, targets, limit, remaining, state) do
    result =
      Enum.reduce_while(targets, {:ok, state, 0}, fn target, {:ok, acc, progressed} ->
        case reencrypt_batch(old_tag, target, limit) do
          {:ok, batch} ->
            next = %{
              batches: acc.batches + 1,
              reencrypted: acc.reencrypted + batch.reencrypted,
              failures: acc.failures ++ batch.failures
            }

            {:cont, {:ok, next, progressed + batch.reencrypted + length(batch.failures)}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, next, 0} -> {:ok, next}
      {:ok, next, _progressed} -> run_rounds(old_tag, targets, limit, remaining - 1, next)
      {:error, _reason} = error -> error
    end
  end

  defp reencrypt_batch(old_tag, target, limit) do
    with {:ok, prefix} <- tag_prefix(old_tag) do
      case Repo.transaction(fn -> reencrypt_locked(old_tag, prefix, target, limit) end,
             timeout: 120_000
           ) do
        {:ok, report} -> {:ok, report}
        {:error, _reason} -> {:error, :vault_reencryption_failed}
      end
    end
  rescue
    _error -> {:error, :vault_reencryption_failed}
  catch
    :exit, _reason -> {:error, :vault_reencryption_failed}
  end

  defp reencrypt_locked(old_tag, prefix, target, limit) do
    Repo.query!("SET LOCAL ROLE maraithon_incident_operator", [], log: false)

    %{rows: [["maraithon_incident_operator"]]} =
      Repo.query!("SELECT current_user", [], log: false)

    Repo.query!(
      "SELECT set_config('maraithon.vault_reencryption', 'VAULT_REENCRYPT_V1', true)",
      [],
      log: false
    )

    Repo.query!(
      "SELECT set_config('maraithon.effect_writer_protocol', 'generation_fenced_v1', true)",
      [],
      log: false
    )

    oversized = oversized_candidates(prefix, target, limit)

    oversized_report =
      Enum.reduce(oversized, empty_report(target), fn [row_identity, row_ref, digest], acc ->
        store_rotation_failure!(target, row_identity, digest, :oversized)
        %{acc | failures: [%{row_ref: row_ref, failure: :oversized} | acc.failures]}
      end)

    remaining = limit - length(oversized)

    rows =
      if remaining > 0,
        do: rotation_candidates(prefix, target, remaining),
        else: []

    Enum.reduce(rows, oversized_report, fn
      [ctid, row_identity, row_ref, digest, ciphertext], acc ->
        case reencrypt_ciphertext(old_tag, ciphertext, target.max_bytes) do
          {:ok, replacement} ->
            case Repo.query!(
                   """
                   UPDATE public.#{target.table}
                   SET #{target.column} = $1
                   WHERE ctid = $2::tid AND #{target.column} = $3
                   """,
                   [replacement, ctid, ciphertext],
                   log: false
                 ).num_rows do
              1 ->
                delete_rotation_failure!(target, row_identity)
                %{acc | reencrypted: acc.reencrypted + 1}

              0 ->
                %{acc | failures: [%{row_ref: row_ref, failure: :source_changed} | acc.failures]}
            end

          {:error, failure} ->
            store_rotation_failure!(target, row_identity, digest, failure)
            %{acc | failures: [%{row_ref: row_ref, failure: failure} | acc.failures]}
        end
    end)
    |> Map.update!(:failures, &Enum.reverse/1)
  end

  defp empty_report(target),
    do: %{target: "#{target.table}.#{target.column}", reencrypted: 0, failures: []}

  defp oversized_candidates(prefix, target, limit) do
    Repo.query!(
      """
      SELECT source.id::text,
             encode(public.digest(pg_catalog.convert_to(
               '#{target.table}:#{target.column}:' || source.id::text, 'UTF8'), 'sha256'), 'hex'),
             public.digest(source.#{target.column}, 'sha256')
      FROM public.#{target.table} AS source
      LEFT JOIN public.vault_reencryption_failures AS failure
        ON failure.payload_table = '#{target.table}'
       AND failure.payload_column = '#{target.column}'
       AND failure.row_identity = source.id::text
       AND failure.ciphertext_digest = public.digest(source.#{target.column}, 'sha256')
      WHERE source.#{target.column} IS NOT NULL
        AND substring(source.#{target.column} FROM 1 FOR $1) = $2
        AND octet_length(source.#{target.column}) > $3
        AND failure.row_identity IS NULL
      ORDER BY source.id
      LIMIT $4
      FOR UPDATE OF source SKIP LOCKED
      """,
      [byte_size(prefix), prefix, target.max_bytes, limit],
      log: false
    ).rows
  end

  defp rotation_candidates(prefix, target, limit) do
    Repo.query!(
      """
      SELECT source.ctid::text,
             source.id::text,
             encode(public.digest(pg_catalog.convert_to(
               '#{target.table}:#{target.column}:' || source.id::text, 'UTF8'), 'sha256'), 'hex'),
             public.digest(source.#{target.column}, 'sha256'),
             source.#{target.column}
      FROM public.#{target.table} AS source
      LEFT JOIN public.vault_reencryption_failures AS failure
        ON failure.payload_table = '#{target.table}'
       AND failure.payload_column = '#{target.column}'
       AND failure.row_identity = source.id::text
       AND failure.ciphertext_digest = public.digest(source.#{target.column}, 'sha256')
      WHERE source.#{target.column} IS NOT NULL
        AND substring(source.#{target.column} FROM 1 FOR $1) = $2
        AND octet_length(source.#{target.column}) <= $3
        AND failure.row_identity IS NULL
      ORDER BY source.id
      LIMIT $4
      FOR UPDATE OF source SKIP LOCKED
      """,
      [byte_size(prefix), prefix, target.max_bytes, limit],
      log: false
    ).rows
  end

  defp store_rotation_failure!(target, row_identity, digest, failure) do
    Repo.query!(
      """
      INSERT INTO public.vault_reencryption_failures (
        payload_table, payload_column, row_identity, ciphertext_digest,
        failure_class, failed_at
      ) VALUES ($1, $2, $3, $4, $5, timezone('UTC', clock_timestamp()))
      ON CONFLICT (payload_table, payload_column, row_identity) DO UPDATE SET
        ciphertext_digest = EXCLUDED.ciphertext_digest,
        failure_class = EXCLUDED.failure_class,
        failed_at = EXCLUDED.failed_at
      """,
      [target.table, target.column, row_identity, digest, Atom.to_string(failure)],
      log: false
    )

    :ok
  end

  defp delete_rotation_failure!(target, row_identity) do
    Repo.query!(
      """
      DELETE FROM public.vault_reencryption_failures
      WHERE payload_table = $1 AND payload_column = $2 AND row_identity = $3
      """,
      [target.table, target.column, row_identity],
      log: false
    )

    :ok
  end

  defp reencrypt_ciphertext(old_tag, ciphertext, max_bytes) do
    with {:ok, ^old_tag} <- Vault.ciphertext_key_tag(ciphertext),
         {:ok, plaintext} when is_binary(plaintext) <- Vault.decrypt(ciphertext),
         true <- byte_size(plaintext) <= max_bytes,
         {:ok, replacement} <- Vault.encrypt(plaintext),
         {:ok, current_tag} <- Vault.ciphertext_key_tag(replacement),
         true <- current_tag == Vault.current_key_tag() do
      {:ok, replacement}
    else
      false -> {:error, :plaintext_oversized}
      {:ok, _other_tag} -> {:error, :key_tag_mismatch}
      _error -> {:error, :authentication_failed}
    end
  rescue
    _error -> {:error, :authentication_failed}
  end

  defp validate_old_tag(old_tag) when is_binary(old_tag) do
    cond do
      old_tag == Vault.current_key_tag() ->
        {:error, :current_vault_tag_cannot_be_retired}

      old_tag not in Vault.configured_key_tags() ->
        {:error, :vault_read_key_unavailable}

      true ->
        tag_prefix(old_tag)
        |> then(fn
          {:ok, _prefix} -> :ok
          error -> error
        end)
    end
  end

  defp validate_old_tag(_old_tag), do: {:error, :invalid_vault_key_tag}

  defp tag_prefix(tag) do
    {:ok, Vault.tag_prefix(tag)}
  rescue
    _error -> {:error, :invalid_vault_key_tag}
  end

  defp bounded_option(opts, key, default, range) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:limit, :max_batches, :target])) do
      case Keyword.get(opts, key, default) do
        value when is_integer(value) ->
          if value in range,
            do: {:ok, value},
            else: {:error, :invalid_vault_reencryption_options}

        _invalid ->
          {:error, :invalid_vault_reencryption_options}
      end
    else
      {:error, :invalid_vault_reencryption_options}
    end
  end

  defp selected_targets(opts) do
    case Keyword.get(opts, :target) do
      nil ->
        {:ok, VaultCiphertextRegistry.all()}

      {table, column} ->
        case VaultCiphertextRegistry.fetch(table, column) do
          {:ok, target} -> {:ok, [target]}
          :error -> {:error, :invalid_vault_reencryption_target}
        end

      _invalid ->
        {:error, :invalid_vault_reencryption_target}
    end
  end
end
