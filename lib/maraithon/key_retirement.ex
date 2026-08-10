defmodule Maraithon.KeyRetirement do
  @moduledoc """
  Backup-aware retirement gates shared by Vault ciphertext and contextual
  binding keys.

  A retirement requires two temporally ordered, incident-operator-only facts:
  a PostgreSQL-clock global live-zero proof, followed by append-only catalog,
  WAL, PITR, and successful restore-drill evidence whose oldest recoverable
  point is strictly newer than that proof. Retirement always locks and recounts
  the fixed live registry; a stored proof alone can never authorize removal.
  """

  alias Maraithon.DurablePayloadBinding
  alias Maraithon.DurablePayloadBindingLifecycle, as: Lifecycle
  alias Maraithon.DurablePayloadBindingRotation
  alias Maraithon.Repo
  alias Maraithon.Vault
  alias Maraithon.VaultCiphertextRegistry
  alias Maraithon.VaultReencryption

  @kinds [:vault, :binding]

  @doc "Persists a PostgreSQL-clock proof only while the global old-tag count is zero."
  def prove_live_zero(kind, old_tag, opts)
      when kind in @kinds and is_binary(old_tag) and is_list(opts) do
    with :ok <- validate_retirable_tag(kind, old_tag),
         {:ok, evidence} <- Lifecycle.validate_evidence(opts) do
      incident_transaction(fn ->
        :ok = Lifecycle.verify_protocol_evidence!(evidence)
        lock_kind_sources!(kind)
        report = live_report!(kind, old_tag)

        if report.total != 0 do
          Repo.rollback(old_tag_present_error(kind, report.total))
        end

        source_digest = source_digest(kind, old_tag, report.targets)
        proof_id = Ecto.UUID.generate()

        Repo.query!(
          "SELECT set_config('maraithon.key_retirement_zero_proof', 'LIVE_ZERO_PROOF_V1', true)",
          [],
          log: false
        )

        Repo.query!(
          """
          INSERT INTO public.key_retirement_zero_proofs (
            key_kind, old_tag, proof_id, source_digest, evidence_id,
            evidence_digest, evidence_operator, exact_revision, proved_at
          ) VALUES (
            $1, $2, $3::uuid, $4, $5, $6, $7, $8,
            timezone('UTC', clock_timestamp())
          )
          """,
          [
            Atom.to_string(kind),
            old_tag,
            proof_id,
            source_digest,
            evidence.id,
            evidence.digest,
            evidence.operator,
            evidence.revision
          ],
          log: false
        )

        %{
          kind: kind,
          old_tag: old_tag,
          proof_id: proof_id,
          total: 0,
          registry_targets: length(report.targets),
          source_digest: Base.encode16(source_digest, case: :lower)
        }
      end)
    end
  end

  def prove_live_zero(_kind, _old_tag, _opts),
    do: {:error, :invalid_key_retirement_zero_proof}

  @doc "Appends catalog/WAL/PITR/restore evidence bound to one earlier zero proof."
  def attest_backup_evidence(kind, old_tag, opts)
      when kind in @kinds and is_binary(old_tag) and is_list(opts) do
    with {:ok, evidence} <- Lifecycle.validate_evidence(opts),
         {:ok, proof_id} <- uuid(Keyword.get(opts, :proof_id)),
         {:ok, backup} <- recovery_component(opts, :backup),
         {:ok, wal} <- recovery_component(opts, :wal),
         {:ok, pitr} <- recovery_component(opts, :pitr),
         {:ok, restore_digest} <- digest(Keyword.get(opts, :restore_drill_digest)),
         {:ok, restore_completed_at} <- datetime(Keyword.get(opts, :restore_drill_completed_at)),
         {:ok, restore_recovered_through_at} <-
           datetime(Keyword.get(opts, :restore_drill_recovered_through_at)),
         {:ok, expires_at} <- datetime(Keyword.get(opts, :evidence_expires_at)) do
      incident_transaction(fn ->
        :ok = Lifecycle.verify_protocol_evidence!(evidence)
        proof = lock_zero_proof!(kind, old_tag, proof_id, evidence)

        unless strictly_after?(backup.oldest_recoverable_at, proof.proved_at) and
                 strictly_after?(wal.oldest_recoverable_at, proof.proved_at) and
                 strictly_after?(pitr.oldest_recoverable_at, proof.proved_at) and
                 strictly_after?(restore_recovered_through_at, proof.proved_at) do
          Repo.rollback(:backup_recovery_point_not_newer_than_zero_proof)
        end

        Repo.query!(
          "SELECT set_config('maraithon.vault_backup_evidence', 'BACKUP_CATALOG_ATTESTED_V1', true)",
          [],
          log: false
        )

        evidence_id = evidence.id

        Repo.query!(
          """
          INSERT INTO public.vault_backup_retirement_evidence (
            key_kind, old_tag, zero_proof_id, evidence_id, evidence_digest,
            evidence_operator, exact_revision, oldest_recoverable_at,
            evidence_expires_at, attested_at,
            backup_catalog_digest, backup_catalog_captured_at,
            backup_oldest_recoverable_at,
            wal_catalog_digest, wal_catalog_captured_at,
            wal_oldest_recoverable_at,
            pitr_catalog_digest, pitr_catalog_captured_at,
            pitr_oldest_recoverable_at,
            restore_drill_digest, restore_drill_completed_at,
            restore_drill_recovered_through_at
          ) VALUES (
            $1, $2, $3::uuid, $4, $5, $6, $7,
            LEAST($8::timestamp, $9::timestamp, $10::timestamp),
            $11::timestamp, timezone('UTC', clock_timestamp()),
            $12, $13::timestamp, $8::timestamp,
            $14, $15::timestamp, $9::timestamp,
            $16, $17::timestamp, $10::timestamp,
            $18, $19::timestamp, $20::timestamp
          )
          """,
          [
            Atom.to_string(kind),
            old_tag,
            proof_id,
            evidence_id,
            evidence.digest,
            evidence.operator,
            evidence.revision,
            naive(backup.oldest_recoverable_at),
            naive(wal.oldest_recoverable_at),
            naive(pitr.oldest_recoverable_at),
            naive(expires_at),
            backup.digest,
            naive(backup.captured_at),
            wal.digest,
            naive(wal.captured_at),
            pitr.digest,
            naive(pitr.captured_at),
            restore_digest,
            naive(restore_completed_at),
            naive(restore_recovered_through_at)
          ],
          log: false
        )

        %{
          kind: kind,
          old_tag: old_tag,
          proof_id: proof_id,
          evidence_id: evidence_id,
          backup_catalog_digest: Base.encode16(backup.digest, case: :lower),
          wal_catalog_digest: Base.encode16(wal.digest, case: :lower),
          pitr_catalog_digest: Base.encode16(pitr.digest, case: :lower),
          restore_drill_digest: Base.encode16(restore_digest, case: :lower)
        }
      end)
    end
  end

  def attest_backup_evidence(_kind, _old_tag, _opts),
    do: {:error, :invalid_backup_retirement_evidence}

  @doc "Recounts live storage and validates unexpired post-zero recovery evidence."
  def retirement_preflight(kind, old_tag, opts)
      when kind in @kinds and is_binary(old_tag) and is_list(opts) do
    with {:ok, evidence} <- Lifecycle.validate_evidence(opts),
         {:ok, proof_id} <- uuid(Keyword.get(opts, :proof_id)),
         {:ok, evidence_id} <- bounded_evidence_id(Keyword.get(opts, :backup_evidence_id)) do
      incident_transaction(fn ->
        :ok = Lifecycle.verify_protocol_evidence!(evidence)
        lock_kind_sources!(kind)
        report = live_report!(kind, old_tag)

        if report.total != 0 do
          Repo.rollback(old_tag_present_error(kind, report.total))
        end

        expected_source_digest = source_digest(kind, old_tag, report.targets)
        proof = lock_zero_proof!(kind, old_tag, proof_id, evidence)

        if proof.source_digest != expected_source_digest do
          Repo.rollback(:key_retirement_registry_changed_since_zero_proof)
        end

        case retirement_evidence(kind, old_tag, proof_id, evidence_id, evidence) do
          {:ok, row} ->
            %{
              kind: kind,
              old_tag: old_tag,
              total: 0,
              registry_targets: length(report.targets),
              proof_id: proof_id,
              backup_evidence_id: evidence_id,
              zero_proved_at: row.proved_at,
              oldest_recoverable_at: row.oldest_recoverable_at,
              evidence_expires_at: row.expires_at,
              source_digest: Base.encode16(expected_source_digest, case: :lower)
            }

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  def retirement_preflight(_kind, _old_tag, _opts),
    do: {:error, :backup_aware_retirement_evidence_required}

  defp retirement_evidence(kind, old_tag, proof_id, evidence_id, evidence) do
    rows =
      Repo.query!(
        """
        SELECT proof.proved_at,
               backup.oldest_recoverable_at,
               backup.evidence_expires_at
        FROM public.key_retirement_zero_proofs AS proof
        JOIN public.vault_backup_retirement_evidence AS backup
          ON backup.key_kind = proof.key_kind
         AND backup.old_tag = proof.old_tag
         AND backup.zero_proof_id = proof.proof_id
        WHERE proof.key_kind = $1
          AND proof.old_tag = $2
          AND proof.proof_id = $3::uuid
          AND backup.evidence_id = $4
          AND proof.evidence_id = $5
          AND proof.evidence_digest = $6
          AND proof.evidence_operator = $7
          AND proof.exact_revision = $8
          AND backup.evidence_digest = proof.evidence_digest
          AND backup.evidence_operator = proof.evidence_operator
          AND backup.exact_revision = proof.exact_revision
          AND backup.attested_at > proof.proved_at
          AND backup.backup_oldest_recoverable_at > proof.proved_at
          AND backup.wal_oldest_recoverable_at > proof.proved_at
          AND backup.pitr_oldest_recoverable_at > proof.proved_at
          AND backup.restore_drill_recovered_through_at > proof.proved_at
          AND backup.oldest_recoverable_at > proof.proved_at
          AND backup.evidence_expires_at > timezone('UTC', clock_timestamp())
          AND backup.backup_catalog_captured_at <= timezone('UTC', clock_timestamp())
          AND backup.wal_catalog_captured_at <= timezone('UTC', clock_timestamp())
          AND backup.pitr_catalog_captured_at <= timezone('UTC', clock_timestamp())
          AND backup.restore_drill_completed_at <= timezone('UTC', clock_timestamp())
        FOR SHARE OF proof, backup
        """,
        [
          Atom.to_string(kind),
          old_tag,
          proof_id,
          evidence_id,
          evidence.id,
          evidence.digest,
          evidence.operator,
          evidence.revision
        ],
        log: false
      ).rows

    case rows do
      [[proved_at, oldest, expires_at]] ->
        {:ok, %{proved_at: proved_at, oldest_recoverable_at: oldest, expires_at: expires_at}}

      [] ->
        missing_or_stale_evidence(kind, old_tag, proof_id, evidence_id)
    end
  end

  defp missing_or_stale_evidence(kind, old_tag, proof_id, evidence_id) do
    case Repo.query!(
           """
           SELECT COUNT(*)
           FROM public.vault_backup_retirement_evidence
           WHERE key_kind = $1 AND old_tag = $2
             AND zero_proof_id = $3::uuid AND evidence_id = $4
           """,
           [Atom.to_string(kind), old_tag, proof_id, evidence_id],
           log: false
         ).rows do
      [[0]] -> {:error, :backup_retirement_evidence_missing}
      [[_count]] -> {:error, :backup_retirement_evidence_stale_or_mismatched}
    end
  end

  defp lock_zero_proof!(kind, old_tag, proof_id, evidence) do
    case Repo.query!(
           """
           SELECT source_digest, proved_at
           FROM public.key_retirement_zero_proofs
           WHERE key_kind = $1 AND old_tag = $2 AND proof_id = $3::uuid
             AND evidence_id = $4 AND evidence_digest = $5
             AND evidence_operator = $6 AND exact_revision = $7
           FOR SHARE
           """,
           [
             Atom.to_string(kind),
             old_tag,
             proof_id,
             evidence.id,
             evidence.digest,
             evidence.operator,
             evidence.revision
           ],
           log: false
         ).rows do
      [[source_digest, proved_at]] -> %{source_digest: source_digest, proved_at: proved_at}
      [] -> Repo.rollback(:key_retirement_zero_proof_missing_or_mismatched)
    end
  end

  defp incident_transaction(fun) do
    case Repo.transaction(
           fn ->
             Repo.query!("SET LOCAL ROLE maraithon_incident_operator", [], log: false)

             case Repo.query!("SELECT current_user", [], log: false).rows do
               [["maraithon_incident_operator"]] -> fun.()
               _invalid -> Repo.rollback(:incident_operator_credential_required)
             end
           end,
           timeout: 180_000
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :key_retirement_operation_failed}
  catch
    :exit, _reason -> {:error, :key_retirement_operation_failed}
  end

  defp live_report!(:vault, old_tag) do
    case VaultReencryption.preflight(old_tag) do
      {:ok, report} -> report
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp live_report!(:binding, old_tag) do
    case DurablePayloadBindingRotation.preflight(old_tag) do
      {:ok, report} -> report
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_kind_sources!(:vault) do
    VaultCiphertextRegistry.all()
    |> Enum.map(& &1.table)
    |> Enum.uniq()
    |> Enum.each(fn table ->
      Repo.query!("LOCK TABLE public.#{table} IN SHARE MODE", [], log: false)
    end)
  end

  defp lock_kind_sources!(:binding), do: Lifecycle.lock_source_tables!()

  defp source_digest(kind, old_tag, targets) do
    canonical =
      targets
      |> Enum.map(&Map.take(&1, [:table, :column, :binding, :old_tag_rows, :oversized_rows]))
      |> then(
        &%{domain: "maraithon:key-retirement-live-zero:v1", kind: kind, tag: old_tag, targets: &1}
      )

    canonical
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp recovery_component(opts, prefix) do
    with {:ok, digest} <-
           digest(Keyword.get(opts, String.to_existing_atom("#{prefix}_catalog_digest"))),
         {:ok, captured_at} <-
           datetime(Keyword.get(opts, String.to_existing_atom("#{prefix}_catalog_captured_at"))),
         {:ok, oldest_recoverable_at} <-
           datetime(Keyword.get(opts, String.to_existing_atom("#{prefix}_oldest_recoverable_at"))) do
      {:ok,
       %{digest: digest, captured_at: captured_at, oldest_recoverable_at: oldest_recoverable_at}}
    end
  end

  defp validate_retirable_tag(:vault, old_tag) do
    cond do
      old_tag == Vault.current_key_tag() -> {:error, :current_vault_tag_cannot_be_retired}
      old_tag not in Vault.configured_key_tags() -> {:error, :vault_read_key_unavailable}
      true -> validate_tag(old_tag)
    end
  end

  defp validate_retirable_tag(:binding, old_tag) do
    cond do
      old_tag == DurablePayloadBinding.current_key_tag() ->
        {:error, :current_binding_tag_cannot_be_retired}

      old_tag not in DurablePayloadBinding.configured_key_tags() ->
        {:error, :binding_read_key_unavailable}

      true ->
        validate_tag(old_tag)
    end
  end

  defp validate_tag(tag) when is_binary(tag) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/, tag) and tag == String.trim(tag),
      do: :ok,
      else: {:error, :invalid_key_tag}
  end

  defp digest(value) when is_binary(value) and byte_size(value) == 32, do: {:ok, value}
  defp digest(_value), do: {:error, :invalid_backup_evidence_digest}

  defp datetime(%DateTime{} = value), do: {:ok, value}

  defp datetime(%NaiveDateTime{} = value) do
    {:ok, DateTime.from_naive!(value, "Etc/UTC")}
  rescue
    _error -> {:error, :invalid_backup_evidence_timestamp}
  end

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, 0} -> {:ok, parsed}
      _invalid -> {:error, :invalid_backup_evidence_timestamp}
    end
  end

  defp datetime(_value), do: {:error, :invalid_backup_evidence_timestamp}

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_key_retirement_zero_proof_id}
    end
  end

  defp uuid(_value), do: {:error, :invalid_key_retirement_zero_proof_id}

  defp bounded_evidence_id(value)
       when is_binary(value) and byte_size(value) in 1..128,
       do: {:ok, value}

  defp bounded_evidence_id(_value), do: {:error, :backup_aware_retirement_evidence_required}

  defp strictly_after?(%DateTime{} = later, %NaiveDateTime{} = earlier),
    do: DateTime.compare(later, DateTime.from_naive!(earlier, "Etc/UTC")) == :gt

  defp strictly_after?(%DateTime{} = later, %DateTime{} = earlier),
    do: DateTime.compare(later, earlier) == :gt

  defp naive(%DateTime{} = value), do: DateTime.to_naive(value)

  defp old_tag_present_error(:vault, count), do: {:vault_old_tag_still_present, count}
  defp old_tag_present_error(:binding, count), do: {:binding_old_tag_still_present, count}
end
