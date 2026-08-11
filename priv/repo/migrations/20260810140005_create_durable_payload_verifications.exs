defmodule Maraithon.Repo.Migrations.CreateDurablePayloadVerifications do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    repo().checkout(
      fn ->
        repo().query!(
          "SELECT pg_catalog.pg_advisory_lock(" <>
            "pg_catalog.hashtextextended('maraithon:durable-payload-verifications:v2', 0))",
          [],
          timeout: :infinity
        )

        try do
          migrate()
          flush()
        after
          repo().query!(
            "SELECT pg_catalog.pg_advisory_unlock(" <>
              "pg_catalog.hashtextextended('maraithon:durable-payload-verifications:v2', 0))",
            [],
            timeout: :infinity
          )
        end
      end,
      timeout: :infinity
    )
  end

  defp migrate do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public")

    # Exact PreparedAction writes clear the legacy preview projection. The
    # original schema made that projection NOT NULL, so relax it before any
    # stopped-fleet contraction can make ciphertext-only rows authoritative.
    execute(
      "ALTER TABLE public.telegram_prepared_actions " <>
        "ALTER COLUMN preview_text DROP NOT NULL"
    )

    execute("ALTER TABLE public.snapshots ADD COLUMN IF NOT EXISTS state_data_ciphertext bytea")
    execute("ALTER TABLE public.snapshots ADD COLUMN IF NOT EXISTS budget_ciphertext bytea")

    execute(
      "ALTER TABLE public.snapshots ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE public.snapshots ADD COLUMN IF NOT EXISTS payload_binding_version smallint"
    )

    execute(
      "ALTER TABLE public.snapshots ADD COLUMN IF NOT EXISTS payload_binding_key_tag varchar(64)"
    )

    execute("ALTER TABLE public.snapshots ADD COLUMN IF NOT EXISTS payload_binding_mac bytea")
    execute("ALTER TABLE public.snapshots ADD COLUMN IF NOT EXISTS payload_purged_at timestamptz")

    add_not_valid_constraint(
      "snapshots",
      "snapshots_encrypted_payload_shape_check",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (state_data_ciphertext IS NULL OR octet_length(state_data_ciphertext) <= 1100000)
      AND (budget_ciphertext IS NULL OR octet_length(budget_ciphertext) <= 1100000)
      AND (
        (payload_binding_version IS NULL AND payload_binding_key_tag IS NULL AND payload_binding_mac IS NULL) OR
        (payload_binding_version = 1
         AND payload_binding_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
         AND octet_length(payload_binding_mac) = 32)
      )
      """
    )

    execute(
      "ALTER TABLE public.events ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE public.agent_run_steps ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    for table <- ~w(effects agent_directives events agent_run_steps) do
      execute(
        "ALTER TABLE public.#{table} ADD COLUMN IF NOT EXISTS payload_binding_version smallint"
      )

      execute(
        "ALTER TABLE public.#{table} ADD COLUMN IF NOT EXISTS payload_binding_key_tag varchar(64)"
      )

      execute("ALTER TABLE public.#{table} ADD COLUMN IF NOT EXISTS payload_binding_mac bytea")

      execute("""
      DO $constraint$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_catalog.pg_constraint
          WHERE conrelid = 'public.#{table}'::regclass
            AND conname = '#{table}_payload_binding_shape_check'
        ) THEN
          ALTER TABLE public.#{table}
          ADD CONSTRAINT #{table}_payload_binding_shape_check
          CHECK (
            (payload_binding_version IS NULL
              AND payload_binding_key_tag IS NULL
              AND payload_binding_mac IS NULL) OR
            (payload_binding_version = 1
              AND payload_binding_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
              AND octet_length(payload_binding_mac) = 32)
          ) NOT VALID;
        END IF;
      END
      $constraint$
      """)
    end

    add_not_valid_constraint(
      "effects",
      "effects_durable_payload_storage_bound",
      """
      (params_ciphertext IS NULL OR octet_length(params_ciphertext) <= 200000)
      AND (result_ciphertext IS NULL OR octet_length(result_ciphertext) <= 600000)
      AND pg_column_size(params) <= 200000
      AND (result IS NULL OR pg_column_size(result) <= 600000)
      """
    )

    add_not_valid_constraint(
      "agent_directives",
      "agent_directives_durable_payload_storage_bound",
      """
      (payload_ciphertext IS NULL OR octet_length(payload_ciphertext) <= 180000)
      AND pg_column_size(payload) <= 160000
      """
    )

    add_not_valid_constraint(
      "events",
      "events_payload_encryption_version_check",
      "payload_encryption_version IS NULL OR payload_encryption_version = 1"
    )

    add_not_valid_constraint(
      "agent_run_steps",
      "agent_run_steps_payload_encryption_version_check",
      "payload_encryption_version IS NULL OR payload_encryption_version = 1"
    )

    create_if_not_exists table(:durable_payload_verifications, primary_key: false) do
      add :payload_table, :string, null: false
      add :row_identity, :text, null: false
      add :ciphertext_digest, :binary, null: false
      add :projection_digest, :binary, null: false
      add :version_digest, :binary, null: false
      add :purge_digest, :binary, null: false
      add :key_tags, {:array, :string}, null: false, default: []
      add :verified_at, :utc_datetime_usec, null: false
    end

    ensure_index(
      "durable_payload_verifications",
      "durable_payload_verifications_pkey",
      ~w(payload_table row_identity),
      true
    )

    ensure_index(
      "durable_payload_verifications",
      "durable_payload_verifications_verified_at_index",
      ~w(payload_table verified_at),
      false
    )

    add_valid_constraint(
      "durable_payload_verifications",
      "durable_payload_verifications_table_check",
      "payload_table ~ '^[a-z][a-z0-9_]{0,62}$' AND octet_length(row_identity) BETWEEN 1 AND 255"
    )

    add_valid_constraint(
      "durable_payload_verifications",
      "durable_payload_verifications_digest_check",
      """
      octet_length(ciphertext_digest) = 32
      AND octet_length(projection_digest) = 32
      AND octet_length(version_digest) = 32
      AND octet_length(purge_digest) = 32
      """
    )

    add_valid_constraint(
      "durable_payload_verifications",
      "durable_payload_verifications_tags_check",
      """
      cardinality(key_tags) <= 8
      AND (
        cardinality(key_tags) = 0 OR
        array_to_string(key_tags, ',') ~
          '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}(,[A-Za-z0-9][A-Za-z0-9._:-]{0,63})*$'
      )
      """
    )

    create_if_not_exists table(:durable_payload_verification_failures, primary_key: false) do
      add :payload_table, :string, null: false
      add :row_identity, :text, null: false
      add :failure_class, :string, null: false
      add :ciphertext_digest, :binary, null: false
      add :projection_digest, :binary, null: false
      add :version_digest, :binary, null: false
      add :purge_digest, :binary, null: false
      add :failed_at, :utc_datetime_usec, null: false
    end

    ensure_index(
      "durable_payload_verification_failures",
      "durable_payload_verification_failures_pkey",
      ~w(payload_table row_identity),
      true
    )

    ensure_index(
      "durable_payload_verification_failures",
      "durable_payload_verification_failures_failed_at_index",
      ~w(failed_at),
      false
    )

    add_valid_constraint(
      "durable_payload_verification_failures",
      "durable_payload_verification_failures_shape_check",
      """
      payload_table ~ '^[a-z][a-z0-9_]{0,62}$'
      AND octet_length(row_identity) BETWEEN 1 AND 255
      AND failure_class ~ '^[a-z][a-z0-9_]{0,62}$'
      AND octet_length(ciphertext_digest) = 32
      AND octet_length(projection_digest) = 32
      AND octet_length(version_digest) = 32
      AND octet_length(purge_digest) = 32
      """
    )

    create_if_not_exists table(:vault_backup_retirement_evidence, primary_key: false) do
      add :old_tag, :string, null: false
      add :evidence_id, :string, null: false
      add :evidence_digest, :binary, null: false
      add :evidence_operator, :string, null: false
      add :exact_revision, :string, null: false
      add :oldest_recoverable_at, :utc_datetime_usec, null: false
      add :evidence_expires_at, :utc_datetime_usec, null: false
      add :attested_at, :utc_datetime_usec, null: false
    end

    add_valid_constraint(
      "vault_backup_retirement_evidence",
      "vault_backup_retirement_evidence_shape",
      """
      old_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
      AND octet_length(evidence_id) BETWEEN 1 AND 256
      AND octet_length(evidence_digest) = 32
      AND octet_length(evidence_operator) BETWEEN 1 AND 320
      AND exact_revision ~ '^[0-9a-f]{40}([0-9a-f]{24})?$'
      AND evidence_expires_at > oldest_recoverable_at
      """
    )

    create_if_not_exists table(:vault_reencryption_failures, primary_key: false) do
      add :payload_table, :string, null: false
      add :payload_column, :string, null: false
      add :row_identity, :text, null: false
      add :ciphertext_digest, :binary, null: false
      add :failure_class, :string, null: false
      add :failed_at, :utc_datetime_usec, null: false
    end

    ensure_index(
      "vault_reencryption_failures",
      "vault_reencryption_failures_pkey",
      ~w(payload_table payload_column row_identity),
      true
    )

    add_valid_constraint(
      "vault_reencryption_failures",
      "vault_reencryption_failures_shape_check",
      """
      payload_table ~ '^[a-z][a-z0-9_]{0,62}$'
      AND payload_column ~ '^[a-z][a-z0-9_]{0,62}$'
      AND octet_length(row_identity) BETWEEN 1 AND 255
      AND octet_length(ciphertext_digest) = 32
      AND failure_class IN ('oversized', 'authentication_failed',
                            'plaintext_oversized', 'key_tag_mismatch')
      """
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS key_kind varchar(16) NOT NULL DEFAULT 'vault'"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS backup_catalog_digest bytea"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS backup_catalog_captured_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS backup_oldest_recoverable_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS wal_catalog_digest bytea"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS wal_catalog_captured_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS wal_oldest_recoverable_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS pitr_catalog_digest bytea"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS pitr_catalog_captured_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS pitr_oldest_recoverable_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS restore_drill_digest bytea"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS restore_drill_completed_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS restore_drill_recovered_through_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE public.vault_backup_retirement_evidence ADD COLUMN IF NOT EXISTS zero_proof_id uuid"
    )

    ensure_index(
      "vault_backup_retirement_evidence",
      "vault_backup_retirement_evidence_pkey",
      ~w(key_kind old_tag zero_proof_id evidence_id),
      true
    )

    ensure_index(
      "vault_backup_retirement_evidence",
      "vault_backup_retirement_evidence_kind_index",
      ~w(key_kind old_tag attested_at),
      false
    )

    add_not_valid_constraint(
      "vault_backup_retirement_evidence",
      "vault_backup_retirement_evidence_recovery_shape_v2",
      """
      key_kind IN ('vault', 'binding')
      AND old_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
      AND octet_length(evidence_id) BETWEEN 1 AND 256
      AND octet_length(evidence_digest) = 32
      AND octet_length(evidence_operator) BETWEEN 1 AND 320
      AND exact_revision ~ '^[0-9a-f]{40}([0-9a-f]{24})?$'
      AND octet_length(backup_catalog_digest) = 32
      AND octet_length(wal_catalog_digest) = 32
      AND octet_length(pitr_catalog_digest) = 32
      AND octet_length(restore_drill_digest) = 32
      AND zero_proof_id IS NOT NULL
      AND backup_catalog_captured_at IS NOT NULL
      AND backup_oldest_recoverable_at IS NOT NULL
      AND wal_catalog_captured_at IS NOT NULL
      AND wal_oldest_recoverable_at IS NOT NULL
      AND pitr_catalog_captured_at IS NOT NULL
      AND pitr_oldest_recoverable_at IS NOT NULL
      AND restore_drill_completed_at IS NOT NULL
      AND restore_drill_recovered_through_at IS NOT NULL
      AND oldest_recoverable_at = LEAST(backup_oldest_recoverable_at,
                                        wal_oldest_recoverable_at,
                                        pitr_oldest_recoverable_at)
      AND evidence_expires_at > restore_drill_completed_at
      """
    )

    create_if_not_exists table(:durable_payload_binding_operations, primary_key: false) do
      add :operation_kind, :string, null: false
      add :payload_table, :string, null: false
      add :binding_name, :string, null: false, default: "payload"
      add :row_identity, :text, null: false
      add :source_digest, :binary, null: false
      add :target_key_tag, :string, null: false
      add :status, :string, null: false
      add :failure_class, :string
      add :evidence_id, :string, null: false
      add :evidence_digest, :binary, null: false
      add :evidence_operator, :string, null: false
      add :exact_revision, :string, null: false
      add :attempted_at, :utc_datetime_usec, null: false
    end

    execute(
      "ALTER TABLE public.durable_payload_binding_operations " <>
        "ADD COLUMN IF NOT EXISTS binding_name varchar(255) NOT NULL DEFAULT 'payload'"
    )

    ensure_index(
      "durable_payload_binding_operations",
      "durable_payload_binding_operations_pkey",
      ~w(operation_kind payload_table binding_name row_identity target_key_tag),
      true
    )

    ensure_index(
      "durable_payload_binding_operations",
      "durable_payload_binding_operations_progress_index",
      ~w(operation_kind status attempted_at),
      false
    )

    add_not_valid_constraint(
      "durable_payload_binding_operations",
      "durable_payload_binding_operations_shape",
      """
      operation_kind IN ('legacy_context_rebind_v1', 'binding_key_rotation_v1')
      AND payload_table IN (
        'effects', 'agent_directives', 'events', 'agent_run_steps',
        'telegram_conversation_turns', 'telegram_conversations',
        'telegram_assistant_runs', 'telegram_assistant_steps',
        'telegram_prepared_actions', 'agent_runs', 'operator_events',
        'user_memory_profiles', 'operator_memory_summaries', 'background_jobs',
        'scheduled_jobs', 'runtime_ingress_receipts', 'snapshots', 'agent_work_results'
      )
      AND binding_name IN ('payload', 'authority')
      AND (binding_name = 'payload' OR payload_table = 'agent_work_results')
      AND octet_length(row_identity) BETWEEN 1 AND 255
      AND octet_length(source_digest) = 32
      AND target_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
      AND status IN ('migrated', 'already_current', 'failed')
      AND ((status = 'failed' AND failure_class IN (
             'oversized', 'ciphertext_missing', 'authentication_failed',
             'payload_schema_invalid', 'binding_incomplete', 'binding_mismatch',
             'binding_key_unavailable', 'source_changed',
             'purge_marker_inconsistent'
           )) OR (status <> 'failed' AND failure_class IS NULL))
      AND octet_length(evidence_id) BETWEEN 1 AND 256
      AND octet_length(evidence_digest) = 32
      AND octet_length(evidence_operator) BETWEEN 1 AND 320
      AND exact_revision ~ '^[0-9a-f]{40}([0-9a-f]{24})?$'
      """
    )

    create_if_not_exists table(:key_retirement_zero_proofs, primary_key: false) do
      add :key_kind, :string, null: false
      add :old_tag, :string, null: false
      add :proof_id, :uuid, null: false
      add :source_digest, :binary, null: false
      add :evidence_id, :string, null: false
      add :evidence_digest, :binary, null: false
      add :evidence_operator, :string, null: false
      add :exact_revision, :string, null: false
      add :proved_at, :utc_datetime_usec, null: false
    end

    ensure_index(
      "key_retirement_zero_proofs",
      "key_retirement_zero_proofs_pkey",
      ~w(key_kind old_tag proof_id),
      true
    )

    ensure_index(
      "key_retirement_zero_proofs",
      "key_retirement_zero_proofs_latest_index",
      ~w(key_kind old_tag proved_at),
      false
    )

    add_not_valid_constraint(
      "key_retirement_zero_proofs",
      "key_retirement_zero_proofs_shape",
      """
      key_kind IN ('vault', 'binding')
      AND old_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
      AND octet_length(source_digest) = 32
      AND octet_length(evidence_id) BETWEEN 1 AND 256
      AND octet_length(evidence_digest) = 32
      AND octet_length(evidence_operator) BETWEEN 1 AND 320
      AND exact_revision ~ '^[0-9a-f]{40}([0-9a-f]{24})?$'
      """
    )

    create_if_not_exists table(:durable_payload_key_fence_state, primary_key: false) do
      add :singleton, :boolean, null: false
      add :generation, :bigint, null: false, default: 0
      add :fences, :map, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    ensure_index(
      "durable_payload_key_fence_state",
      "durable_payload_key_fence_state_pkey",
      ~w(singleton),
      true
    )

    add_valid_constraint(
      "durable_payload_key_fence_state",
      "durable_payload_key_fence_state_shape",
      """
      singleton IS TRUE
      AND generation >= 0
      AND pg_catalog.jsonb_typeof(fences) = 'object'
      AND pg_catalog.jsonb_typeof(fences -> 'vault') = 'object'
      AND pg_catalog.jsonb_typeof(fences -> 'binding') = 'object'
      AND fences = pg_catalog.jsonb_build_object(
        'vault', fences -> 'vault', 'binding', fences -> 'binding'
      )
      """
    )

    execute("""
    DO $key_fence_seed$
    DECLARE
      state_count bigint;
    BEGIN
      SELECT count(*) INTO STRICT state_count
      FROM public.durable_payload_key_fence_state;

      IF state_count = 0 THEN
        IF EXISTS (SELECT 1 FROM public.key_retirement_zero_proofs) THEN
          RAISE EXCEPTION 'Durable payload key fence state is missing for existing zero proofs'
            USING ERRCODE = 'check_violation';
        END IF;

        INSERT INTO public.durable_payload_key_fence_state (
          singleton, generation, fences, updated_at
        ) VALUES (
          true, 0, '{"vault": {}, "binding": {}}'::jsonb,
          timezone('UTC', clock_timestamp())
        );
      ELSIF state_count <> 1 OR NOT EXISTS (
        SELECT 1
        FROM public.durable_payload_key_fence_state
        WHERE singleton IS TRUE
      ) THEN
        RAISE EXCEPTION 'Durable payload key fence singleton is invalid'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM public.key_retirement_zero_proofs AS proof
        CROSS JOIN public.durable_payload_key_fence_state AS state
        WHERE state.singleton IS TRUE
          AND NOT ((state.fences -> proof.key_kind) ? proof.old_tag)
      ) OR EXISTS (
        SELECT 1
        FROM public.durable_payload_key_fence_state AS state
        CROSS JOIN LATERAL (
          SELECT 'vault'::text AS key_kind, key AS old_tag, value AS proof_id
          FROM pg_catalog.jsonb_each_text(state.fences -> 'vault')
          UNION ALL
          SELECT 'binding'::text AS key_kind, key AS old_tag, value AS proof_id
          FROM pg_catalog.jsonb_each_text(state.fences -> 'binding')
        ) AS fence
        WHERE state.singleton IS TRUE
          AND NOT EXISTS (
            SELECT 1
            FROM public.key_retirement_zero_proofs AS proof
            WHERE proof.key_kind = fence.key_kind
              AND proof.old_tag = fence.old_tag
              AND proof.proof_id::text = fence.proof_id
          )
      ) THEN
        RAISE EXCEPTION 'Durable payload key fence state does not match zero-proof history'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $key_fence_seed$;
    """)

    create_if_not_exists table(:retired_durable_payload_keys, primary_key: false) do
      add :key_kind, :string, null: false
      add :old_tag, :string, null: false
      add :zero_proof_id, :uuid, null: false
      add :backup_evidence_id, :string, null: false
      add :source_digest, :binary, null: false
      add :fence_generation, :bigint, null: false
      add :evidence_id, :string, null: false
      add :evidence_digest, :binary, null: false
      add :evidence_operator, :string, null: false
      add :exact_revision, :string, null: false
      add :authorized_at, :utc_datetime_usec, null: false
    end

    ensure_index(
      "retired_durable_payload_keys",
      "retired_durable_payload_keys_pkey",
      ~w(key_kind old_tag),
      true
    )

    add_not_valid_constraint(
      "retired_durable_payload_keys",
      "retired_durable_payload_keys_shape",
      """
      key_kind IN ('vault', 'binding')
      AND old_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
      AND octet_length(backup_evidence_id) BETWEEN 1 AND 128
      AND octet_length(source_digest) = 32
      AND fence_generation > 0
      AND octet_length(evidence_id) BETWEEN 1 AND 256
      AND octet_length(evidence_digest) = 32
      AND octet_length(evidence_operator) BETWEEN 1 AND 320
      AND exact_revision ~ '^[0-9a-f]{40}([0-9a-f]{24})?$'
      """
    )

    execute("""
    DO $constraint$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conrelid = 'public.vault_backup_retirement_evidence'::regclass
          AND conname = 'vault_backup_retirement_evidence_zero_proof_fkey'
      ) THEN
        ALTER TABLE public.vault_backup_retirement_evidence
          ADD CONSTRAINT vault_backup_retirement_evidence_zero_proof_fkey
          FOREIGN KEY (key_kind, old_tag, zero_proof_id)
          REFERENCES public.key_retirement_zero_proofs (key_kind, old_tag, proof_id)
          NOT VALID;
      END IF;
    END
    $constraint$;
    """)

    execute("""
    ALTER TABLE public.vault_backup_retirement_evidence
      VALIDATE CONSTRAINT vault_backup_retirement_evidence_zero_proof_fkey
    """)

    execute("""
    DO $constraint$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conrelid = 'public.retired_durable_payload_keys'::regclass
          AND conname = 'retired_durable_payload_keys_zero_proof_fkey'
      ) THEN
        ALTER TABLE public.retired_durable_payload_keys
          ADD CONSTRAINT retired_durable_payload_keys_zero_proof_fkey
          FOREIGN KEY (key_kind, old_tag, zero_proof_id)
          REFERENCES public.key_retirement_zero_proofs (key_kind, old_tag, proof_id)
          NOT VALID;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conrelid = 'public.retired_durable_payload_keys'::regclass
          AND conname = 'retired_durable_payload_keys_backup_evidence_fkey'
      ) THEN
        ALTER TABLE public.retired_durable_payload_keys
          ADD CONSTRAINT retired_durable_payload_keys_backup_evidence_fkey
          FOREIGN KEY (key_kind, old_tag, zero_proof_id, backup_evidence_id)
          REFERENCES public.vault_backup_retirement_evidence
            (key_kind, old_tag, zero_proof_id, evidence_id)
          NOT VALID;
      END IF;
    END
    $constraint$;
    """)

    execute("""
    ALTER TABLE public.retired_durable_payload_keys
      VALIDATE CONSTRAINT retired_durable_payload_keys_zero_proof_fkey
    """)

    execute("""
    ALTER TABLE public.retired_durable_payload_keys
      VALIDATE CONSTRAINT retired_durable_payload_keys_backup_evidence_fkey
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_row_identity(
      source_table text,
      source_id text
    )
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    STRICT
    SET search_path = pg_catalog, public
    AS $function$
      SELECT CASE
        WHEN source_table = 'events'
         AND source_id ~ '^\\["[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}","[1-9][0-9]*"\\]$'
          THEN source_id
        WHEN source_table IN (
          'effects', 'agent_directives', 'agent_run_steps',
          'telegram_conversation_turns', 'telegram_conversations',
          'telegram_assistant_runs', 'telegram_assistant_steps',
          'telegram_prepared_actions', 'agent_runs', 'operator_events',
          'user_memory_profiles', 'operator_memory_summaries',
          'background_jobs', 'scheduled_jobs', 'runtime_ingress_receipts',
          'agent_work_results'
        )
         AND source_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          THEN source_id
        WHEN source_table = 'snapshots'
         AND source_id ~ '^[1-9][0-9]*$'
          THEN source_id
        ELSE NULL::text
      END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_digest_part(
      source_table text,
      source_row jsonb,
      digest_part text
    )
    RETURNS bytea
    LANGUAGE sql
    IMMUTABLE
    STRICT
    SET search_path = pg_catalog, public
    AS $function$
      SELECT public.digest(
        pg_catalog.convert_to(
          jsonb_build_object(
            'domain', 'maraithon:durable-payload-proof:v1',
            'table', source_table,
            'part', digest_part,
            'value',
              CASE digest_part
                WHEN 'ciphertext' THEN
                  CASE source_table
                    WHEN 'effects' THEN jsonb_build_array(source_row -> 'params_ciphertext', source_row -> 'result_ciphertext')
                    WHEN 'agent_directives' THEN jsonb_build_array(source_row -> 'payload_ciphertext')
                    WHEN 'events' THEN jsonb_build_array(source_row -> 'payload_ciphertext')
                    WHEN 'agent_run_steps' THEN jsonb_build_array(source_row -> 'request_payload_ciphertext', source_row -> 'response_payload_ciphertext')
                    WHEN 'telegram_conversation_turns' THEN jsonb_build_array(source_row -> 'text_ciphertext', source_row -> 'structured_data_ciphertext')
                    WHEN 'telegram_conversations' THEN jsonb_build_array(source_row -> 'summary_ciphertext', source_row -> 'historical_summary_ciphertext')
                    WHEN 'telegram_assistant_runs' THEN jsonb_build_array(source_row -> 'prompt_snapshot_ciphertext', source_row -> 'result_summary_ciphertext')
                    WHEN 'telegram_assistant_steps' THEN jsonb_build_array(source_row -> 'request_payload_ciphertext', source_row -> 'response_payload_ciphertext')
                    WHEN 'telegram_prepared_actions' THEN jsonb_build_array(source_row -> 'payload_ciphertext', source_row -> 'preview_text_ciphertext')
                    WHEN 'agent_runs' THEN jsonb_build_array(source_row -> 'trigger_ciphertext', source_row -> 'metadata_ciphertext')
                    WHEN 'operator_events' THEN jsonb_build_array(source_row -> 'payload_ciphertext', source_row -> 'metadata_ciphertext')
                    WHEN 'user_memory_profiles' THEN jsonb_build_array(source_row -> 'summary_ciphertext', source_row -> 'profile_ciphertext')
                    WHEN 'operator_memory_summaries' THEN jsonb_build_array(source_row -> 'content_ciphertext')
                    WHEN 'background_jobs' THEN jsonb_build_array(source_row -> 'payload_ciphertext', source_row -> 'result_ciphertext')
                    WHEN 'scheduled_jobs' THEN jsonb_build_array(source_row -> 'payload_ciphertext')
                    WHEN 'runtime_ingress_receipts' THEN jsonb_build_array(source_row -> 'payload_ciphertext')
                    WHEN 'agent_work_results' THEN jsonb_build_array(source_row -> 'result_ciphertext')
                    WHEN 'snapshots' THEN jsonb_build_array(source_row -> 'state_data_ciphertext', source_row -> 'budget_ciphertext')
                  END
                WHEN 'projection' THEN
                  CASE source_table
                    WHEN 'effects' THEN jsonb_build_array(source_row -> 'params', source_row -> 'result')
                    WHEN 'agent_directives' THEN jsonb_build_array(source_row -> 'payload')
                    WHEN 'events' THEN jsonb_build_array(source_row -> 'payload')
                    WHEN 'agent_run_steps' THEN jsonb_build_array(source_row -> 'request_payload', source_row -> 'response_payload')
                    WHEN 'telegram_conversation_turns' THEN jsonb_build_array(source_row -> 'text', source_row -> 'structured_data')
                    WHEN 'telegram_conversations' THEN jsonb_build_array(source_row -> 'summary', source_row -> 'metadata' -> 'historical_summary')
                    WHEN 'telegram_assistant_runs' THEN jsonb_build_array(source_row -> 'prompt_snapshot', source_row -> 'result_summary')
                    WHEN 'telegram_assistant_steps' THEN jsonb_build_array(source_row -> 'request_payload', source_row -> 'response_payload')
                    WHEN 'telegram_prepared_actions' THEN jsonb_build_array(source_row -> 'payload', source_row -> 'preview_text')
                    WHEN 'agent_runs' THEN jsonb_build_array(source_row -> 'trigger', source_row -> 'metadata')
                    WHEN 'operator_events' THEN jsonb_build_array(source_row -> 'payload', source_row -> 'metadata')
                    WHEN 'user_memory_profiles' THEN jsonb_build_array(source_row -> 'summary', source_row -> 'profile')
                    WHEN 'operator_memory_summaries' THEN jsonb_build_array(source_row -> 'content')
                    WHEN 'background_jobs' THEN jsonb_build_array(source_row -> 'payload', source_row -> 'result')
                    WHEN 'scheduled_jobs' THEN jsonb_build_array(source_row -> 'payload')
                    WHEN 'runtime_ingress_receipts' THEN jsonb_build_array(source_row -> 'payload')
                    WHEN 'agent_work_results' THEN jsonb_build_array(source_row -> 'result')
                    WHEN 'snapshots' THEN jsonb_build_array(source_row -> 'state_data', source_row -> 'budget')
                  END
                WHEN 'version' THEN
                  CASE source_table
                    WHEN 'effects' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'owner_user_id', source_row -> 'agent_id')
                    WHEN 'agent_directives' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id', source_row -> 'agent_id')
                    WHEN 'events' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'agent_id', source_row -> 'sequence_num')
                    WHEN 'agent_run_steps' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'agent_id', source_row -> 'agent_run_id')
                    WHEN 'telegram_conversation_turns' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'conversation_id')
                    WHEN 'telegram_conversations' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id')
                    WHEN 'telegram_assistant_runs' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id', source_row -> 'conversation_id')
                    WHEN 'telegram_assistant_steps' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'run_id')
                    WHEN 'telegram_prepared_actions' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id', source_row -> 'conversation_id', source_row -> 'run_id')
                    WHEN 'agent_runs' THEN jsonb_build_array(source_row -> 'private_payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id', source_row -> 'agent_id')
                    WHEN 'operator_events' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id', source_row -> 'project_id')
                    WHEN 'user_memory_profiles' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id')
                    WHEN 'operator_memory_summaries' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id')
                    WHEN 'background_jobs' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id')
                    WHEN 'scheduled_jobs' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'agent_id')
                    WHEN 'runtime_ingress_receipts' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id', source_row -> 'agent_id', source_row -> 'connected_account_id')
                    WHEN 'agent_work_results' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id', source_row -> 'agent_id', source_row -> 'agent_directive_id', source_row -> 'agent_run_id', source_row -> 'result_digest_version', source_row -> 'result_digest_key_tag', source_row -> 'result_digest', source_row -> 'result_content_digest_version', source_row -> 'result_content_digest')
                    WHEN 'snapshots' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'agent_id', source_row -> 'sequence_num', source_row -> 'schema_version', source_row -> 'state_name')
                  END
                WHEN 'purge' THEN
                  CASE source_table
                    WHEN 'effects' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                    WHEN 'agent_directives' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                    WHEN 'events' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                    WHEN 'agent_run_steps' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                    WHEN 'telegram_conversation_turns' THEN jsonb_build_array(source_row -> 'content_scrubbed_at')
                    WHEN 'telegram_conversations' THEN jsonb_build_array(source_row -> 'content_scrubbed_at')
                    WHEN 'telegram_assistant_runs' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                    WHEN 'telegram_assistant_steps' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                    WHEN 'telegram_prepared_actions' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                    WHEN 'agent_runs' THEN jsonb_build_array(source_row -> 'private_payload_purged_at')
                    WHEN 'operator_events' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                    WHEN 'user_memory_profiles' THEN jsonb_build_array(source_row -> 'content_erased_at')
                    WHEN 'operator_memory_summaries' THEN jsonb_build_array(source_row -> 'content_erased_at')
                    WHEN 'background_jobs' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                    WHEN 'scheduled_jobs' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                    WHEN 'runtime_ingress_receipts' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                    WHEN 'agent_work_results' THEN jsonb_build_array(source_row -> 'result_purged_at')
                    WHEN 'snapshots' THEN jsonb_build_array(source_row -> 'payload_purged_at')
                  END
              END
          )::text,
          'UTF8'
        ),
        'sha256'
      );
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_proof_failures()
    RETURNS bigint
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      failure_count bigint;
    BEGIN
      EXECUTE $proof_query$
        WITH source_rows AS (
          SELECT
            'effects'::text AS payload_table,
            public.durable_payload_row_identity('effects', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.params = '{"redacted": true}'::jsonb AND source.result IS NULL
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.params_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND true
                  AND source.params_ciphertext IS NULL AND source.result_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.effects AS source

          UNION ALL

          SELECT
            'agent_directives'::text AS payload_table,
            public.durable_payload_row_identity('agent_directives', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.payload = '{"redacted": true}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.payload_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND true
                  AND source.payload_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.agent_directives AS source

          UNION ALL

          SELECT
            'events'::text AS payload_table,
            public.durable_payload_row_identity('events', '[' || to_json(source.agent_id::text)::text || ',' || to_json(source.sequence_num::text)::text || ']') AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.payload = '{}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.payload_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND true
                  AND source.payload_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.events AS source

          UNION ALL

          SELECT
            'agent_run_steps'::text AS payload_table,
            public.durable_payload_row_identity('agent_run_steps', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.request_payload = '{}'::jsonb AND source.response_payload = '{}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.request_payload_ciphertext IS NOT NULL AND source.response_payload_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND true
                  AND source.request_payload_ciphertext IS NULL AND source.response_payload_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.agent_run_steps AS source

          UNION ALL

          SELECT
            'telegram_conversation_turns'::text AS payload_table,
            public.durable_payload_row_identity('telegram_conversation_turns', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.content_scrubbed_at IS NULL AS proof_required,
            (source.text = '[encrypted]' AND source.structured_data = '{}'::jsonb
              AND (
                (source.content_scrubbed_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.text_ciphertext IS NOT NULL AND source.structured_data_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.content_scrubbed_at IS NOT NULL
                  AND true
                  AND source.text_ciphertext IS NULL AND source.structured_data_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.telegram_conversation_turns AS source

          UNION ALL

          SELECT
            'telegram_conversations'::text AS payload_table,
            public.durable_payload_row_identity('telegram_conversations', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.content_scrubbed_at IS NULL AS proof_required,
            (source.summary IS NULL AND NOT jsonb_exists(source.metadata, 'historical_summary')
              AND (
                (source.content_scrubbed_at IS NULL
                  AND (source.payload_encryption_version = 1 OR (source.payload_encryption_version IS NULL AND source.summary_ciphertext IS NULL AND source.historical_summary_ciphertext IS NULL))
                  AND true
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.content_scrubbed_at IS NOT NULL
                  AND true
                  AND source.summary_ciphertext IS NULL AND source.historical_summary_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.telegram_conversations AS source

          UNION ALL

          SELECT
            'telegram_assistant_runs'::text AS payload_table,
            public.durable_payload_row_identity('telegram_assistant_runs', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.prompt_snapshot = '{}'::jsonb AND source.result_summary = '{}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.prompt_snapshot_ciphertext IS NOT NULL AND source.result_summary_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND true
                  AND source.prompt_snapshot_ciphertext IS NULL AND source.result_summary_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.telegram_assistant_runs AS source

          UNION ALL

          SELECT
            'telegram_assistant_steps'::text AS payload_table,
            public.durable_payload_row_identity('telegram_assistant_steps', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.request_payload = '{}'::jsonb AND source.response_payload = '{}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.request_payload_ciphertext IS NOT NULL AND source.response_payload_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND true
                  AND source.request_payload_ciphertext IS NULL AND source.response_payload_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.telegram_assistant_steps AS source

          UNION ALL

          SELECT
            'telegram_prepared_actions'::text AS payload_table,
            public.durable_payload_row_identity('telegram_prepared_actions', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.payload = '{}'::jsonb AND source.preview_text IS NULL
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.payload_ciphertext IS NOT NULL AND source.preview_text_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND source.status IN ('executed', 'rejected', 'expired', 'failed')
                  AND source.payload_ciphertext IS NULL AND source.preview_text_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.telegram_prepared_actions AS source

          UNION ALL

          SELECT
            'agent_runs'::text AS payload_table,
            public.durable_payload_row_identity('agent_runs', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.private_payload_purged_at IS NULL AS proof_required,
            (source.trigger = '{}'::jsonb AND source.metadata = '{}'::jsonb
              AND (
                (source.private_payload_purged_at IS NULL
                  AND source.private_payload_encryption_version = 1
                  AND source.trigger_ciphertext IS NOT NULL AND source.metadata_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.private_payload_purged_at IS NOT NULL
                  AND true
                  AND source.trigger_ciphertext IS NULL AND source.metadata_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.agent_runs AS source

          UNION ALL

          SELECT
            'operator_events'::text AS payload_table,
            public.durable_payload_row_identity('operator_events', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.payload = '{}'::jsonb AND source.metadata = '{}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.payload_ciphertext IS NOT NULL AND source.metadata_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND true
                  AND source.payload_ciphertext IS NULL AND source.metadata_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.operator_events AS source

          UNION ALL

          SELECT
            'user_memory_profiles'::text AS payload_table,
            public.durable_payload_row_identity('user_memory_profiles', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.content_erased_at IS NULL AS proof_required,
            (source.summary = '[encrypted]' AND source.profile = '{}'::jsonb
              AND (
                (source.content_erased_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.summary_ciphertext IS NOT NULL AND source.profile_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.content_erased_at IS NOT NULL
                  AND true
                  AND source.summary_ciphertext IS NULL AND source.profile_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.user_memory_profiles AS source

          UNION ALL

          SELECT
            'operator_memory_summaries'::text AS payload_table,
            public.durable_payload_row_identity('operator_memory_summaries', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.content_erased_at IS NULL AS proof_required,
            (source.content = '[encrypted]'
              AND (
                (source.content_erased_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.content_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.content_erased_at IS NOT NULL
                  AND true
                  AND source.content_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.operator_memory_summaries AS source

          UNION ALL

          SELECT
            'background_jobs'::text AS payload_table,
            public.durable_payload_row_identity('background_jobs', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.payload = '{}'::jsonb AND source.result = '{}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.payload_ciphertext IS NOT NULL AND source.result_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND true
                  AND source.payload_ciphertext IS NULL AND source.result_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.background_jobs AS source

          UNION ALL

          SELECT
            'scheduled_jobs'::text AS payload_table,
            public.durable_payload_row_identity('scheduled_jobs', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.payload = '{}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.payload_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND true
                  AND source.payload_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.scheduled_jobs AS source

          UNION ALL

          SELECT
            'runtime_ingress_receipts'::text AS payload_table,
            public.durable_payload_row_identity('runtime_ingress_receipts', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.payload = '{}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.payload_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND true
                  AND source.payload_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.runtime_ingress_receipts AS source

          UNION ALL

          SELECT
            'agent_work_results'::text AS payload_table,
            public.durable_payload_row_identity('agent_work_results', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.result_purged_at IS NULL AS proof_required,
            (source.result = '{}'::jsonb
              AND (
                (source.result_purged_at IS NULL
                  AND source.payload_encryption_version = 1 AND source.result_digest_version = 1 AND source.result_digest_key_tag IS NOT NULL AND octet_length(source.result_digest) = 32
                  AND source.result_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.result_purged_at IS NOT NULL
                  AND source.status = 'committed'
                  AND source.result_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.agent_work_results AS source

          UNION ALL

          SELECT
            'snapshots'::text AS payload_table,
            public.durable_payload_row_identity('snapshots', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.state_data = '{}'::jsonb
              AND source.budget = '{}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.state_data_ciphertext IS NOT NULL
                  AND source.budget_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND source.state_data_ciphertext IS NULL
                  AND source.budget_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.snapshots AS source
        )
        SELECT COUNT(*)
        FROM source_rows AS source
        LEFT JOIN public.durable_payload_verifications AS proof
          ON proof.payload_table = source.payload_table
         AND proof.row_identity = source.row_identity
        WHERE NOT source.shape_valid
           OR (source.proof_required AND (
             proof.row_identity IS NULL OR
             proof.ciphertext_digest IS DISTINCT FROM
               public.durable_payload_digest_part(
                 source.payload_table, source.source_row, 'ciphertext'
               ) OR
             proof.projection_digest IS DISTINCT FROM
               public.durable_payload_digest_part(
                 source.payload_table, source.source_row, 'projection'
               ) OR
             proof.version_digest IS DISTINCT FROM
               public.durable_payload_digest_part(
                 source.payload_table, source.source_row, 'version'
               ) OR
             proof.purge_digest IS DISTINCT FROM
               public.durable_payload_digest_part(
                 source.payload_table, source.source_row, 'purge'
               )
           ))
      $proof_query$
      INTO failure_count;

      RETURN failure_count;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_source_acl_ready()
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
      WITH source_relations(table_name, relation_id) AS (
        VALUES
          ('connected_accounts', 'public.connected_accounts'),
          ('oauth_tokens', 'public.oauth_tokens'),
          ('local_browser_visits', 'public.local_browser_visits'),
          ('local_calendar_events', 'public.local_calendar_events'),
          ('local_files', 'public.local_files'),
          ('memory_items', 'public.memory_items'),
          ('effects', 'public.effects'),
          ('agent_directives', 'public.agent_directives'),
          ('events', 'public.events'),
          ('agent_run_steps', 'public.agent_run_steps'),
          ('telegram_conversation_turns', 'public.telegram_conversation_turns'),
          ('telegram_conversations', 'public.telegram_conversations'),
          ('telegram_assistant_runs', 'public.telegram_assistant_runs'),
          ('telegram_assistant_steps', 'public.telegram_assistant_steps'),
          ('telegram_prepared_actions', 'public.telegram_prepared_actions'),
          ('agent_runs', 'public.agent_runs'),
          ('operator_events', 'public.operator_events'),
          ('user_memory_profiles', 'public.user_memory_profiles'),
          ('operator_memory_summaries', 'public.operator_memory_summaries'),
          ('background_jobs', 'public.background_jobs'),
          ('scheduled_jobs', 'public.scheduled_jobs'),
          ('runtime_ingress_receipts', 'public.runtime_ingress_receipts'),
          ('agent_work_results', 'public.agent_work_results'),
          ('snapshots', 'public.snapshots')
      ), expected_table_acl_groups(grantee, table_names) AS (
        VALUES
          ('maraithon_payload_verifier', ARRAY['effects', 'agent_directives', 'events', 'agent_run_steps', 'telegram_conversation_turns', 'telegram_conversations', 'telegram_assistant_runs', 'telegram_assistant_steps', 'telegram_prepared_actions', 'agent_runs', 'operator_events', 'user_memory_profiles', 'operator_memory_summaries', 'background_jobs', 'scheduled_jobs', 'runtime_ingress_receipts', 'agent_work_results', 'snapshots']::text[]),
          ('maraithon_incident_operator', ARRAY['connected_accounts', 'oauth_tokens', 'local_browser_visits', 'local_calendar_events', 'local_files', 'memory_items', 'effects', 'agent_directives', 'events', 'agent_run_steps', 'telegram_conversation_turns', 'telegram_conversations', 'telegram_assistant_runs', 'telegram_assistant_steps', 'telegram_prepared_actions', 'agent_runs', 'operator_events', 'user_memory_profiles', 'operator_memory_summaries', 'background_jobs', 'scheduled_jobs', 'runtime_ingress_receipts', 'agent_work_results', 'snapshots']::text[]),
          ('maraithon_activation_operator', ARRAY['effects', 'agent_directives', 'events', 'agent_run_steps', 'telegram_conversation_turns', 'telegram_conversations', 'telegram_assistant_runs', 'telegram_assistant_steps', 'telegram_prepared_actions', 'agent_runs', 'operator_events', 'user_memory_profiles', 'operator_memory_summaries', 'background_jobs', 'scheduled_jobs', 'runtime_ingress_receipts', 'agent_work_results', 'snapshots']::text[])
      ), expected_table_acls AS (
        SELECT expected.grantee,
               table_name,
               NULL::text AS column_name,
               'SELECT'::text AS privilege_type,
               false AS is_grantable
        FROM expected_table_acl_groups AS expected
        CROSS JOIN LATERAL pg_catalog.unnest(expected.table_names) AS expanded(table_name)
      ), actual_table_acls AS (
        SELECT COALESCE(grantee.rolname, 'PUBLIC') AS grantee,
               source.table_name,
               NULL::text AS column_name,
               acl.privilege_type,
               acl.is_grantable
        FROM source_relations AS source
        JOIN pg_catalog.pg_class AS relation
          ON relation.oid = source.relation_id::regclass
        CROSS JOIN LATERAL pg_catalog.aclexplode(
          COALESCE(relation.relacl, pg_catalog.acldefault('r', relation.relowner))
        ) AS acl
        LEFT JOIN pg_catalog.pg_roles AS grantee ON grantee.oid = acl.grantee
        WHERE acl.grantee = 0
           OR grantee.rolname IN (
             'maraithon_payload_verifier',
             'maraithon_incident_operator',
             'maraithon_activation_operator'
           )
      ), expected_column_acl_groups(grantee, table_name, column_names) AS (
        VALUES
          ('maraithon_incident_operator', 'connected_accounts', ARRAY['access_token', 'refresh_token']::text[]),
          ('maraithon_incident_operator', 'oauth_tokens', ARRAY['access_token', 'refresh_token']::text[]),
          ('maraithon_incident_operator', 'local_browser_visits', ARRAY['title']::text[]),
          ('maraithon_incident_operator', 'local_calendar_events', ARRAY['title', 'notes']::text[]),
          ('maraithon_incident_operator', 'local_files', ARRAY['filename', 'text_content']::text[]),
          ('maraithon_incident_operator', 'memory_items', ARRAY['content', 'summary', 'metadata']::text[]),
          ('maraithon_incident_operator', 'effects', ARRAY['params_ciphertext', 'result_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'agent_directives', ARRAY['payload_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'events', ARRAY['payload_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'agent_run_steps', ARRAY['request_payload_ciphertext', 'response_payload_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'telegram_conversation_turns', ARRAY['text_ciphertext', 'structured_data_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'telegram_conversations', ARRAY['summary_ciphertext', 'historical_summary_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'telegram_assistant_runs', ARRAY['prompt_snapshot_ciphertext', 'result_summary_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'telegram_assistant_steps', ARRAY['request_payload_ciphertext', 'response_payload_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'telegram_prepared_actions', ARRAY['payload_ciphertext', 'preview_text_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'agent_runs', ARRAY['trigger_ciphertext', 'metadata_ciphertext', 'private_payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'operator_events', ARRAY['payload_ciphertext', 'metadata_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'user_memory_profiles', ARRAY['summary_ciphertext', 'profile_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'operator_memory_summaries', ARRAY['content_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'background_jobs', ARRAY['payload_ciphertext', 'result_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'scheduled_jobs', ARRAY['payload_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'runtime_ingress_receipts', ARRAY['payload_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_incident_operator', 'agent_work_results', ARRAY['result_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac', 'result_digest', 'result_digest_version', 'result_digest_key_tag']::text[]),
          ('maraithon_incident_operator', 'snapshots', ARRAY['state_data_ciphertext', 'budget_ciphertext', 'payload_encryption_version', 'payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'effects', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac', 'params', 'params_ciphertext', 'result', 'result_ciphertext', 'error', 'payload_encryption_version', 'updated_at']::text[]),
          ('maraithon_activation_operator', 'agent_directives', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac', 'payload', 'payload_ciphertext', 'payload_encryption_version', 'payload_purged_at', 'updated_at']::text[]),
          ('maraithon_activation_operator', 'events', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac', 'payload', 'payload_ciphertext', 'payload_encryption_version', 'spend_total_cost', 'spend_input_tokens', 'spend_output_tokens', 'spend_llm_calls']::text[]),
          ('maraithon_activation_operator', 'agent_run_steps', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac', 'request_payload', 'request_payload_ciphertext', 'response_payload', 'response_payload_ciphertext', 'payload_encryption_version', 'updated_at']::text[]),
          ('maraithon_activation_operator', 'telegram_conversation_turns', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'telegram_conversations', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'telegram_assistant_runs', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'telegram_assistant_steps', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'telegram_prepared_actions', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'agent_runs', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'operator_events', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'user_memory_profiles', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'operator_memory_summaries', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'background_jobs', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac', 'payload', 'payload_ciphertext', 'result', 'result_ciphertext', 'payload_encryption_version', 'updated_at']::text[]),
          ('maraithon_activation_operator', 'scheduled_jobs', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'runtime_ingress_receipts', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac']::text[]),
          ('maraithon_activation_operator', 'agent_work_results', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac', 'result_digest', 'result_digest_version', 'result_digest_key_tag']::text[]),
          ('maraithon_activation_operator', 'snapshots', ARRAY['payload_binding_version', 'payload_binding_key_tag', 'payload_binding_mac', 'state_data', 'state_data_ciphertext', 'budget', 'budget_ciphertext', 'payload_encryption_version']::text[])
      ), expected_column_acls AS (
        SELECT expected.grantee,
               expected.table_name,
               column_name,
               'UPDATE'::text AS privilege_type,
               false AS is_grantable
        FROM expected_column_acl_groups AS expected
        CROSS JOIN LATERAL pg_catalog.unnest(expected.column_names) AS expanded(column_name)
      ), actual_column_acls AS (
        SELECT COALESCE(grantee.rolname, 'PUBLIC') AS grantee,
               source.table_name,
               attribute.attname AS column_name,
               acl.privilege_type,
               acl.is_grantable
        FROM source_relations AS source
        JOIN pg_catalog.pg_class AS relation
          ON relation.oid = source.relation_id::regclass
        JOIN pg_catalog.pg_attribute AS attribute
          ON attribute.attrelid = relation.oid
         AND attribute.attnum > 0
         AND NOT attribute.attisdropped
        CROSS JOIN LATERAL pg_catalog.aclexplode(attribute.attacl) AS acl
        LEFT JOIN pg_catalog.pg_roles AS grantee ON grantee.oid = acl.grantee
        WHERE acl.grantee = 0
           OR grantee.rolname IN (
             'maraithon_payload_verifier',
             'maraithon_incident_operator',
             'maraithon_activation_operator'
           )
      ), acl_differences AS (
        (SELECT * FROM actual_table_acls EXCEPT SELECT * FROM expected_table_acls)
        UNION ALL
        (SELECT * FROM expected_table_acls EXCEPT SELECT * FROM actual_table_acls)
        UNION ALL
        (SELECT * FROM actual_column_acls EXCEPT SELECT * FROM expected_column_acls)
        UNION ALL
        (SELECT * FROM expected_column_acls EXCEPT SELECT * FROM actual_column_acls)
      )
      SELECT NOT EXISTS (SELECT 1 FROM acl_differences)
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_roles_ready()
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      owner_oid oid;
      runtime_oid oid;
      verifier_oid oid;
      incident_oid oid;
      activation_oid oid;
    BEGIN
      IF NOT public.runtime_coordination_roles_ready()
         OR NOT public.durable_payload_source_acl_ready() THEN
        RETURN false;
      END IF;

      SELECT oid INTO STRICT owner_oid FROM pg_catalog.pg_roles
      WHERE rolname = 'maraithon_object_owner';
      SELECT oid INTO STRICT runtime_oid FROM pg_catalog.pg_roles
      WHERE rolname = 'maraithon_runtime';
      SELECT oid INTO STRICT verifier_oid FROM pg_catalog.pg_roles
      WHERE rolname = 'maraithon_payload_verifier';
      SELECT oid INTO STRICT incident_oid FROM pg_catalog.pg_roles
      WHERE rolname = 'maraithon_incident_operator';
      SELECT oid INTO STRICT activation_oid FROM pg_catalog.pg_roles
      WHERE rolname = 'maraithon_activation_operator';

      IF EXISTS (
        SELECT 1
        FROM (
          VALUES
            ('public.durable_payload_verifications'::regclass),
            ('public.durable_payload_verification_failures'::regclass),
            ('public.vault_reencryption_failures'::regclass),
            ('public.vault_backup_retirement_evidence'::regclass),
            ('public.durable_payload_binding_operations'::regclass),
            ('public.key_retirement_zero_proofs'::regclass),
            ('public.durable_payload_key_fence_state'::regclass),
            ('public.retired_durable_payload_keys'::regclass)
        ) AS controlled(relation_id)
        JOIN pg_catalog.pg_class AS relation ON relation.oid = controlled.relation_id
        WHERE relation.relowner <> owner_oid
      ) THEN
        RETURN false;
      END IF;

      IF NOT (
        has_table_privilege('maraithon_payload_verifier',
          'public.durable_payload_verifications', 'SELECT') AND
        has_table_privilege('maraithon_payload_verifier',
          'public.durable_payload_verifications', 'INSERT') AND
        has_table_privilege('maraithon_payload_verifier',
          'public.durable_payload_verifications', 'DELETE') AND
        NOT has_table_privilege('maraithon_payload_verifier',
          'public.durable_payload_verifications', 'UPDATE') AND
        has_table_privilege('maraithon_payload_verifier',
          'public.durable_payload_verification_failures', 'SELECT') AND
        has_table_privilege('maraithon_payload_verifier',
          'public.durable_payload_verification_failures', 'INSERT') AND
        has_table_privilege('maraithon_payload_verifier',
          'public.durable_payload_verification_failures', 'UPDATE') AND
        has_table_privilege('maraithon_payload_verifier',
          'public.durable_payload_verification_failures', 'DELETE') AND
        has_table_privilege('maraithon_activation_operator',
          'public.durable_payload_verifications', 'SELECT') AND
        has_table_privilege('maraithon_activation_operator',
          'public.durable_payload_verifications', 'UPDATE') AND
        has_table_privilege('maraithon_activation_operator',
          'public.durable_payload_verification_failures', 'SELECT') AND
        has_table_privilege('maraithon_activation_operator',
          'public.durable_payload_verification_failures', 'UPDATE') AND
        has_table_privilege('maraithon_activation_operator',
          'public.durable_payload_binding_operations', 'SELECT') AND
        has_table_privilege('maraithon_activation_operator',
          'public.durable_payload_binding_operations', 'INSERT') AND
        has_table_privilege('maraithon_activation_operator',
          'public.durable_payload_binding_operations', 'UPDATE') AND
        NOT has_table_privilege('maraithon_activation_operator',
          'public.durable_payload_binding_operations', 'DELETE') AND
        has_table_privilege('maraithon_incident_operator',
          'public.durable_payload_binding_operations', 'SELECT') AND
        has_table_privilege('maraithon_incident_operator',
          'public.durable_payload_binding_operations', 'INSERT') AND
        has_table_privilege('maraithon_incident_operator',
          'public.durable_payload_binding_operations', 'UPDATE') AND
        NOT has_table_privilege('maraithon_incident_operator',
          'public.durable_payload_binding_operations', 'DELETE') AND
        has_table_privilege('maraithon_incident_operator',
          'public.key_retirement_zero_proofs', 'SELECT') AND
        has_table_privilege('maraithon_incident_operator',
          'public.key_retirement_zero_proofs', 'INSERT') AND
        NOT has_table_privilege('maraithon_incident_operator',
          'public.key_retirement_zero_proofs', 'UPDATE') AND
        NOT has_table_privilege('maraithon_incident_operator',
          'public.key_retirement_zero_proofs', 'DELETE') AND
        has_table_privilege('maraithon_incident_operator',
          'public.retired_durable_payload_keys', 'SELECT') AND
        has_table_privilege('maraithon_incident_operator',
          'public.retired_durable_payload_keys', 'INSERT') AND
        NOT has_table_privilege('maraithon_incident_operator',
          'public.retired_durable_payload_keys', 'UPDATE') AND
        NOT has_table_privilege('maraithon_incident_operator',
          'public.retired_durable_payload_keys', 'DELETE') AND
        NOT has_table_privilege('maraithon_runtime',
          'public.durable_payload_key_fence_state', 'SELECT') AND
        NOT has_table_privilege('maraithon_payload_verifier',
          'public.durable_payload_key_fence_state', 'SELECT') AND
        NOT has_table_privilege('maraithon_incident_operator',
          'public.durable_payload_key_fence_state', 'SELECT') AND
        NOT has_table_privilege('maraithon_activation_operator',
          'public.durable_payload_key_fence_state', 'SELECT') AND
        has_table_privilege('maraithon_incident_operator',
          'public.vault_backup_retirement_evidence', 'SELECT') AND
        has_table_privilege('maraithon_incident_operator',
          'public.vault_backup_retirement_evidence', 'INSERT') AND
        NOT has_table_privilege('maraithon_incident_operator',
          'public.vault_backup_retirement_evidence', 'UPDATE') AND
        NOT has_table_privilege('maraithon_incident_operator',
          'public.vault_backup_retirement_evidence', 'DELETE') AND
        NOT has_table_privilege('maraithon_runtime',
          'public.durable_payload_binding_operations', 'SELECT') AND
        NOT has_table_privilege('maraithon_payload_verifier',
          'public.durable_payload_binding_operations', 'SELECT') AND
        NOT has_table_privilege('maraithon_runtime',
          'public.key_retirement_zero_proofs', 'SELECT') AND
        NOT has_table_privilege('maraithon_payload_verifier',
          'public.key_retirement_zero_proofs', 'SELECT')
      ) THEN
        RETURN false;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM (
          VALUES ('effects'), ('agent_directives'), ('events'), ('agent_run_steps'), ('telegram_conversation_turns'), ('telegram_conversations'), ('telegram_assistant_runs'), ('telegram_assistant_steps'), ('telegram_prepared_actions'), ('agent_runs'), ('operator_events'), ('user_memory_profiles'), ('operator_memory_summaries'), ('background_jobs'), ('scheduled_jobs'), ('runtime_ingress_receipts'), ('snapshots'), ('agent_work_results')
        ) AS source(table_name)
        WHERE NOT has_table_privilege(
                'maraithon_payload_verifier', 'public.' || source.table_name, 'SELECT')
           OR has_table_privilege(
                'maraithon_payload_verifier', 'public.' || source.table_name, 'INSERT')
           OR has_table_privilege(
                'maraithon_payload_verifier', 'public.' || source.table_name, 'UPDATE')
           OR has_table_privilege(
                'maraithon_payload_verifier', 'public.' || source.table_name, 'DELETE')
           OR has_table_privilege(
                'maraithon_payload_verifier', 'public.' || source.table_name, 'TRUNCATE')
           OR has_table_privilege(
                'maraithon_payload_verifier', 'public.' || source.table_name, 'REFERENCES')
           OR has_table_privilege(
                'maraithon_payload_verifier', 'public.' || source.table_name, 'TRIGGER')
      ) THEN
        RETURN false;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM (
          VALUES
            ('public.durable_payload_verifications'::regclass,
             ARRAY[owner_oid, verifier_oid, activation_oid]),
            ('public.durable_payload_verification_failures'::regclass,
             ARRAY[owner_oid, verifier_oid, activation_oid]),
            ('public.vault_reencryption_failures'::regclass,
             ARRAY[owner_oid, incident_oid]),
            ('public.vault_backup_retirement_evidence'::regclass,
             ARRAY[owner_oid, incident_oid]),
            ('public.durable_payload_binding_operations'::regclass,
             ARRAY[owner_oid, incident_oid, activation_oid]),
            ('public.key_retirement_zero_proofs'::regclass,
             ARRAY[owner_oid, incident_oid]),
            ('public.durable_payload_key_fence_state'::regclass,
             ARRAY[owner_oid]),
            ('public.retired_durable_payload_keys'::regclass,
             ARRAY[owner_oid, incident_oid])
        ) AS controlled(relation_id, allowed_grantees)
        JOIN pg_catalog.pg_class AS relation ON relation.oid = controlled.relation_id
        CROSS JOIN LATERAL pg_catalog.aclexplode(
          COALESCE(relation.relacl, pg_catalog.acldefault('r', relation.relowner))
        ) AS acl
        WHERE acl.grantee = 0 OR NOT (acl.grantee = ANY(controlled.allowed_grantees))
      ) THEN
        RETURN false;
      END IF;

      IF NOT (
        has_function_privilege('maraithon_runtime',
          'public.durable_payload_key_write_fenced(text,text)', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_payload_verifier',
          'public.durable_payload_key_write_fenced(text,text)', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_incident_operator',
          'public.durable_payload_key_write_fenced(text,text)', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_activation_operator',
          'public.durable_payload_key_write_fenced(text,text)', 'EXECUTE') AND
        has_function_privilege('maraithon_runtime',
          'public.snapshot_writer_authority_valid(uuid,uuid)', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_payload_verifier',
          'public.snapshot_writer_authority_valid(uuid,uuid)', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_incident_operator',
          'public.snapshot_writer_authority_valid(uuid,uuid)', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_activation_operator',
          'public.snapshot_writer_authority_valid(uuid,uuid)', 'EXECUTE') AND
        has_function_privilege('maraithon_runtime',
          'public.delete_durable_payload_verification(text,text)', 'EXECUTE') AND
        has_function_privilege('maraithon_payload_verifier',
          'public.delete_durable_payload_verification(text,text)', 'EXECUTE') AND
        has_function_privilege('maraithon_incident_operator',
          'public.delete_durable_payload_verification(text,text)', 'EXECUTE') AND
        has_function_privilege('maraithon_activation_operator',
          'public.delete_durable_payload_verification(text,text)', 'EXECUTE') AND
        has_function_privilege('maraithon_incident_operator',
          'public.durable_payload_source_acl_ready()', 'EXECUTE') AND
        has_function_privilege('maraithon_incident_operator',
          'public.durable_payload_roles_ready()', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_incident_operator',
          'public.durable_payload_operator_mutation_authorized()', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_activation_operator',
          'public.durable_payload_operator_mutation_authorized()', 'EXECUTE') AND
        has_function_privilege('maraithon_incident_operator',
          'public.durable_payload_operator_row_mutation_authorized(regclass,text,jsonb,jsonb)',
          'EXECUTE') AND
        has_function_privilege('maraithon_activation_operator',
          'public.durable_payload_operator_row_mutation_authorized(regclass,text,jsonb,jsonb)',
          'EXECUTE') AND
        NOT has_function_privilege('maraithon_incident_operator',
          'public.guard_durable_payload_operator_source_mutation()', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_activation_operator',
          'public.guard_durable_payload_operator_source_mutation()', 'EXECUTE') AND
        has_function_privilege('maraithon_incident_operator',
          'public.lock_durable_payload_binding_sources()', 'EXECUTE') AND
        has_function_privilege('maraithon_activation_operator',
          'public.lock_durable_runtime_activation_sources()', 'EXECUTE') AND
        has_function_privilege('maraithon_activation_operator',
          'public.lock_durable_payload_contraction_sources()', 'EXECUTE') AND
        has_function_privilege('maraithon_activation_operator',
          'public.lock_durable_payload_contraction_coordination()', 'EXECUTE') AND
        has_function_privilege('maraithon_incident_operator',
          'public.durable_payload_old_key_live_count(text,text)', 'EXECUTE') AND
        has_function_privilege('maraithon_incident_operator',
          'public.durable_payload_key_registry_definition(text)', 'EXECUTE') AND
        has_function_privilege('maraithon_incident_operator',
          'public.durable_payload_old_key_source_digest(text,text)', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_incident_operator',
          'public.advance_durable_payload_key_fence_epoch(text,text,uuid)', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_runtime',
          'public.advance_durable_payload_key_fence_epoch(text, text, uuid)', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_payload_verifier',
          'public.advance_durable_payload_key_fence_epoch(text, text, uuid)', 'EXECUTE') AND
        NOT has_function_privilege('maraithon_activation_operator',
          'public.advance_durable_payload_key_fence_epoch(text, text, uuid)', 'EXECUTE')
      ) THEN
        RETURN false;
      END IF;

      RETURN true;
    EXCEPTION WHEN no_data_found OR undefined_table OR undefined_function THEN
      RETURN false;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_durable_history_payload_protocol()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      protocol_mode text;
      writer_protocol text;
      valid_shape boolean;
      new_row jsonb;
      old_row jsonb;
    BEGIN
      new_row := to_jsonb(NEW);
      old_row := to_jsonb(OLD);

      SELECT mode INTO STRICT protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF protocol_mode = 'legacy' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
      END IF;

      IF protocol_mode <> 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Unknown durable history payload protocol mode'
          USING ERRCODE = 'check_violation';
      END IF;

      writer_protocol := current_setting('maraithon.effect_writer_protocol', true);

      IF writer_protocol IS DISTINCT FROM 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Exact durable history mutation requires generation-fenced writer marker'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      IF TG_OP = 'UPDATE'
         AND current_user = 'maraithon_migrator'
         AND current_setting('maraithon.vault_reencryption', true) = 'VAULT_REENCRYPT_V1'
         AND (
           (TG_TABLE_NAME = 'events'
            AND (new_row ->> 'payload_ciphertext' IS NULL) =
                  (old_row ->> 'payload_ciphertext' IS NULL)
            AND (new_row - ARRAY['payload_ciphertext']::text[])
                  IS NOT DISTINCT FROM
                (old_row - ARRAY['payload_ciphertext']::text[])
            AND new_row -> 'payload_ciphertext' IS DISTINCT FROM
                  old_row -> 'payload_ciphertext') OR
           (TG_TABLE_NAME = 'agent_run_steps'
            AND (new_row ->> 'request_payload_ciphertext' IS NULL) =
                  (old_row ->> 'request_payload_ciphertext' IS NULL)
            AND (new_row ->> 'response_payload_ciphertext' IS NULL) =
                  (old_row ->> 'response_payload_ciphertext' IS NULL)
            AND (new_row - ARRAY[
                  'request_payload_ciphertext', 'response_payload_ciphertext', 'updated_at'
                ]::text[]) IS NOT DISTINCT FROM
                (old_row - ARRAY[
                  'request_payload_ciphertext', 'response_payload_ciphertext', 'updated_at'
                ]::text[])
            AND (new_row -> 'request_payload_ciphertext' IS DISTINCT FROM
                   old_row -> 'request_payload_ciphertext' OR
                 new_row -> 'response_payload_ciphertext' IS DISTINCT FROM
                   old_row -> 'response_payload_ciphertext'))
         ) THEN
        RETURN NEW;
      END IF;

      valid_shape := CASE TG_TABLE_NAME
        WHEN 'events' THEN
          new_row -> 'payload' = '{}'::jsonb
          AND (
            (NEW.payload_purged_at IS NULL
              AND NEW.payload_encryption_version = 1
              AND new_row ->> 'payload_ciphertext' IS NOT NULL
              AND NEW.payload_binding_version = 1
              AND NEW.payload_binding_key_tag IS NOT NULL
              AND octet_length(NEW.payload_binding_mac) = 32) OR
            (NEW.payload_purged_at IS NOT NULL
              AND new_row ->> 'payload_ciphertext' IS NULL
              AND NEW.payload_binding_version IS NULL
              AND NEW.payload_binding_key_tag IS NULL
              AND NEW.payload_binding_mac IS NULL)
          )
        WHEN 'agent_run_steps' THEN
          new_row -> 'request_payload' = '{}'::jsonb
          AND new_row -> 'response_payload' = '{}'::jsonb
          AND (
            (NEW.payload_purged_at IS NULL
              AND NEW.payload_encryption_version = 1
              AND new_row ->> 'request_payload_ciphertext' IS NOT NULL
              AND new_row ->> 'response_payload_ciphertext' IS NOT NULL
              AND NEW.payload_binding_version = 1
              AND NEW.payload_binding_key_tag IS NOT NULL
              AND octet_length(NEW.payload_binding_mac) = 32) OR
            (NEW.payload_purged_at IS NOT NULL
              AND new_row ->> 'request_payload_ciphertext' IS NULL
              AND new_row ->> 'response_payload_ciphertext' IS NULL
              AND NEW.payload_binding_version IS NULL
              AND NEW.payload_binding_key_tag IS NULL
              AND NEW.payload_binding_mac IS NULL)
          )
        ELSE false
      END;

      IF NOT (valid_shape IS TRUE) THEN
        RAISE EXCEPTION 'Exact durable history payload must remain encrypted or authoritatively purged'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    EXCEPTION
      WHEN no_data_found THEN
        RAISE EXCEPTION 'Effect execution protocol row is missing'
          USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_operator_mutation_authorized()
    RETURNS boolean
    LANGUAGE sql
    IMMUTABLE
    SET search_path = pg_catalog, public
    AS $function$
      -- Compatibility tombstone. Operator authority is row- and
      -- operation-specific; callers must use the four-argument reviewed helper.
      SELECT false
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.lock_durable_runtime_activation_sources()
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      PERFORM pg_catalog.pg_advisory_xact_lock(20260811, 420);

      LOCK TABLE
        public.runtime_leader_authorities,
        public.runtime_node_incarnations,
        public.runtime_partitions,
        public.runtime_partition_transitions,
        public.agent_runtime_leases,
        public.runtime_task_assignments,
        public.runtime_partition_rebalance_requests,
        public.effects,
        public.agent_directives,
        public.events,
        public.agent_run_steps,
        public.telegram_conversation_turns,
        public.telegram_conversations,
        public.telegram_assistant_runs,
        public.telegram_assistant_steps,
        public.telegram_prepared_actions,
        public.agent_runs,
        public.operator_events,
        public.user_memory_profiles,
        public.operator_memory_summaries,
        public.background_jobs,
        public.scheduled_jobs,
        public.runtime_ingress_receipts,
        public.snapshots,
        public.agent_work_results,
        public.durable_payload_verifications,
        public.durable_payload_verification_failures
      IN SHARE MODE;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.lock_durable_payload_binding_sources()
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      LOCK TABLE
      public.effects,
      public.agent_directives,
      public.events,
      public.agent_run_steps,
      public.telegram_conversation_turns,
      public.telegram_conversations,
      public.telegram_assistant_runs,
      public.telegram_assistant_steps,
      public.telegram_prepared_actions,
      public.agent_runs,
      public.operator_events,
      public.user_memory_profiles,
      public.operator_memory_summaries,
      public.background_jobs,
      public.scheduled_jobs,
      public.runtime_ingress_receipts,
      public.snapshots,
      public.agent_work_results
      IN SHARE MODE;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.lock_durable_payload_contraction_sources()
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      LOCK TABLE
      public.effects,
      public.agent_directives,
      public.events,
      public.agent_run_steps,
      public.telegram_conversation_turns,
      public.telegram_conversations,
      public.telegram_assistant_runs,
      public.telegram_assistant_steps,
      public.telegram_prepared_actions,
      public.agent_runs,
      public.operator_events,
      public.user_memory_profiles,
      public.operator_memory_summaries,
      public.background_jobs,
      public.scheduled_jobs,
      public.runtime_ingress_receipts,
      public.snapshots,
      public.agent_work_results
      IN SHARE ROW EXCLUSIVE MODE;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.lock_durable_payload_contraction_coordination()
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      PERFORM pg_catalog.pg_advisory_xact_lock(20260811, 420);

      LOCK TABLE
        public.runtime_leader_authorities,
        public.runtime_node_incarnations,
        public.runtime_partitions,
        public.runtime_partition_transitions,
        public.agent_runtime_leases,
        public.runtime_task_assignments,
        public.runtime_partition_rebalance_requests
      IN SHARE MODE;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_effect_protocol_one_way()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      active_legacy bigint;
      terminal_legacy bigint;
      runtime_leases bigint;
      runtime_mode text;
      processing_directives bigint;
      running_runs bigint;
      requested_steps bigint;
      unencrypted_effect_payloads bigint;
      unencrypted_directive_payloads bigint;
      durable_payload_proof_failures bigint;
      operator_roles_ready boolean;
      ready_indexes bigint;
      ready_helpers bigint;
      ready_constraints bigint;
      ready_triggers bigint;
      schema_migrations_recorded boolean;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Effect execution protocol row cannot be deleted'
          USING ERRCODE = 'check_violation';
      END IF;

      IF OLD.mode = 'generation_fenced_v1' AND
         NEW.mode IS DISTINCT FROM OLD.mode THEN
        RAISE EXCEPTION 'Effect execution protocol cannot be downgraded'
          USING ERRCODE = 'check_violation';
      END IF;

      IF OLD.mode = 'generation_fenced_v1' AND
         (NEW.activated_at IS DISTINCT FROM OLD.activated_at OR
          NEW.activation_epoch IS DISTINCT FROM OLD.activation_epoch OR
          NEW.activation_evidence_id IS DISTINCT FROM OLD.activation_evidence_id OR
          NEW.activation_evidence_digest IS DISTINCT FROM OLD.activation_evidence_digest OR
          NEW.activated_by IS DISTINCT FROM OLD.activated_by OR
          NEW.exact_revision IS DISTINCT FROM OLD.exact_revision) THEN
        RAISE EXCEPTION 'Activated Effect protocol identity is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      IF OLD.mode = 'legacy' AND NEW.mode = 'generation_fenced_v1' THEN
        IF current_user IS DISTINCT FROM 'maraithon_activation_operator' THEN
          RAISE EXCEPTION 'Effect protocol activation requires exact activation role'
            USING ERRCODE = 'insufficient_privilege';
        END IF;

        SELECT mode INTO STRICT runtime_mode
        FROM public.runtime_coordination_protocols
        WHERE name = 'runtime'
        FOR SHARE;

        IF runtime_mode <> 'dark' THEN
          RAISE EXCEPTION 'Effect protocol activation requires dark runtime coordination'
            USING ERRCODE = 'check_violation';
        END IF;

        IF current_setting('maraithon.effect_protocol_activation', true)
             IS DISTINCT FROM 'generation_fenced_v1' THEN
          RAISE EXCEPTION 'Effect protocol activation requires the cutover barrier'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.activated_at IS NULL OR NEW.activation_epoch IS NULL OR
           NEW.activation_evidence_id IS NULL OR NEW.activation_evidence_digest IS NULL OR
           NEW.activated_by IS NULL OR NEW.exact_revision IS NULL THEN
          RAISE EXCEPTION 'Effect protocol activation identity is incomplete'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.activation_evidence_id IS DISTINCT FROM OLD.activation_evidence_id OR
           NEW.activation_evidence_digest IS DISTINCT FROM OLD.activation_evidence_digest OR
           NEW.activated_by IS DISTINCT FROM OLD.activated_by OR
           NEW.exact_revision IS DISTINCT FROM OLD.exact_revision THEN
          RAISE EXCEPTION 'Effect protocol activation requires pre-attested fleet evidence'
            USING ERRCODE = 'check_violation';
        END IF;

        -- These locks make the safety checks authoritative even if activation
        -- is invoked through direct SQL instead of the Mix task. Queued old
        -- Effect writes resume only after mode is exact and are then rejected
        -- by enforce_effect_execution_protocol().
        PERFORM public.lock_durable_runtime_activation_sources();

        SELECT COUNT(*) INTO runtime_leases
        FROM public.agent_runtime_leases;

        IF runtime_leases <> 0 THEN
          RAISE EXCEPTION 'Effect protocol activation requires drained runtime leases'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT
          (SELECT COUNT(*) FROM public.agent_directives WHERE status = 'processing'),
          (SELECT COUNT(*) FROM public.agent_runs WHERE status = 'running'),
          (SELECT COUNT(*) FROM public.agent_run_steps WHERE status = 'requested')
        INTO processing_directives, running_runs, requested_steps;

        IF processing_directives <> 0 OR running_runs <> 0 OR requested_steps <> 0 THEN
          RAISE EXCEPTION 'Effect protocol activation requires drained durable Agent work'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT
          COUNT(*) FILTER (
            WHERE runtime_owner_generation IS NULL AND
              NOT ((
                (status = 'cancelled' AND result_envelope IS NULL) OR
                (status IN ('completed', 'failed', 'cancelled') AND
                 result_envelope IS NOT NULL AND result_acknowledged_at IS NOT NULL)
              ) IS TRUE) AND
              NOT ((
                status IN ('completed', 'failed', 'cancelled') AND
                result_envelope IS NOT NULL AND result_acknowledged_at IS NULL
              ) IS TRUE)
          ),
          COUNT(*) FILTER (
            WHERE runtime_owner_generation IS NULL AND
                  status IN ('completed', 'failed', 'cancelled') AND
                  result_envelope IS NOT NULL AND
                  result_acknowledged_at IS NULL
          )
        INTO active_legacy, terminal_legacy
        FROM public.effects;

        IF active_legacy <> 0 OR terminal_legacy <> 0 THEN
          RAISE EXCEPTION 'Effect protocol activation requires drained legacy work'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT COUNT(*) INTO unencrypted_effect_payloads
        FROM public.effects
        WHERE payload_encryption_version IS DISTINCT FROM 1
           OR (payload_purged_at IS NULL AND params_ciphertext IS NULL)
           OR (payload_purged_at IS NOT NULL AND
               (params_ciphertext IS NOT NULL OR result_ciphertext IS NOT NULL))
           OR params IS DISTINCT FROM '{"redacted": true}'::jsonb
           OR result IS NOT NULL;

        IF unencrypted_effect_payloads <> 0 THEN
          RAISE EXCEPTION 'Effect protocol activation requires encrypted payload backfill'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT COUNT(*) INTO unencrypted_directive_payloads
        FROM public.agent_directives
        WHERE payload_encryption_version IS DISTINCT FROM 1
           OR (payload_purged_at IS NULL AND payload_ciphertext IS NULL)
           OR payload IS DISTINCT FROM '{"redacted": true}'::jsonb;

        IF unencrypted_directive_payloads <> 0 THEN
          RAISE EXCEPTION 'Effect protocol activation requires encrypted Directive payload backfill'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT public.durable_payload_roles_ready()
        INTO operator_roles_ready;

        IF NOT operator_roles_ready OR
           NOT public.durable_payload_catalog_ready() OR
           NOT public.privacy_protocol_catalog_ready() THEN
          RAISE EXCEPTION 'Effect protocol activation requires separated payload verifier privileges and catalog authority'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT public.durable_payload_proof_failures()
        INTO durable_payload_proof_failures;

        IF durable_payload_proof_failures <> 0 THEN
          RAISE EXCEPTION 'Effect protocol activation requires authenticated durable payload proofs'
            USING ERRCODE = 'check_violation',
                  DETAIL = durable_payload_proof_failures::text;
        END IF;

        SELECT COUNT(*) = 5
        FROM public.schema_migrations
        WHERE version IN (
          20260810132102,
          20260810132103,
          20260810140000,
          20260810140001,
          20260810140005
        )
        INTO schema_migrations_recorded;

        IF NOT schema_migrations_recorded THEN
          RAISE EXCEPTION 'Effect protocol activation requires both recorded exact migrations'
            USING ERRCODE = 'check_violation';
        END IF;

        WITH required(
          function_id,
          expected_volatility,
          expected_language,
          expected_security_definer
        ) AS (
          VALUES
            ('public.generation_fenced_effect_index_matches(text)'::regprocedure, 's'::"char", 'sql', false),
            ('public.generation_fenced_effect_indexes_ready_count()'::regprocedure, 's'::"char", 'sql', false),
            ('public.durable_payload_row_identity(text,text)'::regprocedure, 'i'::"char", 'sql', false),
            ('public.durable_payload_digest_part(text,jsonb,text)'::regprocedure, 'i'::"char", 'sql', false),
            ('public.durable_payload_proof_failures()'::regprocedure, 's'::"char", 'plpgsql', false),
            ('public.durable_payload_roles_ready()'::regprocedure, 's'::"char", 'plpgsql', false),
            ('public.delete_durable_payload_verification(text,text)'::regprocedure, 'v'::"char", 'plpgsql', true)
        )
        SELECT COUNT(*) INTO ready_helpers
        FROM required
        JOIN pg_catalog.pg_proc AS function_row
          ON function_row.oid = required.function_id
         AND function_row.provolatile = required.expected_volatility
         AND function_row.prosecdef = required.expected_security_definer
         AND function_row.proconfig = ARRAY['search_path=pg_catalog, public']::text[]
        JOIN pg_catalog.pg_language AS language_row
          ON language_row.oid = function_row.prolang
         AND language_row.lanname = required.expected_language
        JOIN public.effect_execution_protocol_manifests AS manifest
          ON manifest.name = 'effects'
         AND manifest.function_fingerprints ->> function_row.proname =
               md5(function_row.prosrc);

        IF ready_helpers <> 7 THEN
          RAISE EXCEPTION 'Effect protocol activation requires attested catalog helpers'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT public.generation_fenced_effect_indexes_ready_count()
        INTO ready_indexes;

        IF ready_indexes <> 6 THEN
          RAISE EXCEPTION 'Effect protocol activation requires all exact indexes ready'
            USING ERRCODE = 'check_violation';
        END IF;

        WITH required(relation_id, constraint_name) AS (
          VALUES
            ('public.effect_execution_protocols'::regclass, 'effect_execution_protocol_singleton_check'),
            ('public.effect_execution_protocols'::regclass, 'effect_execution_protocol_mode_check'),
            ('public.effect_execution_protocols'::regclass, 'effect_execution_protocol_activation_shape_check'),
            ('public.effect_execution_protocol_manifests'::regclass,
             'effect_execution_protocol_manifest_singleton_check'),
            ('public.effect_termination_attestations'::regclass,
             'effect_termination_attestations_shape_check'),
            ('public.effects'::regclass, 'effects_execution_status_check'),
            ('public.effects'::regclass, 'effects_generation_fenced_shape_check')
        )
        SELECT COUNT(*) INTO ready_constraints
        FROM required
        JOIN pg_catalog.pg_constraint AS constraint_row
          ON constraint_row.conrelid = required.relation_id
         AND constraint_row.conname = required.constraint_name
         AND constraint_row.contype = 'c'
         AND constraint_row.convalidated
        JOIN public.effect_execution_protocol_manifests AS manifest
          ON manifest.name = 'effects'
         AND manifest.constraint_fingerprints ->> required.constraint_name =
               md5(pg_catalog.pg_get_constraintdef(constraint_row.oid, true));

        IF ready_constraints <> 7 THEN
          RAISE EXCEPTION 'Effect protocol activation requires validated safety constraints'
            USING ERRCODE = 'check_violation';
        END IF;

        WITH required(trigger_name, relation_id, function_id, trigger_type) AS (
          VALUES
            ('enforce_effect_execution_protocol_trigger', 'public.effects'::regclass,
             'public.enforce_effect_execution_protocol()'::regprocedure, 31),
            ('enforce_agent_directive_protocol_trigger', 'public.agent_directives'::regclass,
             'public.enforce_agent_directive_protocol()'::regprocedure, 31),
            ('enforce_effect_protocol_one_way_trigger', 'public.effect_execution_protocols'::regclass,
             'public.enforce_effect_protocol_one_way()'::regprocedure, 27),
            ('enforce_effect_termination_attestation_trigger',
             'public.effect_termination_attestations'::regclass,
             'public.enforce_effect_termination_attestation()'::regprocedure, 31),
            ('reject_effect_protocol_manifest_mutation_trigger',
             'public.effect_execution_protocol_manifests'::regclass,
             'public.reject_effect_protocol_manifest_mutation()'::regprocedure, 27),
            ('reject_effect_protocol_manifest_truncate_trigger',
             'public.effect_execution_protocol_manifests'::regclass,
             'public.reject_durable_effect_truncate()'::regprocedure, 34),
            ('reject_effect_termination_attestations_truncate_trigger',
             'public.effect_termination_attestations'::regclass,
             'public.reject_durable_effect_truncate()'::regprocedure, 34),
            ('reject_effect_protocol_truncate_trigger', 'public.effect_execution_protocols'::regclass,
             'public.reject_durable_effect_truncate()'::regprocedure, 34),
            ('reject_effects_truncate_trigger', 'public.effects'::regclass,
             'public.reject_durable_effect_truncate()'::regprocedure, 34),
            ('guard_durable_payload_verification_write_trigger',
             'public.durable_payload_verifications'::regclass,
             'public.guard_durable_payload_verification_write()'::regprocedure, 23),
            ('guard_durable_payload_verification_failure_write_trigger',
             'public.durable_payload_verification_failures'::regclass,
             'public.guard_durable_payload_verification_failure_write()'::regprocedure, 23),
            ('enforce_durable_history_payload_protocol_trigger', 'public.events'::regclass,
             'public.enforce_durable_history_payload_protocol()'::regprocedure, 31),
            ('enforce_durable_history_payload_protocol_trigger',
             'public.agent_run_steps'::regclass,
             'public.enforce_durable_history_payload_protocol()'::regprocedure, 31),
            ('invalidate_durable_payload_verification_trigger', 'public.effects'::regclass,
             'public.invalidate_durable_payload_verification()'::regprocedure, 29),
            ('invalidate_durable_payload_verification_trigger',
             'public.agent_directives'::regclass,
             'public.invalidate_durable_payload_verification()'::regprocedure, 29),
            ('invalidate_durable_payload_verification_trigger', 'public.events'::regclass,
             'public.invalidate_durable_payload_verification()'::regprocedure, 29),
            ('invalidate_durable_payload_verification_trigger',
             'public.agent_run_steps'::regclass,
             'public.invalidate_durable_payload_verification()'::regprocedure, 29),
            ('reject_durable_payload_verifications_truncate_trigger',
             'public.durable_payload_verifications'::regclass,
             'public.reject_durable_effect_truncate()'::regprocedure, 34),
            ('reject_durable_payload_verification_failures_truncate_trigger',
             'public.durable_payload_verification_failures'::regclass,
             'public.reject_durable_effect_truncate()'::regprocedure, 34)
        )
        SELECT COUNT(*) INTO ready_triggers
        FROM required
        JOIN pg_catalog.pg_trigger AS trigger_row
          ON trigger_row.tgrelid = required.relation_id
         AND trigger_row.tgname = required.trigger_name
         AND trigger_row.tgfoid = required.function_id
         AND trigger_row.tgtype = required.trigger_type
         AND NOT trigger_row.tgisinternal
         AND trigger_row.tgenabled IN ('O', 'A')
        JOIN pg_catalog.pg_proc AS function_row
          ON function_row.oid = required.function_id
         AND function_row.provolatile = 'v'
         AND NOT function_row.prosecdef
         AND function_row.proconfig = ARRAY['search_path=pg_catalog, public']::text[]
        JOIN pg_catalog.pg_language AS language_row
          ON language_row.oid = function_row.prolang
         AND language_row.lanname = 'plpgsql'
        JOIN public.effect_execution_protocol_manifests AS manifest
          ON manifest.name = 'effects'
         AND manifest.function_fingerprints ->> function_row.proname =
               md5(function_row.prosrc);

        IF ready_triggers <> 19 THEN
          RAISE EXCEPTION 'Effect protocol activation requires enabled safety triggers'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_old_key_live_count(
      requested_key_kind text,
      requested_old_tag text
    )
    RETURNS bigint
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      ciphertext_prefix bytea;
      live_count bigint;
    BEGIN
      IF requested_old_tag IS NULL OR
         requested_old_tag !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' THEN
        RETURN NULL;
      END IF;

      IF public.durable_payload_catalog_ready() IS NOT TRUE OR
         public.privacy_protocol_catalog_ready() IS NOT TRUE THEN
        RAISE EXCEPTION 'key retirement catalog authority is not ready'
          USING ERRCODE = 'check_violation';
      END IF;

      IF requested_key_kind = 'binding' THEN
        LOCK TABLE
          public.effects,
          public.agent_directives,
          public.events,
          public.agent_run_steps,
          public.telegram_conversation_turns,
          public.telegram_conversations,
          public.telegram_assistant_runs,
          public.telegram_assistant_steps,
          public.telegram_prepared_actions,
          public.agent_runs,
          public.operator_events,
          public.user_memory_profiles,
          public.operator_memory_summaries,
          public.background_jobs,
          public.scheduled_jobs,
          public.runtime_ingress_receipts,
          public.snapshots,
          public.agent_work_results
        IN SHARE MODE;

        SELECT
          (SELECT count(*) FROM public.effects WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.agent_directives WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.events WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.agent_run_steps WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.telegram_conversation_turns WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.telegram_conversations WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.telegram_assistant_runs WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.telegram_assistant_steps WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.telegram_prepared_actions WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.agent_runs WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.operator_events WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.user_memory_profiles WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.operator_memory_summaries WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.background_jobs WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.scheduled_jobs WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.runtime_ingress_receipts WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.snapshots WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.agent_work_results WHERE payload_binding_key_tag = requested_old_tag) +
          (SELECT count(*) FROM public.agent_work_results WHERE result_digest_key_tag = requested_old_tag)
        INTO live_count;
      ELSIF requested_key_kind = 'vault' THEN
        LOCK TABLE
          public.effects,
          public.agent_directives,
          public.events,
          public.agent_run_steps,
          public.telegram_conversation_turns,
          public.telegram_conversations,
          public.telegram_assistant_runs,
          public.telegram_assistant_steps,
          public.telegram_prepared_actions,
          public.agent_runs,
          public.operator_events,
          public.user_memory_profiles,
          public.operator_memory_summaries,
          public.background_jobs,
          public.scheduled_jobs,
          public.runtime_ingress_receipts,
          public.snapshots,
          public.agent_work_results,
          public.connected_accounts,
          public.oauth_tokens,
          public.local_browser_visits,
          public.local_calendar_events,
          public.local_files,
          public.memory_items
        IN SHARE MODE;

        ciphertext_prefix := pg_catalog.decode(
          '01' || pg_catalog.lpad(pg_catalog.to_hex(
            pg_catalog.octet_length(pg_catalog.convert_to(requested_old_tag, 'UTF8'))
          ), 2, '0') ||
          pg_catalog.encode(pg_catalog.convert_to(requested_old_tag, 'UTF8'), 'hex'),
          'hex'
        );

        SELECT
          (SELECT count(*) FROM public.effects WHERE params_ciphertext IS NOT NULL AND substring(params_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.effects WHERE result_ciphertext IS NOT NULL AND substring(result_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.agent_directives WHERE payload_ciphertext IS NOT NULL AND substring(payload_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.events WHERE payload_ciphertext IS NOT NULL AND substring(payload_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.agent_run_steps WHERE request_payload_ciphertext IS NOT NULL AND substring(request_payload_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.agent_run_steps WHERE response_payload_ciphertext IS NOT NULL AND substring(response_payload_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.telegram_conversation_turns WHERE text_ciphertext IS NOT NULL AND substring(text_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.telegram_conversation_turns WHERE structured_data_ciphertext IS NOT NULL AND substring(structured_data_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.telegram_conversations WHERE summary_ciphertext IS NOT NULL AND substring(summary_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.telegram_conversations WHERE historical_summary_ciphertext IS NOT NULL AND substring(historical_summary_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.telegram_assistant_runs WHERE prompt_snapshot_ciphertext IS NOT NULL AND substring(prompt_snapshot_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.telegram_assistant_runs WHERE result_summary_ciphertext IS NOT NULL AND substring(result_summary_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.telegram_assistant_steps WHERE request_payload_ciphertext IS NOT NULL AND substring(request_payload_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.telegram_assistant_steps WHERE response_payload_ciphertext IS NOT NULL AND substring(response_payload_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.telegram_prepared_actions WHERE payload_ciphertext IS NOT NULL AND substring(payload_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.telegram_prepared_actions WHERE preview_text_ciphertext IS NOT NULL AND substring(preview_text_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.agent_runs WHERE trigger_ciphertext IS NOT NULL AND substring(trigger_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.agent_runs WHERE metadata_ciphertext IS NOT NULL AND substring(metadata_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.operator_events WHERE payload_ciphertext IS NOT NULL AND substring(payload_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.operator_events WHERE metadata_ciphertext IS NOT NULL AND substring(metadata_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.user_memory_profiles WHERE summary_ciphertext IS NOT NULL AND substring(summary_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.user_memory_profiles WHERE profile_ciphertext IS NOT NULL AND substring(profile_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.operator_memory_summaries WHERE content_ciphertext IS NOT NULL AND substring(content_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.background_jobs WHERE payload_ciphertext IS NOT NULL AND substring(payload_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.background_jobs WHERE result_ciphertext IS NOT NULL AND substring(result_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.scheduled_jobs WHERE payload_ciphertext IS NOT NULL AND substring(payload_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.runtime_ingress_receipts WHERE payload_ciphertext IS NOT NULL AND substring(payload_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.snapshots WHERE state_data_ciphertext IS NOT NULL AND substring(state_data_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.snapshots WHERE budget_ciphertext IS NOT NULL AND substring(budget_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.agent_work_results WHERE result_ciphertext IS NOT NULL AND substring(result_ciphertext FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.connected_accounts WHERE access_token IS NOT NULL AND substring(access_token FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.connected_accounts WHERE refresh_token IS NOT NULL AND substring(refresh_token FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.oauth_tokens WHERE access_token IS NOT NULL AND substring(access_token FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.oauth_tokens WHERE refresh_token IS NOT NULL AND substring(refresh_token FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.local_browser_visits WHERE title IS NOT NULL AND substring(title FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.local_calendar_events WHERE title IS NOT NULL AND substring(title FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.local_calendar_events WHERE notes IS NOT NULL AND substring(notes FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.local_files WHERE filename IS NOT NULL AND substring(filename FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.local_files WHERE text_content IS NOT NULL AND substring(text_content FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.memory_items WHERE content IS NOT NULL AND substring(content FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.memory_items WHERE summary IS NOT NULL AND substring(summary FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix) +
          (SELECT count(*) FROM public.memory_items WHERE metadata IS NOT NULL AND substring(metadata FROM 1 FOR octet_length(ciphertext_prefix)) = ciphertext_prefix)
        INTO live_count;
      ELSE
        RETURN NULL;
      END IF;

      RETURN live_count;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_key_registry_definition(
      requested_key_kind text
    )
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    SET search_path = pg_catalog, public
    AS $function$
      SELECT CASE requested_key_kind
        WHEN 'vault' THEN 'effects.params_ciphertext,effects.result_ciphertext,agent_directives.payload_ciphertext,events.payload_ciphertext,agent_run_steps.request_payload_ciphertext,agent_run_steps.response_payload_ciphertext,telegram_conversation_turns.text_ciphertext,telegram_conversation_turns.structured_data_ciphertext,telegram_conversations.summary_ciphertext,telegram_conversations.historical_summary_ciphertext,telegram_assistant_runs.prompt_snapshot_ciphertext,telegram_assistant_runs.result_summary_ciphertext,telegram_assistant_steps.request_payload_ciphertext,telegram_assistant_steps.response_payload_ciphertext,telegram_prepared_actions.payload_ciphertext,telegram_prepared_actions.preview_text_ciphertext,agent_runs.trigger_ciphertext,agent_runs.metadata_ciphertext,operator_events.payload_ciphertext,operator_events.metadata_ciphertext,user_memory_profiles.summary_ciphertext,user_memory_profiles.profile_ciphertext,operator_memory_summaries.content_ciphertext,background_jobs.payload_ciphertext,background_jobs.result_ciphertext,scheduled_jobs.payload_ciphertext,runtime_ingress_receipts.payload_ciphertext,snapshots.state_data_ciphertext,snapshots.budget_ciphertext,agent_work_results.result_ciphertext,connected_accounts.access_token,connected_accounts.refresh_token,oauth_tokens.access_token,oauth_tokens.refresh_token,local_browser_visits.title,local_calendar_events.title,local_calendar_events.notes,local_files.filename,local_files.text_content,memory_items.content,memory_items.summary,memory_items.metadata'
        WHEN 'binding' THEN 'effects:payload,agent_directives:payload,events:payload,agent_run_steps:payload,telegram_conversation_turns:payload,telegram_conversations:payload,telegram_assistant_runs:payload,telegram_assistant_steps:payload,telegram_prepared_actions:payload,agent_runs:payload,operator_events:payload,user_memory_profiles:payload,operator_memory_summaries:payload,background_jobs:payload,scheduled_jobs:payload,runtime_ingress_receipts:payload,snapshots:payload,agent_work_results:payload,agent_work_results:authority'
        ELSE NULL::text
      END
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_old_key_source_digest(
      requested_key_kind text,
      requested_old_tag text
    )
    RETURNS bytea
    LANGUAGE sql
    VOLATILE
    SET search_path = pg_catalog, public
    AS $function$
      SELECT CASE
        WHEN requested_key_kind IN ('vault', 'binding') AND
             requested_old_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
        THEN public.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
          'registry', 'durable_payload_key_registry_v1',
          'key_kind', requested_key_kind,
          'old_tag', requested_old_tag,
          'registry_definition', public.durable_payload_key_registry_definition(
            requested_key_kind
          ),
          'live_count', public.durable_payload_old_key_live_count(
            requested_key_kind, requested_old_tag
          ),
          'vault_ciphertext_targets', 42,
          'binding_targets', 19
        )::text, 'UTF8'), 'sha256')
        ELSE NULL::bytea
      END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_ciphertext_key_tag(ciphertext bytea)
    RETURNS text
    LANGUAGE plpgsql
    IMMUTABLE
    STRICT
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      tag_length integer;
      decoded_tag text;
    BEGIN
      IF pg_catalog.octet_length(ciphertext) < 3 OR
         pg_catalog.get_byte(ciphertext, 0) <> 1 THEN
        RETURN NULL;
      END IF;

      tag_length := pg_catalog.get_byte(ciphertext, 1);

      IF tag_length NOT BETWEEN 1 AND 64 OR
         pg_catalog.octet_length(ciphertext) < tag_length + 2 THEN
        RETURN NULL;
      END IF;

      decoded_tag := pg_catalog.convert_from(
        pg_catalog.substring(ciphertext, 3, tag_length), 'UTF8'
      );

      IF decoded_tag !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' THEN
        RETURN NULL;
      END IF;

      RETURN decoded_tag;
    EXCEPTION WHEN OTHERS THEN
      RETURN NULL;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.advance_durable_payload_key_fence_epoch(
      requested_kind text,
      requested_tag text,
      requested_proof_id uuid
    )
    RETURNS bigint
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      next_generation bigint;
    BEGIN
      IF current_setting('maraithon.key_retirement_zero_proof', true)
           IS DISTINCT FROM 'LIVE_ZERO_PROOF_V1' OR
         (session_user IS DISTINCT FROM 'maraithon_incident_operator' AND
          current_setting('role', true) IS DISTINCT FROM 'maraithon_incident_operator') THEN
        RAISE EXCEPTION 'Key fence advancement requires incident zero-proof authority'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF requested_kind NOT IN ('vault', 'binding') OR
         requested_tag !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' OR
         requested_proof_id IS NULL THEN
        RAISE EXCEPTION 'Key fence advancement arguments are invalid'
          USING ERRCODE = 'check_violation';
      END IF;

      PERFORM 1
      FROM public.durable_payload_key_fence_state
      WHERE singleton IS TRUE
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Durable payload key fence state is missing'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM public.retired_durable_payload_keys
        WHERE key_kind = requested_kind
          AND old_tag = requested_tag
      ) THEN
        RAISE EXCEPTION 'Durable payload key tag already has final removal authorization'
          USING ERRCODE = 'check_violation';
      END IF;

      PERFORM set_config('maraithon.key_fence_kind', requested_kind, true);
      PERFORM set_config('maraithon.key_fence_tag', requested_tag, true);
      PERFORM set_config('maraithon.key_fence_proof_id', requested_proof_id::text, true);

      UPDATE public.durable_payload_key_fence_state
      SET generation = generation + 1,
          fences = pg_catalog.jsonb_set(
            fences,
            ARRAY[requested_kind, requested_tag],
            pg_catalog.to_jsonb(requested_proof_id::text),
            true
          ),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE singleton IS TRUE
        AND fences #>> ARRAY[requested_kind, requested_tag]
              IS DISTINCT FROM requested_proof_id::text
      RETURNING generation INTO next_generation;

      IF next_generation IS NULL THEN
        RAISE EXCEPTION 'Durable payload key fence state is missing or proof is already current'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN next_generation;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.guard_durable_payload_key_fence_state()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      expected_kind text := current_setting('maraithon.key_fence_kind', true);
      expected_tag text := current_setting('maraithon.key_fence_tag', true);
      expected_proof_id text := current_setting('maraithon.key_fence_proof_id', true);
      zero_proof_transition boolean :=
        current_setting('maraithon.key_retirement_zero_proof', true)
          IS NOT DISTINCT FROM 'LIVE_ZERO_PROOF_V1';
      retirement_finalization boolean :=
        current_setting('maraithon.key_retirement_finalization', true)
          IS NOT DISTINCT FROM 'FINAL_REMOVAL_AUTHORIZATION_V1';
      old_fence_count bigint;
      new_fence_count bigint;
    BEGIN
      IF TG_OP <> 'UPDATE' OR
         current_user IS DISTINCT FROM 'maraithon_object_owner' OR
         zero_proof_transition = retirement_finalization THEN
        RAISE EXCEPTION 'Durable payload key fence state is immutable'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF expected_kind NOT IN ('vault', 'binding') OR
         expected_tag !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' OR
         expected_proof_id !~
           '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' OR
         NEW.singleton IS DISTINCT FROM OLD.singleton OR
         NEW.singleton IS NOT TRUE OR
         NEW.generation IS DISTINCT FROM OLD.generation + 1 OR
         NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at OR
         NEW.fences #>> ARRAY[expected_kind, expected_tag]
           IS DISTINCT FROM expected_proof_id THEN
        RAISE EXCEPTION 'Durable payload key fence transition is invalid'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT
        (SELECT count(*) FROM pg_catalog.jsonb_each(OLD.fences -> 'vault')) +
        (SELECT count(*) FROM pg_catalog.jsonb_each(OLD.fences -> 'binding')),
        (SELECT count(*) FROM pg_catalog.jsonb_each(NEW.fences -> 'vault')) +
        (SELECT count(*) FROM pg_catalog.jsonb_each(NEW.fences -> 'binding'))
      INTO STRICT old_fence_count, new_fence_count;

      IF retirement_finalization THEN
        IF NEW.fences IS DISTINCT FROM OLD.fences OR
           new_fence_count IS DISTINCT FROM old_fence_count OR
           NOT EXISTS (
             SELECT 1
             FROM public.retired_durable_payload_keys AS retirement
             WHERE retirement.key_kind = expected_kind
               AND retirement.old_tag = expected_tag
               AND retirement.zero_proof_id::text = expected_proof_id
           ) THEN
          RAISE EXCEPTION 'Durable payload key fence finalization is invalid'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END IF;

      IF (OLD.fences -> expected_kind) ? expected_tag THEN
        IF OLD.fences #>> ARRAY[expected_kind, expected_tag]
             IS NOT DISTINCT FROM expected_proof_id OR
           new_fence_count IS DISTINCT FROM old_fence_count OR
           EXISTS (
             SELECT 1
             FROM (
               SELECT 'vault'::text AS key_kind, key, value
               FROM pg_catalog.jsonb_each_text(OLD.fences -> 'vault')
               UNION ALL
               SELECT 'binding'::text AS key_kind, key, value
               FROM pg_catalog.jsonb_each_text(OLD.fences -> 'binding')
             ) AS prior
             WHERE (prior.key_kind, prior.key) IS DISTINCT FROM
                     (expected_kind, expected_tag)
               AND NEW.fences #>> ARRAY[prior.key_kind, prior.key]
                     IS DISTINCT FROM prior.value
           ) THEN
          RAISE EXCEPTION 'Durable payload key proof refresh is invalid'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF new_fence_count IS DISTINCT FROM old_fence_count + 1 OR
            EXISTS (
              SELECT 1
              FROM (
                SELECT 'vault'::text AS key_kind, key, value
                FROM pg_catalog.jsonb_each_text(OLD.fences -> 'vault')
                UNION ALL
                SELECT 'binding'::text AS key_kind, key, value
                FROM pg_catalog.jsonb_each_text(OLD.fences -> 'binding')
              ) AS prior
              WHERE NEW.fences #>> ARRAY[prior.key_kind, prior.key]
                IS DISTINCT FROM prior.value
            ) THEN
        RAISE EXCEPTION 'Durable payload key fences cannot be removed or replaced'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS guard_durable_payload_key_fence_state_trigger " <>
        "ON public.durable_payload_key_fence_state"
    )

    execute("""
    CREATE TRIGGER guard_durable_payload_key_fence_state_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.durable_payload_key_fence_state
      FOR EACH ROW EXECUTE FUNCTION public.guard_durable_payload_key_fence_state()
    """)

    execute("""
    ALTER TABLE public.durable_payload_key_fence_state
      ENABLE ALWAYS TRIGGER guard_durable_payload_key_fence_state_trigger
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_durable_payload_key_fence_state_truncate_trigger " <>
        "ON public.durable_payload_key_fence_state"
    )

    execute("""
    CREATE TRIGGER reject_durable_payload_key_fence_state_truncate_trigger
      BEFORE TRUNCATE ON public.durable_payload_key_fence_state
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_key_write_fenced(
      requested_kind text,
      requested_tag text
    )
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      fence_state jsonb;
    BEGIN
      IF requested_kind NOT IN ('vault', 'binding') OR
         requested_tag !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' THEN
        RAISE EXCEPTION 'Durable payload key fence lookup is invalid'
          USING ERRCODE = 'check_violation';
      END IF;

      IF public.durable_payload_catalog_ready() IS NOT TRUE OR
         public.privacy_protocol_catalog_ready() IS NOT TRUE THEN
        RAISE EXCEPTION 'Durable payload key fence catalog authority is not ready'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT fences INTO STRICT fence_state
      FROM public.durable_payload_key_fence_state
      WHERE singleton IS TRUE;

      RETURN (fence_state -> requested_kind) ? requested_tag;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Durable payload key fence state is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.guard_durable_payload_retired_key_write()
    RETURNS trigger
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      new_row jsonb := to_jsonb(NEW);
      old_row jsonb := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
      vault_fields text[];
      field_name text;
      encoded_value text;
      candidate_tag text;
      candidate_vault_tags text[] := ARRAY[]::text[];
      candidate_binding_tags text[] := ARRAY[]::text[];
      fence_state jsonb;
    BEGIN
      vault_fields := CASE TG_TABLE_NAME
        WHEN 'connected_accounts' THEN ARRAY['access_token', 'refresh_token']
        WHEN 'oauth_tokens' THEN ARRAY['access_token', 'refresh_token']
        WHEN 'local_browser_visits' THEN ARRAY['title']
        WHEN 'local_calendar_events' THEN ARRAY['title', 'notes']
        WHEN 'local_files' THEN ARRAY['filename', 'text_content']
        WHEN 'memory_items' THEN ARRAY['content', 'summary', 'metadata']
        WHEN 'effects' THEN ARRAY['params_ciphertext', 'result_ciphertext']
        WHEN 'agent_directives' THEN ARRAY['payload_ciphertext']
        WHEN 'events' THEN ARRAY['payload_ciphertext']
        WHEN 'agent_run_steps' THEN
          ARRAY['request_payload_ciphertext', 'response_payload_ciphertext']
        WHEN 'telegram_conversation_turns' THEN
          ARRAY['text_ciphertext', 'structured_data_ciphertext']
        WHEN 'telegram_conversations' THEN
          ARRAY['summary_ciphertext', 'historical_summary_ciphertext']
        WHEN 'telegram_assistant_runs' THEN
          ARRAY['prompt_snapshot_ciphertext', 'result_summary_ciphertext']
        WHEN 'telegram_assistant_steps' THEN
          ARRAY['request_payload_ciphertext', 'response_payload_ciphertext']
        WHEN 'telegram_prepared_actions' THEN
          ARRAY['payload_ciphertext', 'preview_text_ciphertext']
        WHEN 'agent_runs' THEN ARRAY['trigger_ciphertext', 'metadata_ciphertext']
        WHEN 'operator_events' THEN ARRAY['payload_ciphertext', 'metadata_ciphertext']
        WHEN 'user_memory_profiles' THEN ARRAY['summary_ciphertext', 'profile_ciphertext']
        WHEN 'operator_memory_summaries' THEN ARRAY['content_ciphertext']
        WHEN 'background_jobs' THEN ARRAY['payload_ciphertext', 'result_ciphertext']
        WHEN 'scheduled_jobs' THEN ARRAY['payload_ciphertext']
        WHEN 'runtime_ingress_receipts' THEN ARRAY['payload_ciphertext']
        WHEN 'snapshots' THEN ARRAY['state_data_ciphertext', 'budget_ciphertext']
        WHEN 'agent_work_results' THEN ARRAY['result_ciphertext']
        ELSE NULL::text[]
      END;

      IF vault_fields IS NULL THEN
        RAISE EXCEPTION 'Retired-key guard attached outside the fixed payload registry'
          USING ERRCODE = 'check_violation';
      END IF;

      FOREACH field_name IN ARRAY vault_fields LOOP
        IF new_row -> field_name IS DISTINCT FROM old_row -> field_name THEN
          encoded_value := new_row ->> field_name;

          IF encoded_value IS NOT NULL THEN
            candidate_tag := public.durable_payload_ciphertext_key_tag(encoded_value::bytea);

            IF candidate_tag IS NULL THEN
              RAISE EXCEPTION 'Changed durable ciphertext has an invalid key tag envelope'
                USING ERRCODE = 'check_violation';
            END IF;

            candidate_vault_tags := pg_catalog.array_append(
              candidate_vault_tags, candidate_tag
            );
          END IF;
        END IF;
      END LOOP;

      IF new_row -> 'payload_binding_key_tag' IS DISTINCT FROM
           old_row -> 'payload_binding_key_tag' AND
         new_row ->> 'payload_binding_key_tag' IS NOT NULL THEN
        candidate_binding_tags := pg_catalog.array_append(
          candidate_binding_tags, new_row ->> 'payload_binding_key_tag'
        );
      END IF;

      IF TG_TABLE_NAME = 'agent_work_results' AND
         new_row -> 'result_digest_key_tag' IS DISTINCT FROM
           old_row -> 'result_digest_key_tag' AND
         new_row ->> 'result_digest_key_tag' IS NOT NULL THEN
        candidate_binding_tags := pg_catalog.array_append(
          candidate_binding_tags, new_row ->> 'result_digest_key_tag'
        );
      END IF;

      IF pg_catalog.cardinality(candidate_vault_tags) = 0 AND
         pg_catalog.cardinality(candidate_binding_tags) = 0 THEN
        RETURN NEW;
      END IF;

      SELECT fences INTO STRICT fence_state
      FROM public.durable_payload_key_fence_state
      WHERE singleton IS TRUE
      FOR SHARE;

      IF (fence_state -> 'vault') ?| candidate_vault_tags OR
         (fence_state -> 'binding') ?| candidate_binding_tags THEN
        RAISE EXCEPTION 'Durable payload write uses an irreversibly fenced key tag'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Durable payload key fence authority is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute("""
    DO $retired_key_triggers$
    DECLARE
      source_relation text;
    BEGIN
      FOREACH source_relation IN ARRAY ARRAY[
        'connected_accounts', 'oauth_tokens', 'local_browser_visits',
        'local_calendar_events', 'local_files', 'memory_items',
        'effects', 'agent_directives', 'events', 'agent_run_steps',
        'telegram_conversation_turns', 'telegram_conversations',
        'telegram_assistant_runs', 'telegram_assistant_steps',
        'telegram_prepared_actions', 'agent_runs', 'operator_events',
        'user_memory_profiles', 'operator_memory_summaries',
        'background_jobs', 'scheduled_jobs', 'runtime_ingress_receipts',
        'agent_work_results', 'snapshots'
      ] LOOP
        EXECUTE pg_catalog.format(
          'DROP TRIGGER IF EXISTS guard_durable_payload_retired_key_write_trigger ON public.%I',
          source_relation
        );
        EXECUTE pg_catalog.format(
          'CREATE TRIGGER guard_durable_payload_retired_key_write_trigger ' ||
          'BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW ' ||
          'EXECUTE FUNCTION public.guard_durable_payload_retired_key_write()',
          source_relation
        );
        EXECUTE pg_catalog.format(
          'ALTER TABLE public.%I ENABLE ALWAYS TRIGGER ' ||
          'guard_durable_payload_retired_key_write_trigger',
          source_relation
        );
      END LOOP;
    END
    $retired_key_triggers$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.guard_durable_payload_binding_operation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      runtime_mode text;
      effect_mode text;
      stored_evidence_id text;
      stored_evidence_digest bytea;
      stored_evidence_operator text;
      stored_exact_revision text;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Durable payload binding progress cannot be deleted'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      -- Protocol rows are always locked runtime-first, then Effect. A session
      -- GUC is only a scoped capability; immutable stored evidence is the
      -- authority for every accepted operation row.
      SELECT mode INTO STRICT runtime_mode
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime'
      FOR SHARE;

      SELECT mode, activation_evidence_id, activation_evidence_digest,
             activated_by, exact_revision
      INTO STRICT effect_mode, stored_evidence_id, stored_evidence_digest,
                  stored_evidence_operator, stored_exact_revision
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF NEW.operation_kind = 'legacy_context_rebind_v1' THEN
        IF current_user IS DISTINCT FROM 'maraithon_activation_operator' OR
           current_setting('maraithon.payload_contraction', true)
             IS DISTINCT FROM 'STOPPED_FLEET_EVIDENCE_V1' THEN
          RAISE EXCEPTION 'Legacy binding context promotion requires stopped-fleet activation authority'
            USING ERRCODE = 'insufficient_privilege';
        END IF;

        IF runtime_mode <> 'dark' OR effect_mode <> 'legacy' THEN
          RAISE EXCEPTION 'Legacy binding context promotion requires the dark legacy pair'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF NEW.operation_kind = 'binding_key_rotation_v1' THEN
        IF current_user IS DISTINCT FROM 'maraithon_incident_operator' OR
           current_setting('maraithon.binding_key_rotation', true)
             IS DISTINCT FROM 'BINDING_KEY_ROTATION_V1' THEN
          RAISE EXCEPTION 'Binding key rotation progress requires incident authority'
            USING ERRCODE = 'insufficient_privilege';
        END IF;

        IF runtime_mode <> 'partition_fenced_v1' OR
           effect_mode <> 'generation_fenced_v1' THEN
          RAISE EXCEPTION 'Binding key rotation requires the active exact pair'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSE
        RAISE EXCEPTION 'Unknown durable payload binding operation'
          USING ERRCODE = 'check_violation';
      END IF;

      IF stored_evidence_id IS NULL OR stored_evidence_digest IS NULL OR
         pg_catalog.octet_length(stored_evidence_digest) <> 32 OR
         stored_evidence_operator IS NULL OR stored_exact_revision IS NULL OR
         NEW.evidence_id IS DISTINCT FROM stored_evidence_id OR
         NEW.evidence_digest IS DISTINCT FROM stored_evidence_digest OR
         NEW.evidence_operator IS DISTINCT FROM stored_evidence_operator OR
         NEW.exact_revision IS DISTINCT FROM stored_exact_revision THEN
        RAISE EXCEPTION 'Durable payload binding operation evidence does not match protocol authority'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT public.durable_payload_catalog_ready() OR
         NOT public.privacy_protocol_catalog_ready() THEN
        RAISE EXCEPTION 'Durable payload binding operation catalog authority is not ready'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND (
        NEW.operation_kind IS DISTINCT FROM OLD.operation_kind OR
        NEW.payload_table IS DISTINCT FROM OLD.payload_table OR
        NEW.binding_name IS DISTINCT FROM OLD.binding_name OR
        NEW.row_identity IS DISTINCT FROM OLD.row_identity OR
        NEW.target_key_tag IS DISTINCT FROM OLD.target_key_tag
      ) THEN
        RAISE EXCEPTION 'Durable payload binding progress identity is immutable'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      NEW.attempted_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Durable payload binding operation protocol authority is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS guard_durable_payload_binding_operation_trigger " <>
        "ON public.durable_payload_binding_operations"
    )

    execute("""
    CREATE TRIGGER guard_durable_payload_binding_operation_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.durable_payload_binding_operations
      FOR EACH ROW EXECUTE FUNCTION public.guard_durable_payload_binding_operation()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.guard_key_retirement_zero_proof()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      runtime_mode text;
      effect_mode text;
      stored_evidence_id text;
      stored_evidence_digest bytea;
      stored_evidence_operator text;
      stored_exact_revision text;
      live_count bigint;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Key retirement zero proofs are append-only'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF (session_user IS DISTINCT FROM 'maraithon_incident_operator' AND
          current_setting('role', true) IS DISTINCT FROM 'maraithon_incident_operator') OR
         current_setting('maraithon.key_retirement_zero_proof', true)
           IS DISTINCT FROM 'LIVE_ZERO_PROOF_V1' THEN
        RAISE EXCEPTION 'Key retirement zero proof requires incident authority'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      SELECT mode INTO STRICT runtime_mode
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime'
      FOR SHARE;

      SELECT mode, activation_evidence_id, activation_evidence_digest,
             activated_by, exact_revision
      INTO STRICT effect_mode, stored_evidence_id, stored_evidence_digest,
                  stored_evidence_operator, stored_exact_revision
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF runtime_mode <> 'partition_fenced_v1' OR
         effect_mode <> 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Key retirement zero proof requires the active exact pair'
          USING ERRCODE = 'check_violation';
      END IF;

      IF stored_evidence_id IS NULL OR stored_evidence_digest IS NULL OR
         pg_catalog.octet_length(stored_evidence_digest) <> 32 OR
         stored_evidence_operator IS NULL OR stored_exact_revision IS NULL OR
         NEW.evidence_id IS DISTINCT FROM stored_evidence_id OR
         NEW.evidence_digest IS DISTINCT FROM stored_evidence_digest OR
         NEW.evidence_operator IS DISTINCT FROM stored_evidence_operator OR
         NEW.exact_revision IS DISTINCT FROM stored_exact_revision THEN
        RAISE EXCEPTION 'Key retirement zero proof evidence does not match protocol authority'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT public.durable_payload_catalog_ready() OR
         NOT public.privacy_protocol_catalog_ready() THEN
        RAISE EXCEPTION 'Key retirement zero proof catalog authority is not ready'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.key_kind NOT IN ('vault', 'binding') THEN
        RAISE EXCEPTION 'Unknown key retirement kind'
          USING ERRCODE = 'check_violation';
      END IF;

      live_count := public.durable_payload_old_key_live_count(NEW.key_kind, NEW.old_tag);

      IF live_count IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'Key retirement zero proof rejected because live old-key rows remain'
          USING ERRCODE = 'check_violation';
      END IF;

      NEW.source_digest := public.durable_payload_old_key_source_digest(
        NEW.key_kind, NEW.old_tag
      );

      IF pg_catalog.octet_length(NEW.source_digest) <> 32 THEN
        RAISE EXCEPTION 'Key retirement zero proof registry digest is unavailable'
          USING ERRCODE = 'check_violation';
      END IF;

      NEW.proved_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Key retirement zero proof protocol authority is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS guard_key_retirement_zero_proof_trigger " <>
        "ON public.key_retirement_zero_proofs"
    )

    execute("""
    CREATE TRIGGER guard_key_retirement_zero_proof_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.key_retirement_zero_proofs
      FOR EACH ROW EXECUTE FUNCTION public.guard_key_retirement_zero_proof()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.sync_durable_payload_key_fence_from_zero_proof()
    RETURNS trigger
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      -- The BEFORE proof guard still holds every fixed source SHARE lock.
      -- Updating the pre-existing state row after the proof insert makes stale
      -- REPEATABLE READ writers fail serialization and binds one fence advance
      -- to one durable proof in the same transaction.
      PERFORM public.advance_durable_payload_key_fence_epoch(
        NEW.key_kind, NEW.old_tag, NEW.proof_id
      );
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS sync_durable_payload_key_fence_from_zero_proof_trigger " <>
        "ON public.key_retirement_zero_proofs"
    )

    execute("""
    CREATE TRIGGER sync_durable_payload_key_fence_from_zero_proof_trigger
      AFTER INSERT ON public.key_retirement_zero_proofs
      FOR EACH ROW EXECUTE FUNCTION public.sync_durable_payload_key_fence_from_zero_proof()
    """)

    execute("""
    ALTER TABLE public.key_retirement_zero_proofs
      ENABLE ALWAYS TRIGGER guard_key_retirement_zero_proof_trigger
    """)

    execute("""
    ALTER TABLE public.key_retirement_zero_proofs
      ENABLE ALWAYS TRIGGER sync_durable_payload_key_fence_from_zero_proof_trigger
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_durable_payload_binding_operations_truncate_trigger " <>
        "ON public.durable_payload_binding_operations"
    )

    execute("""
    CREATE TRIGGER reject_durable_payload_binding_operations_truncate_trigger
      BEFORE TRUNCATE ON public.durable_payload_binding_operations
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_key_retirement_zero_proofs_truncate_trigger " <>
        "ON public.key_retirement_zero_proofs"
    )

    execute("""
    CREATE TRIGGER reject_key_retirement_zero_proofs_truncate_trigger
      BEFORE TRUNCATE ON public.key_retirement_zero_proofs
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.guard_vault_backup_retirement_evidence()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      runtime_mode text;
      effect_mode text;
      stored_evidence_id text;
      stored_evidence_digest bytea;
      stored_evidence_operator text;
      stored_exact_revision text;
      proof_evidence_id text;
      proof_evidence_digest bytea;
      proof_evidence_operator text;
      proof_exact_revision text;
      proof_source_digest bytea;
      proof_proved_at timestamp(6) without time zone;
      database_now timestamp(6) without time zone;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Vault backup retirement evidence is append-only'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF (session_user IS DISTINCT FROM 'maraithon_incident_operator' AND
          current_setting('role', true) IS DISTINCT FROM 'maraithon_incident_operator') OR
         current_setting('maraithon.vault_backup_evidence', true)
           IS DISTINCT FROM 'BACKUP_CATALOG_ATTESTED_V1' THEN
        RAISE EXCEPTION 'Vault backup evidence requires incident operator attestation'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      SELECT mode INTO STRICT runtime_mode
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime'
      FOR SHARE;

      SELECT mode, activation_evidence_id, activation_evidence_digest,
             activated_by, exact_revision
      INTO STRICT effect_mode, stored_evidence_id, stored_evidence_digest,
                  stored_evidence_operator, stored_exact_revision
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF runtime_mode <> 'partition_fenced_v1' OR
         effect_mode <> 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Backup retirement evidence requires the active exact pair'
          USING ERRCODE = 'check_violation';
      END IF;

      IF stored_evidence_id IS NULL OR stored_evidence_digest IS NULL OR
         pg_catalog.octet_length(stored_evidence_digest) <> 32 OR
         stored_evidence_operator IS NULL OR stored_exact_revision IS NULL OR
         NEW.evidence_id IS DISTINCT FROM stored_evidence_id OR
         NEW.evidence_digest IS DISTINCT FROM stored_evidence_digest OR
         NEW.evidence_operator IS DISTINCT FROM stored_evidence_operator OR
         NEW.exact_revision IS DISTINCT FROM stored_exact_revision THEN
        RAISE EXCEPTION 'Backup retirement evidence does not match protocol authority'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT public.durable_payload_catalog_ready() OR
         NOT public.privacy_protocol_catalog_ready() THEN
        RAISE EXCEPTION 'Backup retirement evidence catalog authority is not ready'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT evidence_id, evidence_digest, evidence_operator, exact_revision,
             source_digest, proved_at
      INTO STRICT proof_evidence_id, proof_evidence_digest,
                  proof_evidence_operator, proof_exact_revision,
                  proof_source_digest, proof_proved_at
      FROM public.key_retirement_zero_proofs
      WHERE key_kind = NEW.key_kind
        AND old_tag = NEW.old_tag
        AND proof_id = NEW.zero_proof_id
      FOR SHARE;

      IF proof_evidence_id IS DISTINCT FROM stored_evidence_id OR
         proof_evidence_digest IS DISTINCT FROM stored_evidence_digest OR
         proof_evidence_operator IS DISTINCT FROM stored_evidence_operator OR
         proof_exact_revision IS DISTINCT FROM stored_exact_revision OR
         pg_catalog.octet_length(proof_source_digest) <> 32 THEN
        RAISE EXCEPTION 'Backup retirement evidence is not bound to its zero proof authority'
          USING ERRCODE = 'check_violation';
      END IF;

      database_now := timezone('UTC', clock_timestamp());

      IF NEW.backup_oldest_recoverable_at <= proof_proved_at OR
         NEW.wal_oldest_recoverable_at <= proof_proved_at OR
         NEW.pitr_oldest_recoverable_at <= proof_proved_at OR
         NEW.restore_drill_recovered_through_at <= proof_proved_at OR
         NEW.backup_catalog_captured_at <= proof_proved_at OR
         NEW.wal_catalog_captured_at <= proof_proved_at OR
         NEW.pitr_catalog_captured_at <= proof_proved_at OR
         NEW.restore_drill_completed_at <= proof_proved_at OR
         NEW.backup_catalog_captured_at > database_now OR
         NEW.wal_catalog_captured_at > database_now OR
         NEW.pitr_catalog_captured_at > database_now OR
         NEW.restore_drill_completed_at > database_now OR
         NEW.backup_oldest_recoverable_at > NEW.backup_catalog_captured_at OR
         NEW.wal_oldest_recoverable_at > NEW.wal_catalog_captured_at OR
         NEW.pitr_oldest_recoverable_at > NEW.pitr_catalog_captured_at OR
         NEW.restore_drill_recovered_through_at > NEW.restore_drill_completed_at OR
         NEW.oldest_recoverable_at IS DISTINCT FROM LEAST(
           NEW.backup_oldest_recoverable_at,
           NEW.wal_oldest_recoverable_at,
           NEW.pitr_oldest_recoverable_at
         ) OR
         NEW.oldest_recoverable_at <= proof_proved_at OR
         NEW.evidence_expires_at <= database_now THEN
        RAISE EXCEPTION 'Backup retirement evidence timing is not strictly post-proof and current'
          USING ERRCODE = 'check_violation';
      END IF;

      NEW.attested_at := database_now;
      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Backup retirement evidence zero proof or protocol authority is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS guard_vault_backup_retirement_evidence_trigger ON public.vault_backup_retirement_evidence"
    )

    execute("""
    CREATE TRIGGER guard_vault_backup_retirement_evidence_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.vault_backup_retirement_evidence
      FOR EACH ROW EXECUTE FUNCTION public.guard_vault_backup_retirement_evidence()
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_vault_backup_retirement_evidence_truncate_trigger ON public.vault_backup_retirement_evidence"
    )

    execute("""
    CREATE TRIGGER reject_vault_backup_retirement_evidence_truncate_trigger
      BEFORE TRUNCATE ON public.vault_backup_retirement_evidence
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.guard_retired_durable_payload_key()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      runtime_mode text;
      effect_mode text;
      stored_evidence_id text;
      stored_evidence_digest bytea;
      stored_evidence_operator text;
      stored_exact_revision text;
      proof_source_digest bytea;
      proof_evidence_id text;
      proof_evidence_digest bytea;
      proof_evidence_operator text;
      proof_exact_revision text;
      proof_proved_at timestamp(6) without time zone;
      backup_oldest_recoverable_at timestamp(6) without time zone;
      backup_expires_at timestamp(6) without time zone;
      live_count bigint;
      current_source_digest bytea;
      observed_fence_generation bigint;
      observed_fences jsonb;
      finalized_generation bigint;
    BEGIN
      IF (session_user IS DISTINCT FROM 'maraithon_incident_operator' AND
          current_setting('role', true) IS DISTINCT FROM 'maraithon_incident_operator') OR
         current_setting('maraithon.key_retirement_authorization', true)
           IS DISTINCT FROM 'RETIRE_KEY_AUTHORIZATION_V1' THEN
        RAISE EXCEPTION 'Key retirement authorization requires incident authority'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Retired durable payload keys are append-only'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF TG_WHEN = 'AFTER' THEN
        PERFORM set_config('maraithon.key_fence_kind', NEW.key_kind, true);
        PERFORM set_config('maraithon.key_fence_tag', NEW.old_tag, true);
        PERFORM set_config(
          'maraithon.key_fence_proof_id', NEW.zero_proof_id::text, true
        );
        PERFORM set_config(
          'maraithon.key_retirement_finalization',
          'FINAL_REMOVAL_AUTHORIZATION_V1',
          true
        );

        UPDATE public.durable_payload_key_fence_state
        SET generation = generation + 1,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE singleton IS TRUE
          AND fences #>> ARRAY[NEW.key_kind, NEW.old_tag] = NEW.zero_proof_id::text
        RETURNING generation INTO finalized_generation;

        IF finalized_generation IS NULL THEN
          RAISE EXCEPTION 'Final key-removal authorization lost its durable write fence'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END IF;

      SELECT mode INTO STRICT runtime_mode
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime'
      FOR SHARE;

      SELECT mode, activation_evidence_id, activation_evidence_digest,
             activated_by, exact_revision
      INTO STRICT effect_mode, stored_evidence_id, stored_evidence_digest,
                  stored_evidence_operator, stored_exact_revision
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF runtime_mode <> 'partition_fenced_v1' OR
         effect_mode <> 'generation_fenced_v1' OR
         stored_evidence_id IS NULL OR stored_evidence_digest IS NULL OR
         stored_evidence_operator IS NULL OR stored_exact_revision IS NULL THEN
        RAISE EXCEPTION 'Key retirement authorization requires the active exact pair'
          USING ERRCODE = 'check_violation';
      END IF;

      IF public.durable_payload_catalog_ready() IS NOT TRUE OR
         public.privacy_protocol_catalog_ready() IS NOT TRUE THEN
        RAISE EXCEPTION 'Key retirement authorization catalog authority is not ready'
          USING ERRCODE = 'check_violation';
      END IF;

      live_count := public.durable_payload_old_key_live_count(NEW.key_kind, NEW.old_tag);

      IF live_count IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'Key retirement authorization rejected because live old-key rows remain'
          USING ERRCODE = 'check_violation';
      END IF;

      current_source_digest := public.durable_payload_old_key_source_digest(
        NEW.key_kind, NEW.old_tag
      );

      SELECT generation, fences
      INTO STRICT observed_fence_generation, observed_fences
      FROM public.durable_payload_key_fence_state
      WHERE singleton IS TRUE
      FOR UPDATE;

      IF observed_fences #>> ARRAY[NEW.key_kind, NEW.old_tag]
           IS DISTINCT FROM NEW.zero_proof_id::text THEN
        RAISE EXCEPTION 'Key retirement zero proof is not the durable write fence'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT proof.source_digest, proof.evidence_id, proof.evidence_digest,
             proof.evidence_operator, proof.exact_revision, proof.proved_at,
             backup.oldest_recoverable_at, backup.evidence_expires_at
      INTO STRICT proof_source_digest, proof_evidence_id, proof_evidence_digest,
                  proof_evidence_operator, proof_exact_revision, proof_proved_at,
                  backup_oldest_recoverable_at, backup_expires_at
      FROM public.key_retirement_zero_proofs AS proof
      JOIN public.vault_backup_retirement_evidence AS backup
        ON backup.key_kind = proof.key_kind
       AND backup.old_tag = proof.old_tag
       AND backup.zero_proof_id = proof.proof_id
      WHERE proof.key_kind = NEW.key_kind
        AND proof.old_tag = NEW.old_tag
        AND proof.proof_id = NEW.zero_proof_id
        AND backup.evidence_id = NEW.backup_evidence_id
        AND proof.evidence_id = stored_evidence_id
        AND proof.evidence_digest = stored_evidence_digest
        AND proof.evidence_operator = stored_evidence_operator
        AND proof.exact_revision = stored_exact_revision
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
      FOR SHARE OF proof;

      IF proof_source_digest IS DISTINCT FROM current_source_digest OR
         pg_catalog.octet_length(current_source_digest) <> 32 OR
         backup_oldest_recoverable_at <= proof_proved_at OR
         backup_expires_at <= timezone('UTC', clock_timestamp()) THEN
        RAISE EXCEPTION 'Key retirement proof or backup evidence is stale'
          USING ERRCODE = 'check_violation';
      END IF;

      NEW.source_digest := proof_source_digest;
      NEW.fence_generation := observed_fence_generation;
      NEW.evidence_id := proof_evidence_id;
      NEW.evidence_digest := proof_evidence_digest;
      NEW.evidence_operator := proof_evidence_operator;
      NEW.exact_revision := proof_exact_revision;
      NEW.authorized_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Key retirement proof or backup evidence is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS guard_retired_durable_payload_key_trigger " <>
        "ON public.retired_durable_payload_keys"
    )

    execute("""
    CREATE TRIGGER guard_retired_durable_payload_key_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.retired_durable_payload_keys
      FOR EACH ROW EXECUTE FUNCTION public.guard_retired_durable_payload_key()
    """)

    execute("""
    ALTER TABLE public.retired_durable_payload_keys
      ENABLE ALWAYS TRIGGER guard_retired_durable_payload_key_trigger
    """)

    execute(
      "DROP TRIGGER IF EXISTS finalize_retired_durable_payload_key_fence_trigger " <>
        "ON public.retired_durable_payload_keys"
    )

    execute("""
    CREATE TRIGGER finalize_retired_durable_payload_key_fence_trigger
      AFTER INSERT ON public.retired_durable_payload_keys
      FOR EACH ROW EXECUTE FUNCTION public.guard_retired_durable_payload_key()
    """)

    execute("""
    ALTER TABLE public.retired_durable_payload_keys
      ENABLE ALWAYS TRIGGER finalize_retired_durable_payload_key_fence_trigger
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_retired_durable_payload_keys_truncate_trigger " <>
        "ON public.retired_durable_payload_keys"
    )

    execute("""
    CREATE TRIGGER reject_retired_durable_payload_keys_truncate_trigger
      BEFORE TRUNCATE ON public.retired_durable_payload_keys
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.guard_vault_reencryption_failure_write()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_incident_operator' OR
         current_setting('maraithon.vault_reencryption', true)
           IS DISTINCT FROM 'VAULT_REENCRYPT_V1' THEN
        RAISE EXCEPTION 'Only the incident operator may record Vault rotation failures'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      NEW.failed_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS guard_vault_reencryption_failure_write_trigger ON public.vault_reencryption_failures"
    )

    execute("""
    CREATE TRIGGER guard_vault_reencryption_failure_write_trigger
      BEFORE INSERT OR UPDATE ON public.vault_reencryption_failures
      FOR EACH ROW EXECUTE FUNCTION public.guard_vault_reencryption_failure_write()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.snapshot_writer_authority_valid(
      requested_agent_id uuid,
      requested_owner_token uuid
    )
    RETURNS boolean
    LANGUAGE plpgsql
    VOLATILE
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      runtime_mode text;
      runtime_activation_epoch uuid;
      effect_mode text;
      observed_user_id text;
      observed_activation_epoch uuid;
      observed_partition_id smallint;
      observed_partition_epoch bigint;
      observed_node_id uuid;
    BEGIN
      SELECT mode, activation_epoch
      INTO STRICT runtime_mode, runtime_activation_epoch
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime'
      FOR SHARE;

      SELECT mode INTO STRICT effect_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF runtime_mode <> 'partition_fenced_v1' OR
         effect_mode <> 'generation_fenced_v1' OR
         requested_agent_id IS NULL OR requested_owner_token IS NULL THEN
        RETURN false;
      END IF;

      SELECT agent.user_id, lease.coordination_activation_epoch,
             lease.coordination_partition_id, lease.coordination_partition_epoch,
             lease.coordination_node_incarnation_id
      INTO STRICT observed_user_id, observed_activation_epoch,
                  observed_partition_id, observed_partition_epoch, observed_node_id
      FROM public.agents AS agent
      JOIN public.agent_runtime_leases AS lease ON lease.agent_id = agent.id
      WHERE agent.id = requested_agent_id
        AND lease.owner_token = requested_owner_token;

      IF observed_user_id IS NULL OR
         observed_activation_epoch IS DISTINCT FROM runtime_activation_epoch OR
         observed_partition_id IS NULL OR observed_partition_epoch IS NULL OR
         observed_node_id IS NULL THEN
        RETURN false;
      END IF;

      PERFORM 1
      FROM public.runtime_node_incarnations AS node
      WHERE node.id = observed_node_id
        AND node.activation_epoch = observed_activation_epoch
        AND node.state = 'ready'
        AND node.ready_at IS NOT NULL
        AND node.lease_expires_at > timezone('UTC', clock_timestamp())
      FOR SHARE;
      IF NOT FOUND THEN RETURN false; END IF;

      PERFORM 1
      FROM public.runtime_partitions AS partition
      WHERE partition.partition_id = observed_partition_id
        AND partition.partition_id =
              public.runtime_partition_for('user:' || observed_user_id)
        AND partition.activation_epoch = observed_activation_epoch
        AND partition.ownership_epoch = observed_partition_epoch
        AND partition.owner_node_incarnation_id = observed_node_id
        AND partition.state = 'ready'
        AND partition.ready_at IS NOT NULL
        AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
      FOR SHARE;
      IF NOT FOUND THEN RETURN false; END IF;

      PERFORM 1
      FROM public.users AS app_user
      WHERE app_user.id = observed_user_id
        AND app_user.privacy_erasure_requested_at IS NULL
      FOR SHARE;
      IF NOT FOUND THEN RETURN false; END IF;

      PERFORM 1
      FROM public.agents AS agent
      WHERE agent.id = requested_agent_id
        AND agent.user_id = observed_user_id
        AND agent.status IN ('running', 'degraded')
        AND agent.install_status = 'enabled'
      FOR SHARE;
      IF NOT FOUND THEN RETURN false; END IF;

      PERFORM 1
      FROM public.agent_isolation_bindings AS binding
      WHERE binding.agent_id = requested_agent_id
        AND binding.user_id = observed_user_id
        AND binding.status = 'active'
      FOR SHARE;
      IF NOT FOUND THEN RETURN false; END IF;

      IF EXISTS (
        SELECT 1 FROM public.agent_restart_guards
        WHERE agent_id = requested_agent_id
      ) THEN
        PERFORM 1
        FROM public.agent_restart_guards AS guard
        WHERE guard.agent_id = requested_agent_id
          AND guard.tripped IS FALSE
          AND guard.needs_recovery IS FALSE
          AND (guard.blocked_until IS NULL OR
               guard.blocked_until <= timezone('UTC', clock_timestamp()))
        FOR SHARE;
        IF NOT FOUND THEN RETURN false; END IF;
      END IF;

      PERFORM 1
      FROM public.agent_runtime_leases AS lease
      WHERE lease.agent_id = requested_agent_id
        AND lease.owner_token = requested_owner_token
        AND lease.coordination_activation_epoch = observed_activation_epoch
        AND lease.coordination_partition_id = observed_partition_id
        AND lease.coordination_partition_epoch = observed_partition_epoch
        AND lease.coordination_node_incarnation_id = observed_node_id
        AND lease.ready_at IS NOT NULL
        AND lease.draining_at IS NULL
        AND lease.lease_until > timezone('UTC', clock_timestamp())
      FOR SHARE;
      IF NOT FOUND THEN RETURN false; END IF;

      IF EXISTS (
        SELECT 1 FROM public.agent_lifecycle_operations
        WHERE agent_id = requested_agent_id
      ) OR EXISTS (
        SELECT 1 FROM public.agent_termination_incidents
        WHERE agent_id = requested_agent_id AND status IN ('requested', 'proven')
      ) THEN
        RETURN false;
      END IF;

      RETURN true;
    EXCEPTION WHEN no_data_found OR invalid_text_representation THEN
      RETURN false;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_snapshot_payload_protocol()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      protocol_mode text;
      newer_count integer;
      lifecycle_delete_authorized boolean := false;
      identity_unchanged boolean;
      writer_owner_token uuid;
      operator_update_authorized boolean := false;
    BEGIN
      SELECT mode INTO STRICT protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF protocol_mode NOT IN ('legacy', 'generation_fenced_v1') THEN
        RAISE EXCEPTION 'Effect execution protocol mode is invalid'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'DELETE' THEN
        IF protocol_mode = 'legacy' AND
           current_user IN ('maraithon_runtime', 'maraithon_migrator') AND
           current_setting('maraithon.snapshot_quarantine_delete', true)
             IS NOT DISTINCT FROM 'QUARANTINE_INVALID_SNAPSHOT_V1' AND
           EXISTS (
             SELECT 1
             FROM public.snapshot_quarantines AS quarantine
             WHERE quarantine.snapshot_id = OLD.id
               AND quarantine.agent_id = OLD.agent_id
               AND quarantine.sequence_num = OLD.sequence_num
               AND quarantine.status = 'quarantined'
               AND quarantine.quarantined_at IS NOT NULL
           ) THEN
          RETURN OLD;
        END IF;

        IF current_user NOT IN ('maraithon_runtime', 'maraithon_migrator') OR
           current_setting('maraithon.snapshot_history_prune', true)
             IS DISTINCT FROM 'PRUNE_BEYOND_RECOVERY_WINDOW_V1' OR
           (protocol_mode = 'generation_fenced_v1' AND
            current_user IS DISTINCT FROM 'maraithon_runtime') THEN
          IF current_user = 'maraithon_runtime' AND
             (protocol_mode = 'legacy' OR
              current_setting('maraithon.effect_writer_protocol', true)
                IS NOT DISTINCT FROM 'generation_fenced_v1') THEN
            SELECT EXISTS (
              SELECT 1
              FROM public.agent_lifecycle_operations AS operation
              WHERE operation.agent_id = OLD.agent_id
                AND operation.kind = 'delete'
                AND operation.state = 'draining'
                AND operation.operation_token::text =
                    current_setting('maraithon.lifecycle_operation_token', true)
                AND operation.payload #>> '{mutation,action}' = 'delete'
                AND operation.payload ->> 'operation_token' =
                    operation.operation_token::text
            ) INTO lifecycle_delete_authorized;
          END IF;

          IF NOT lifecycle_delete_authorized THEN
            RAISE EXCEPTION 'Snapshot deletion requires bounded prune or lifecycle authority'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN OLD;
        END IF;

        IF protocol_mode = 'generation_fenced_v1' THEN
          BEGIN
            writer_owner_token := NULLIF(
              current_setting('maraithon.agent_lease_owner_token', true), ''
            )::uuid;
          EXCEPTION WHEN invalid_text_representation THEN
            writer_owner_token := NULL;
          END;

          IF current_setting('maraithon.effect_writer_protocol', true)
               IS DISTINCT FROM 'generation_fenced_v1' OR
             public.snapshot_writer_authority_valid(OLD.agent_id, writer_owner_token)
               IS NOT TRUE THEN
            RAISE EXCEPTION 'Exact Snapshot pruning requires generation-fenced lease authority'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        SELECT count(*)::integer INTO newer_count
        FROM (
          SELECT newer.id
          FROM public.snapshots AS newer
          WHERE newer.agent_id = OLD.agent_id
            AND (newer.sequence_num, newer.id) > (OLD.sequence_num, OLD.id)
          ORDER BY newer.sequence_num DESC, newer.id DESC
          LIMIT 10
        ) AS retained;

        IF newer_count < 10 THEN
          RAISE EXCEPTION 'Snapshot pruning must preserve the newest ten recovery boundaries'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN OLD;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        identity_unchanged :=
          NEW.id IS NOT DISTINCT FROM OLD.id AND
          NEW.agent_id IS NOT DISTINCT FROM OLD.agent_id AND
          NEW.sequence_num IS NOT DISTINCT FROM OLD.sequence_num AND
          NEW.state_name IS NOT DISTINCT FROM OLD.state_name AND
          NEW.schema_version IS NOT DISTINCT FROM OLD.schema_version AND
          NEW.inserted_at IS NOT DISTINCT FROM OLD.inserted_at;

        IF NOT identity_unchanged OR
           NEW.payload_purged_at IS DISTINCT FROM OLD.payload_purged_at THEN
          RAISE EXCEPTION 'Snapshot identity and purge authority are immutable'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      IF protocol_mode = 'legacy' THEN
        IF TG_OP = 'INSERT' AND current_user = 'maraithon_runtime' THEN
          RETURN NEW;
        END IF;

        IF TG_OP = 'UPDATE' AND
           current_user = 'maraithon_migrator' AND
           current_setting('maraithon.snapshot_format_migration', true)
             IS NOT DISTINCT FROM 'MIGRATE_LEGACY_SNAPSHOT_V1' AND
           (to_jsonb(NEW) - ARRAY['state_data', 'budget']::text[])
             IS NOT DISTINCT FROM
             (to_jsonb(OLD) - ARRAY['state_data', 'budget']::text[]) AND
           (NEW.state_data IS DISTINCT FROM OLD.state_data OR
            NEW.budget IS DISTINCT FROM OLD.budget) AND
           (NEW.state_data ->> 'format' = 'maraithon.agent_snapshot' AND
            NEW.state_data -> 'format_version' = '1'::jsonb AND
            NEW.budget ->> 'format' = 'maraithon.agent_snapshot' AND
            NEW.budget -> 'format_version' = '1'::jsonb) IS TRUE THEN
          RETURN NEW;
        END IF;

        IF TG_OP = 'UPDATE' AND
           current_user = 'maraithon_activation_operator' THEN
          IF public.durable_payload_operator_row_mutation_authorized(
                TG_RELID::regclass, TG_OP, pg_catalog.to_jsonb(OLD), pg_catalog.to_jsonb(NEW)
              ) IS TRUE THEN
            RETURN NEW;
          END IF;
        END IF;

        RAISE EXCEPTION 'Legacy Snapshot mutation requires runtime insert, format migration, or contraction authority'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF current_user = 'maraithon_runtime' THEN
        BEGIN
          writer_owner_token := NULLIF(
            current_setting('maraithon.agent_lease_owner_token', true), ''
          )::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
          writer_owner_token := NULL;
        END;
      END IF;

      IF current_user NOT IN ('maraithon_runtime', 'maraithon_incident_operator',
                              'maraithon_activation_operator') THEN
        RAISE EXCEPTION 'Exact Snapshot mutation requires canonical role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF TG_OP = 'INSERT' THEN
        IF current_user IS DISTINCT FROM 'maraithon_runtime' OR
           current_setting('maraithon.effect_writer_protocol', true)
             IS DISTINCT FROM 'generation_fenced_v1' THEN
          RAISE EXCEPTION 'Exact Snapshot insertion requires generation-fenced runtime authority'
            USING ERRCODE = 'insufficient_privilege';
        END IF;

        IF public.snapshot_writer_authority_valid(NEW.agent_id, writer_owner_token)
             IS NOT TRUE THEN
          RAISE EXCEPTION 'Exact Snapshot insertion requires generation-fenced runtime authority'
            USING ERRCODE = 'insufficient_privilege';
        END IF;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        operator_update_authorized := false;

        IF current_user = 'maraithon_incident_operator' THEN
          operator_update_authorized :=
            public.durable_payload_operator_row_mutation_authorized(
                TG_RELID::regclass, TG_OP, pg_catalog.to_jsonb(OLD), pg_catalog.to_jsonb(NEW)
              ) IS TRUE AND
            (
            (
              current_setting('maraithon.binding_key_rotation', true)
                IS NOT DISTINCT FROM 'BINDING_KEY_ROTATION_V1' AND
              current_setting('maraithon.vault_reencryption', true)
                IS DISTINCT FROM 'VAULT_REENCRYPT_V1' AND
              (to_jsonb(NEW) - ARRAY[
                'payload_binding_version', 'payload_binding_key_tag',
                'payload_binding_mac'
              ]::text[]) IS NOT DISTINCT FROM
              (to_jsonb(OLD) - ARRAY[
                'payload_binding_version', 'payload_binding_key_tag',
                'payload_binding_mac'
              ]::text[]) AND
              (
                NEW.payload_binding_version IS DISTINCT FROM OLD.payload_binding_version OR
                NEW.payload_binding_key_tag IS DISTINCT FROM OLD.payload_binding_key_tag OR
                NEW.payload_binding_mac IS DISTINCT FROM OLD.payload_binding_mac
              )
            ) OR
            (
              current_setting('maraithon.vault_reencryption', true)
                IS NOT DISTINCT FROM 'VAULT_REENCRYPT_V1' AND
              current_setting('maraithon.binding_key_rotation', true)
                IS DISTINCT FROM 'BINDING_KEY_ROTATION_V1' AND
              (to_jsonb(NEW) - ARRAY[
                'state_data_ciphertext', 'budget_ciphertext'
              ]::text[]) IS NOT DISTINCT FROM
              (to_jsonb(OLD) - ARRAY[
                'state_data_ciphertext', 'budget_ciphertext'
              ]::text[]) AND
              (NEW.state_data_ciphertext IS NULL) =
                (OLD.state_data_ciphertext IS NULL) AND
              (NEW.budget_ciphertext IS NULL) = (OLD.budget_ciphertext IS NULL) AND
              (
                NEW.state_data_ciphertext IS DISTINCT FROM OLD.state_data_ciphertext OR
                NEW.budget_ciphertext IS DISTINCT FROM OLD.budget_ciphertext
              )
            )
          );
        END IF;

        IF operator_update_authorized IS NOT TRUE THEN
          RAISE EXCEPTION 'Exact Snapshot update requires narrow operator authority'
            USING ERRCODE = 'insufficient_privilege';
        END IF;
      END IF;

      IF NEW.payload_purged_at IS NULL THEN
        IF NEW.payload_encryption_version IS DISTINCT FROM 1 OR
           NEW.state_data_ciphertext IS NULL OR NEW.budget_ciphertext IS NULL OR
           NEW.state_data IS DISTINCT FROM '{}'::jsonb OR
           NEW.budget IS DISTINCT FROM '{}'::jsonb OR
           NEW.payload_binding_version IS DISTINCT FROM 1 OR
           NEW.payload_binding_key_tag IS NULL OR
           octet_length(NEW.payload_binding_mac) IS DISTINCT FROM 32 THEN
          RAISE EXCEPTION 'Exact Snapshot payload must be encrypted and bound'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSE
        IF NEW.state_data_ciphertext IS NOT NULL OR NEW.budget_ciphertext IS NOT NULL OR
           NEW.state_data IS DISTINCT FROM '{}'::jsonb OR
           NEW.budget IS DISTINCT FROM '{}'::jsonb OR
           NEW.payload_binding_version IS NOT NULL OR
           NEW.payload_binding_key_tag IS NOT NULL OR
           NEW.payload_binding_mac IS NOT NULL THEN
          RAISE EXCEPTION 'Purged Snapshot must remain content-free'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_snapshot_payload_protocol_trigger ON public.snapshots"
    )

    execute("""
    CREATE TRIGGER enforce_snapshot_payload_protocol_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.snapshots
      FOR EACH ROW EXECUTE FUNCTION public.enforce_snapshot_payload_protocol()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.guard_durable_payload_verification_failure_write()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_payload_verifier' OR
         current_setting('maraithon.durable_payload_verifier', true)
           IS DISTINCT FROM 'VAULT_AUTHENTICATED_V1' THEN
        RAISE EXCEPTION 'Only the Vault verification operator may record verification failures'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      NEW.failed_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS guard_durable_payload_verification_failure_write_trigger ON public.durable_payload_verification_failures"
    )

    execute("""
    CREATE TRIGGER guard_durable_payload_verification_failure_write_trigger
      BEFORE INSERT OR UPDATE ON public.durable_payload_verification_failures
      FOR EACH ROW EXECUTE FUNCTION public.guard_durable_payload_verification_failure_write()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.guard_durable_payload_verification_write()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Durable payload proofs are immutable; delete and reverify'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF current_user IS DISTINCT FROM 'maraithon_payload_verifier' OR
         current_setting('maraithon.durable_payload_verifier', true)
           IS DISTINCT FROM 'VAULT_AUTHENTICATED_V1' THEN
        RAISE EXCEPTION 'Only the Vault verification operator may insert durable payload proofs'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      NEW.verified_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS guard_durable_payload_verification_write_trigger ON public.durable_payload_verifications"
    )

    execute("""
    CREATE TRIGGER guard_durable_payload_verification_write_trigger
      BEFORE INSERT OR UPDATE ON public.durable_payload_verifications
      FOR EACH ROW EXECUTE FUNCTION public.guard_durable_payload_verification_write()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.delete_durable_payload_verification(
      source_table text,
      source_identity text
    )
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF public.durable_payload_row_identity(source_table, source_identity)
           IS DISTINCT FROM source_identity THEN
        RAISE EXCEPTION 'Invalid durable payload proof identity'
          USING ERRCODE = 'invalid_parameter_value';
      END IF;

      PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(source_table || ':' || source_identity, 0)
      );

      DELETE FROM public.durable_payload_verifications
      WHERE payload_table = source_table
        AND row_identity = source_identity;

      DELETE FROM public.durable_payload_verification_failures
      WHERE payload_table = source_table
        AND row_identity = source_identity;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.invalidate_durable_payload_verification()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      old_row jsonb;
      new_row jsonb;
      old_identity text;
      new_identity text;
      relevant_change boolean;
    BEGIN
      old_row := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END;
      new_row := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END;

      IF TG_OP IN ('UPDATE', 'DELETE') THEN
        old_identity := public.durable_payload_row_identity(
          TG_TABLE_NAME,
          CASE TG_TABLE_NAME
            WHEN 'events' THEN
              '[' || to_json(old_row ->> 'agent_id')::text || ',' ||
              to_json(old_row ->> 'sequence_num')::text || ']'
            ELSE old_row ->> 'id'
          END
        );
      END IF;

      IF TG_OP IN ('INSERT', 'UPDATE') THEN
        new_identity := public.durable_payload_row_identity(
          TG_TABLE_NAME,
          CASE TG_TABLE_NAME
            WHEN 'events' THEN
              '[' || to_json(new_row ->> 'agent_id')::text || ',' ||
              to_json(new_row ->> 'sequence_num')::text || ']'
            ELSE new_row ->> 'id'
          END
        );
      END IF;

      relevant_change := TG_OP <> 'UPDATE' OR
        old_identity IS DISTINCT FROM new_identity OR
        public.durable_payload_digest_part(TG_TABLE_NAME, old_row, 'ciphertext')
          IS DISTINCT FROM
        public.durable_payload_digest_part(TG_TABLE_NAME, new_row, 'ciphertext') OR
        public.durable_payload_digest_part(TG_TABLE_NAME, old_row, 'projection')
          IS DISTINCT FROM
        public.durable_payload_digest_part(TG_TABLE_NAME, new_row, 'projection') OR
        public.durable_payload_digest_part(TG_TABLE_NAME, old_row, 'version')
          IS DISTINCT FROM
        public.durable_payload_digest_part(TG_TABLE_NAME, new_row, 'version') OR
        public.durable_payload_digest_part(TG_TABLE_NAME, old_row, 'purge')
          IS DISTINCT FROM
        public.durable_payload_digest_part(TG_TABLE_NAME, new_row, 'purge');

      IF relevant_change THEN
        IF old_identity IS NOT NULL THEN
          PERFORM public.delete_durable_payload_verification(TG_TABLE_NAME, old_identity);
        END IF;

        IF new_identity IS NOT NULL AND new_identity IS DISTINCT FROM old_identity THEN
          PERFORM public.delete_durable_payload_verification(TG_TABLE_NAME, new_identity);
        ELSIF TG_OP = 'INSERT' AND new_identity IS NOT NULL THEN
          PERFORM public.delete_durable_payload_verification(TG_TABLE_NAME, new_identity);
        END IF;
      END IF;

      RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END;
    $function$;
    """)

    for table <- ~w(
      effects agent_directives events agent_run_steps
      telegram_conversation_turns telegram_conversations
      telegram_assistant_runs telegram_assistant_steps telegram_prepared_actions
      agent_runs operator_events user_memory_profiles operator_memory_summaries
      background_jobs scheduled_jobs runtime_ingress_receipts agent_work_results snapshots
    ) do
      execute(
        "DROP TRIGGER IF EXISTS invalidate_durable_payload_verification_trigger ON public.#{table}"
      )

      execute("""
      CREATE TRIGGER invalidate_durable_payload_verification_trigger
        AFTER INSERT OR UPDATE OR DELETE ON public.#{table}
        FOR EACH ROW EXECUTE FUNCTION public.invalidate_durable_payload_verification()
      """)
    end

    for table <- ~w(events agent_run_steps) do
      execute(
        "DROP TRIGGER IF EXISTS enforce_durable_history_payload_protocol_trigger ON public.#{table}"
      )

      execute("""
      CREATE TRIGGER enforce_durable_history_payload_protocol_trigger
        BEFORE INSERT OR UPDATE OR DELETE ON public.#{table}
        FOR EACH ROW EXECUTE FUNCTION public.enforce_durable_history_payload_protocol()
      """)
    end

    execute(
      "DROP TRIGGER IF EXISTS reject_durable_payload_verifications_truncate_trigger ON public.durable_payload_verifications"
    )

    execute("""
    CREATE TRIGGER reject_durable_payload_verifications_truncate_trigger
      BEFORE TRUNCATE ON public.durable_payload_verifications
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_durable_payload_verification_failures_truncate_trigger ON public.durable_payload_verification_failures"
    )

    execute("""
    CREATE TRIGGER reject_durable_payload_verification_failures_truncate_trigger
      BEFORE TRUNCATE ON public.durable_payload_verification_failures
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_vault_reencryption_failures_truncate_trigger ON public.vault_reencryption_failures"
    )

    execute("""
    CREATE TRIGGER reject_vault_reencryption_failures_truncate_trigger
      BEFORE TRUNCATE ON public.vault_reencryption_failures
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute("""
    REVOKE ALL ON TABLE public.durable_payload_verifications,
      public.durable_payload_verification_failures,
      public.vault_reencryption_failures,
      public.durable_payload_binding_operations,
      public.key_retirement_zero_proofs,
      public.vault_backup_retirement_evidence,
      public.durable_payload_key_fence_state,
      public.retired_durable_payload_keys
      FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier,
        maraithon_incident_operator, maraithon_activation_operator
    """)

    execute("REVOKE ALL ON public.vault_reencryption_failures FROM PUBLIC")
    execute("REVOKE ALL ON public.durable_payload_verifications FROM PUBLIC")
    execute("REVOKE ALL ON public.durable_payload_verification_failures FROM PUBLIC")

    execute("""
    REVOKE ALL ON FUNCTION
      public.durable_payload_row_identity(text, text),
      public.durable_payload_digest_part(text, jsonb, text),
      public.durable_payload_proof_failures(),
      public.durable_payload_source_acl_ready(),
      public.durable_payload_roles_ready(),
      public.enforce_durable_history_payload_protocol(),
      public.durable_payload_operator_mutation_authorized(),
      public.durable_payload_operator_row_mutation_authorized(regclass,text,jsonb,jsonb),
      public.guard_durable_payload_operator_source_mutation(),
      public.lock_durable_runtime_activation_sources(),
      public.lock_durable_payload_binding_sources(),
      public.lock_durable_payload_contraction_sources(),
      public.lock_durable_payload_contraction_coordination(),
      public.durable_payload_old_key_live_count(text, text),
      public.durable_payload_key_registry_definition(text),
      public.durable_payload_old_key_source_digest(text, text),
      public.durable_payload_ciphertext_key_tag(bytea),
      public.advance_durable_payload_key_fence_epoch(text, text, uuid),
      public.guard_durable_payload_key_fence_state(),
      public.durable_payload_key_write_fenced(text, text),
      public.guard_durable_payload_retired_key_write(),
      public.sync_durable_payload_key_fence_from_zero_proof(),
      public.guard_durable_payload_binding_operation(),
      public.guard_key_retirement_zero_proof(),
      public.guard_vault_backup_retirement_evidence(),
      public.guard_retired_durable_payload_key(),
      public.guard_vault_reencryption_failure_write(),
      public.snapshot_writer_authority_valid(uuid, uuid),
      public.enforce_snapshot_payload_protocol(),
      public.guard_durable_payload_verification_failure_write(),
      public.guard_durable_payload_verification_write(),
      public.delete_durable_payload_verification(text, text),
      public.invalidate_durable_payload_verification()
      FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier,
        maraithon_incident_operator, maraithon_activation_operator
    """)

    execute("""
    DO $grants$
    DECLARE
      acl_role text;
      source_relation text;
      source_columns text;
    BEGIN
      -- Snapshot format migration and quarantine are offline migrator
      -- capabilities. The runtime may inspect sanitized reports but cannot
      -- forge, rewrite, or erase the authority used by quarantine deletion.
      ALTER TABLE public.snapshot_quarantines OWNER TO maraithon_object_owner;
      ALTER SEQUENCE public.snapshot_quarantines_id_seq OWNER TO maraithon_object_owner;

      REVOKE ALL ON TABLE public.snapshot_quarantines FROM
        PUBLIC, maraithon_runtime, maraithon_payload_verifier,
        maraithon_incident_operator, maraithon_activation_operator;
      REVOKE ALL ON SEQUENCE public.snapshot_quarantines_id_seq FROM
        PUBLIC, maraithon_runtime, maraithon_payload_verifier,
        maraithon_incident_operator, maraithon_activation_operator;

      GRANT ALL ON TABLE public.snapshot_quarantines TO maraithon_migrator;
      GRANT ALL ON SEQUENCE public.snapshot_quarantines_id_seq TO maraithon_migrator;
      GRANT SELECT ON TABLE public.snapshot_quarantines TO maraithon_runtime;

      -- SELECT ... FOR SHARE requires UPDATE authority. Limit it to the
      -- immutable primary key and only the Agent columns migration inspects.
      GRANT SELECT (id, status, install_status), UPDATE (id)
        ON TABLE public.agents TO maraithon_migrator;

      -- Converge from any historical broad or column-level grant before
      -- restoring the closed operator capability sets below. Table REVOKE
      -- alone does not remove PostgreSQL column ACLs.
      FOREACH source_relation IN ARRAY ARRAY[
        'connected_accounts', 'oauth_tokens', 'local_browser_visits',
        'local_calendar_events', 'local_files', 'memory_items',
        'effects', 'agent_directives', 'events', 'agent_run_steps',
        'telegram_conversation_turns', 'telegram_conversations',
        'telegram_assistant_runs', 'telegram_assistant_steps',
        'telegram_prepared_actions', 'agent_runs', 'operator_events',
        'user_memory_profiles', 'operator_memory_summaries',
        'background_jobs', 'scheduled_jobs', 'runtime_ingress_receipts',
        'agent_work_results', 'snapshots'
      ] LOOP
        SELECT pg_catalog.string_agg(pg_catalog.quote_ident(attribute.attname), ', ')
        INTO STRICT source_columns
        FROM pg_catalog.pg_attribute AS attribute
        WHERE attribute.attrelid = pg_catalog.to_regclass('public.' || source_relation)
          AND attribute.attnum > 0
          AND NOT attribute.attisdropped;

        EXECUTE pg_catalog.format(
          'REVOKE ALL PRIVILEGES ON TABLE public.%I FROM PUBLIC', source_relation
        );
        EXECUTE pg_catalog.format(
          'REVOKE ALL PRIVILEGES (%s) ON TABLE public.%I FROM PUBLIC',
          source_columns, source_relation
        );

        FOREACH acl_role IN ARRAY ARRAY[
          'maraithon_payload_verifier',
          'maraithon_incident_operator',
          'maraithon_activation_operator'
        ] LOOP
          IF EXISTS (
            SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = acl_role
          ) THEN
            EXECUTE pg_catalog.format(
              'REVOKE ALL PRIVILEGES ON TABLE public.%I FROM %I',
              source_relation, acl_role
            );
            EXECUTE pg_catalog.format(
              'REVOKE ALL PRIVILEGES (%s) ON TABLE public.%I FROM %I',
              source_columns, source_relation, acl_role
            );
          END IF;
        END LOOP;
      END LOOP;

      IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'maraithon_payload_verifier'
      ) THEN
        GRANT SELECT, INSERT, DELETE
          ON public.durable_payload_verifications
          TO maraithon_payload_verifier;
        GRANT SELECT, INSERT, UPDATE, DELETE
          ON public.durable_payload_verification_failures
          TO maraithon_payload_verifier;
        GRANT SELECT
          ON public.effect_execution_protocols,
             public.effects, public.agent_directives, public.events, public.agent_run_steps,
             public.telegram_conversation_turns, public.telegram_conversations,
             public.telegram_assistant_runs, public.telegram_assistant_steps,
             public.telegram_prepared_actions, public.agent_runs, public.operator_events,
             public.user_memory_profiles, public.operator_memory_summaries,
             public.background_jobs, public.scheduled_jobs,
             public.runtime_ingress_receipts, public.agent_work_results, public.snapshots
          TO maraithon_payload_verifier;
        GRANT EXECUTE ON FUNCTION
          public.durable_payload_row_identity(text, text),
          public.durable_payload_digest_part(text, jsonb, text),
          public.delete_durable_payload_verification(text, text)
          TO maraithon_payload_verifier;
      END IF;

      IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'maraithon_runtime'
      ) THEN
        GRANT EXECUTE ON FUNCTION
          public.durable_payload_row_identity(text, text),
          public.durable_payload_digest_part(text, jsonb, text),
          public.durable_payload_source_acl_ready(),
          public.durable_payload_roles_ready(),
          public.durable_payload_key_write_fenced(text, text),
          public.snapshot_writer_authority_valid(uuid, uuid),
          public.delete_durable_payload_verification(text, text)
          TO maraithon_runtime;
      END IF;


      IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'maraithon_incident_operator'
      ) THEN
        GRANT SELECT, UPDATE ON public.effect_execution_protocols
          TO maraithon_incident_operator;
        GRANT SELECT
          ON public.connected_accounts, public.oauth_tokens,
             public.local_browser_visits, public.local_calendar_events,
             public.local_files, public.memory_items,
             public.effects, public.agent_directives, public.events, public.agent_run_steps,
             public.telegram_conversation_turns, public.telegram_conversations,
             public.telegram_assistant_runs, public.telegram_assistant_steps,
             public.telegram_prepared_actions, public.agent_runs, public.operator_events,
             public.user_memory_profiles, public.operator_memory_summaries,
             public.background_jobs, public.scheduled_jobs,
             public.runtime_ingress_receipts, public.agent_work_results, public.snapshots,
             public.vault_reencryption_failures,
             public.vault_backup_retirement_evidence,
             public.durable_payload_binding_operations,
             public.key_retirement_zero_proofs,
             public.retired_durable_payload_keys
          TO maraithon_incident_operator;
        GRANT INSERT ON public.vault_backup_retirement_evidence
          TO maraithon_incident_operator;
        GRANT INSERT ON public.key_retirement_zero_proofs,
          public.retired_durable_payload_keys
          TO maraithon_incident_operator;
        GRANT INSERT, UPDATE ON public.durable_payload_binding_operations
          TO maraithon_incident_operator;
        GRANT EXECUTE ON FUNCTION
          public.durable_payload_row_identity(text, text),
          public.durable_payload_digest_part(text, jsonb, text),
          public.durable_payload_source_acl_ready(),
          public.durable_payload_roles_ready(),
          public.durable_payload_operator_row_mutation_authorized(regclass,text,jsonb,jsonb),
          public.lock_durable_payload_binding_sources(),
          public.durable_payload_old_key_live_count(text, text),
          public.durable_payload_key_registry_definition(text),
          public.durable_payload_old_key_source_digest(text, text),
          public.delete_durable_payload_verification(text, text)
          TO maraithon_incident_operator;
        GRANT INSERT, UPDATE, DELETE ON public.vault_reencryption_failures
          TO maraithon_incident_operator;
        GRANT UPDATE (access_token, refresh_token) ON public.connected_accounts TO maraithon_incident_operator;
        GRANT UPDATE (access_token, refresh_token) ON public.oauth_tokens TO maraithon_incident_operator;
        GRANT UPDATE (title) ON public.local_browser_visits TO maraithon_incident_operator;
        GRANT UPDATE (title, notes) ON public.local_calendar_events TO maraithon_incident_operator;
        GRANT UPDATE (filename, text_content) ON public.local_files TO maraithon_incident_operator;
        GRANT UPDATE (content, summary, metadata) ON public.memory_items TO maraithon_incident_operator;
        GRANT UPDATE (params_ciphertext, result_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.effects TO maraithon_incident_operator;
        GRANT UPDATE (payload_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.agent_directives TO maraithon_incident_operator;
        GRANT UPDATE (payload_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.events TO maraithon_incident_operator;
        GRANT UPDATE (request_payload_ciphertext, response_payload_ciphertext,
                      payload_encryption_version, payload_binding_version,
                      payload_binding_key_tag, payload_binding_mac)
          ON public.agent_run_steps TO maraithon_incident_operator;
        GRANT UPDATE (text_ciphertext, structured_data_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.telegram_conversation_turns TO maraithon_incident_operator;
        GRANT UPDATE (summary_ciphertext, historical_summary_ciphertext,
                      payload_encryption_version, payload_binding_version,
                      payload_binding_key_tag, payload_binding_mac)
          ON public.telegram_conversations TO maraithon_incident_operator;
        GRANT UPDATE (prompt_snapshot_ciphertext, result_summary_ciphertext,
                      payload_encryption_version, payload_binding_version,
                      payload_binding_key_tag, payload_binding_mac)
          ON public.telegram_assistant_runs TO maraithon_incident_operator;
        GRANT UPDATE (request_payload_ciphertext, response_payload_ciphertext,
                      payload_encryption_version, payload_binding_version,
                      payload_binding_key_tag, payload_binding_mac)
          ON public.telegram_assistant_steps TO maraithon_incident_operator;
        GRANT UPDATE (payload_ciphertext, preview_text_ciphertext,
                      payload_encryption_version, payload_binding_version,
                      payload_binding_key_tag, payload_binding_mac)
          ON public.telegram_prepared_actions TO maraithon_incident_operator;
        GRANT UPDATE (trigger_ciphertext, metadata_ciphertext, private_payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.agent_runs TO maraithon_incident_operator;
        GRANT UPDATE (payload_ciphertext, metadata_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.operator_events TO maraithon_incident_operator;
        GRANT UPDATE (summary_ciphertext, profile_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.user_memory_profiles TO maraithon_incident_operator;
        GRANT UPDATE (content_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.operator_memory_summaries TO maraithon_incident_operator;
        GRANT UPDATE (payload_ciphertext, result_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.background_jobs TO maraithon_incident_operator;
        GRANT UPDATE (payload_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.scheduled_jobs TO maraithon_incident_operator;
        GRANT UPDATE (payload_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.runtime_ingress_receipts TO maraithon_incident_operator;
        GRANT UPDATE (result_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac,
                      result_digest, result_digest_version, result_digest_key_tag)
          ON public.agent_work_results TO maraithon_incident_operator;
        GRANT UPDATE (state_data_ciphertext, budget_ciphertext, payload_encryption_version,
                      payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.snapshots TO maraithon_incident_operator;
      END IF;

      IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'maraithon_activation_operator'
      ) THEN
        GRANT SELECT, UPDATE ON public.effect_execution_protocols
          TO maraithon_activation_operator;
        GRANT SELECT, INSERT, UPDATE ON public.durable_payload_binding_operations
          TO maraithon_activation_operator;
        GRANT EXECUTE ON FUNCTION
          public.durable_payload_row_identity(text, text),
          public.durable_payload_digest_part(text, jsonb, text),
          public.durable_payload_proof_failures(),
          public.durable_payload_source_acl_ready(),
          public.durable_payload_roles_ready(),
          public.durable_payload_operator_row_mutation_authorized(regclass,text,jsonb,jsonb),
          public.lock_durable_runtime_activation_sources(),
          public.lock_durable_payload_contraction_sources(),
          public.lock_durable_payload_contraction_coordination(),
          public.delete_durable_payload_verification(text, text)
          TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.effects TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.agent_directives TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.events TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.agent_run_steps TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.telegram_conversation_turns TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.telegram_conversations TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.telegram_assistant_runs TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.telegram_assistant_steps TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.telegram_prepared_actions TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.agent_runs TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.operator_events TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.user_memory_profiles TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.operator_memory_summaries TO maraithon_activation_operator;
        GRANT UPDATE (
          payload, payload_ciphertext, result, result_ciphertext,
          payload_encryption_version, payload_binding_version,
          payload_binding_key_tag, payload_binding_mac, updated_at
        ) ON public.background_jobs TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.scheduled_jobs TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.runtime_ingress_receipts TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.snapshots TO maraithon_activation_operator;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.agent_work_results TO maraithon_activation_operator;
        GRANT UPDATE (result_digest, result_digest_version, result_digest_key_tag)
          ON public.agent_work_results TO maraithon_activation_operator;
        GRANT SELECT
          ON public.effects, public.agent_directives, public.events, public.agent_run_steps,
             public.telegram_conversation_turns, public.telegram_conversations,
             public.telegram_assistant_runs, public.telegram_assistant_steps,
             public.telegram_prepared_actions, public.agent_runs, public.operator_events,
             public.user_memory_profiles, public.operator_memory_summaries,
             public.background_jobs, public.scheduled_jobs,
             public.runtime_ingress_receipts, public.agent_work_results, public.snapshots
          TO maraithon_activation_operator;
        GRANT UPDATE (
          params, params_ciphertext, result, result_ciphertext, error,
          payload_encryption_version, payload_binding_version,
          payload_binding_key_tag, payload_binding_mac, updated_at
        ) ON public.effects TO maraithon_activation_operator;
        GRANT UPDATE (
          payload, payload_ciphertext, payload_encryption_version,
          payload_binding_version, payload_binding_key_tag, payload_binding_mac,
          payload_purged_at, updated_at
        ) ON public.agent_directives TO maraithon_activation_operator;
        GRANT UPDATE (
          payload, payload_ciphertext, payload_encryption_version,
          payload_binding_version, payload_binding_key_tag, payload_binding_mac,
          spend_total_cost, spend_input_tokens, spend_output_tokens, spend_llm_calls
        ) ON public.events TO maraithon_activation_operator;
        GRANT UPDATE (
          request_payload, request_payload_ciphertext,
          response_payload, response_payload_ciphertext,
          payload_encryption_version, payload_binding_version,
          payload_binding_key_tag, payload_binding_mac, updated_at
        ) ON public.agent_run_steps TO maraithon_activation_operator;
        GRANT UPDATE (
          state_data, state_data_ciphertext, budget, budget_ciphertext,
          payload_encryption_version, payload_binding_version,
          payload_binding_key_tag, payload_binding_mac
        ) ON public.snapshots TO maraithon_activation_operator;
        GRANT SELECT
          ON public.agents, public.agent_runtime_leases, public.agent_runs,
             public.effects, public.agent_directives, public.events, public.agent_run_steps,
             public.telegram_conversation_turns, public.telegram_conversations,
             public.telegram_assistant_runs, public.telegram_assistant_steps,
             public.telegram_prepared_actions, public.operator_events,
             public.user_memory_profiles, public.operator_memory_summaries,
             public.background_jobs, public.scheduled_jobs,
             public.runtime_ingress_receipts, public.agent_work_results,
             public.durable_payload_verifications,
             public.durable_payload_verification_failures,
             public.effect_execution_protocol_manifests,
             public.effect_termination_attestations,
             public.schema_migrations
          TO maraithon_activation_operator;
        GRANT UPDATE ON public.durable_payload_verifications,
          public.durable_payload_verification_failures
          TO maraithon_activation_operator;
      END IF;
    END
    $grants$
    """)

    execute("""
    DO $ownership$
    DECLARE
      relation_name text;
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'maraithon_object_owner'
      ) THEN
        FOREACH relation_name IN ARRAY ARRAY['effects', 'agent_directives', 'events', 'agent_run_steps', 'telegram_conversation_turns', 'telegram_conversations', 'telegram_assistant_runs', 'telegram_assistant_steps', 'telegram_prepared_actions', 'agent_runs', 'operator_events', 'user_memory_profiles', 'operator_memory_summaries', 'background_jobs', 'scheduled_jobs', 'runtime_ingress_receipts', 'snapshots', 'agent_work_results', 'connected_accounts', 'oauth_tokens', 'local_browser_visits', 'local_calendar_events', 'local_files', 'memory_items'] LOOP
          EXECUTE pg_catalog.format(
            'ALTER TABLE public.%I OWNER TO maraithon_object_owner', relation_name
          );
        END LOOP;

        ALTER TABLE public.durable_payload_verifications OWNER TO maraithon_object_owner;
        ALTER TABLE public.durable_payload_verification_failures OWNER TO maraithon_object_owner;
        ALTER TABLE public.vault_reencryption_failures OWNER TO maraithon_object_owner;
        ALTER TABLE public.vault_backup_retirement_evidence OWNER TO maraithon_object_owner;
        ALTER TABLE public.durable_payload_binding_operations OWNER TO maraithon_object_owner;
        ALTER TABLE public.key_retirement_zero_proofs OWNER TO maraithon_object_owner;
        ALTER TABLE public.durable_payload_key_fence_state OWNER TO maraithon_object_owner;
        ALTER TABLE public.retired_durable_payload_keys OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_row_identity(text, text)
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_digest_part(text, jsonb, text)
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_proof_failures()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_source_acl_ready()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_roles_ready()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.enforce_durable_history_payload_protocol()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_operator_mutation_authorized()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_operator_row_mutation_authorized(
          regclass, text, jsonb, jsonb
        ) OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_durable_payload_operator_source_mutation()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.lock_durable_runtime_activation_sources()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.lock_durable_payload_binding_sources()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.lock_durable_payload_contraction_sources()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.lock_durable_payload_contraction_coordination()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_old_key_live_count(text, text)
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_key_registry_definition(text)
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_old_key_source_digest(text, text)
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_ciphertext_key_tag(bytea)
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.advance_durable_payload_key_fence_epoch(text, text, uuid)
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_durable_payload_key_fence_state()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.durable_payload_key_write_fenced(text, text)
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_durable_payload_retired_key_write()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_durable_payload_binding_operation()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_key_retirement_zero_proof()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.sync_durable_payload_key_fence_from_zero_proof()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_vault_backup_retirement_evidence()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_retired_durable_payload_key()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_vault_reencryption_failure_write()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.snapshot_writer_authority_valid(uuid, uuid)
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.enforce_snapshot_payload_protocol()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_durable_payload_verification_failure_write()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_durable_payload_verification_write()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.delete_durable_payload_verification(text, text)
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.invalidate_durable_payload_verification()
          OWNER TO maraithon_object_owner;
      END IF;
    END
    $ownership$
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS public.durable_payload_protocol_manifests (
      name text PRIMARY KEY,
      migration_version bigint NOT NULL,
      catalog_manifest jsonb NOT NULL,
      manifest_digest bytea NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT durable_payload_protocol_manifests_singleton CHECK (
        name = 'durable_payload_140005'
        AND migration_version = 20260810140005
        AND pg_catalog.jsonb_typeof(catalog_manifest) = 'object'
        AND pg_catalog.octet_length(manifest_digest) = 32
      )
    )
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_catalog_manifest_snapshot()
    RETURNS jsonb
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
      WITH required_relations(relation_id) AS (
        VALUES
          ('public.runtime_coordination_protocols'::regclass),
          ('public.runtime_coordination_manifests'::regclass),
          ('public.effect_execution_protocols'::regclass),
          ('public.effect_execution_protocol_manifests'::regclass),
          ('public.effect_termination_attestations'::regclass),
          ('public.schema_migrations'::regclass),
          ('public.effects'::regclass),
          ('public.agent_directives'::regclass),
          ('public.events'::regclass),
          ('public.agent_run_steps'::regclass),
          ('public.telegram_conversation_turns'::regclass),
          ('public.telegram_conversations'::regclass),
          ('public.telegram_assistant_runs'::regclass),
          ('public.telegram_assistant_steps'::regclass),
          ('public.telegram_prepared_actions'::regclass),
          ('public.agent_runs'::regclass),
          ('public.operator_events'::regclass),
          ('public.user_memory_profiles'::regclass),
          ('public.operator_memory_summaries'::regclass),
          ('public.background_jobs'::regclass),
          ('public.scheduled_jobs'::regclass),
          ('public.runtime_ingress_receipts'::regclass),
          ('public.snapshots'::regclass),
          ('public.agent_work_results'::regclass),
          ('public.connected_accounts'::regclass),
          ('public.oauth_tokens'::regclass),
          ('public.local_browser_visits'::regclass),
          ('public.local_calendar_events'::regclass),
          ('public.local_files'::regclass),
          ('public.memory_items'::regclass),
          ('public.durable_payload_verifications'::regclass),
          ('public.durable_payload_verification_failures'::regclass),
          ('public.vault_reencryption_failures'::regclass),
          ('public.vault_backup_retirement_evidence'::regclass),
          ('public.durable_payload_binding_operations'::regclass),
          ('public.key_retirement_zero_proofs'::regclass),
          ('public.durable_payload_key_fence_state'::regclass),
          ('public.retired_durable_payload_keys'::regclass),
          ('public.durable_payload_protocol_manifests'::regclass)
      ), explicit_function_names(function_name) AS (
        VALUES ('durable_payload_row_identity'), ('durable_payload_digest_part'), ('durable_payload_proof_failures'), ('durable_payload_source_acl_ready'), ('durable_payload_roles_ready'), ('durable_payload_operator_mutation_authorized'), ('durable_payload_operator_row_mutation_authorized'), ('guard_durable_payload_operator_source_mutation'), ('lock_durable_runtime_activation_sources'), ('lock_durable_payload_binding_sources'), ('lock_durable_payload_contraction_sources'), ('lock_durable_payload_contraction_coordination'), ('durable_payload_old_key_live_count'), ('durable_payload_key_registry_definition'), ('durable_payload_old_key_source_digest'), ('durable_payload_ciphertext_key_tag'), ('advance_durable_payload_key_fence_epoch'), ('durable_payload_key_write_fenced'), ('snapshot_writer_authority_valid'), ('delete_durable_payload_verification'), ('runtime_catalog_table_fingerprint'), ('runtime_role_topology_fingerprint'), ('durable_payload_catalog_manifest_snapshot'), ('refresh_durable_payload_protocol_manifest'), ('durable_payload_catalog_ready'), ('reject_durable_payload_protocol_manifest_mutation'), ('reject_durable_effect_truncate')
      ), required_functions(function_id) AS (
        SELECT function_row.oid
        FROM pg_catalog.pg_proc AS function_row
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = function_row.pronamespace
         AND namespace.nspname = 'public'
        JOIN explicit_function_names AS required
          ON required.function_name = function_row.proname
        UNION
        SELECT trigger_row.tgfoid
        FROM pg_catalog.pg_trigger AS trigger_row
        JOIN required_relations AS required
          ON required.relation_id = trigger_row.tgrelid
        WHERE NOT trigger_row.tgisinternal
      ), function_fingerprints AS (
        SELECT COALESCE(pg_catalog.jsonb_object_agg(
          function_row.oid::regprocedure::text,
          pg_catalog.encode(public.digest(pg_catalog.convert_to(
            pg_catalog.jsonb_build_object(
              'definition', pg_catalog.pg_get_functiondef(function_row.oid),
              'owner', owner_row.rolname,
              'acl', function_row.proacl,
              'config', function_row.proconfig,
              'security_definer', function_row.prosecdef,
              'volatility', function_row.provolatile,
              'parallel', function_row.proparallel,
              'leakproof', function_row.proleakproof,
              'kind', function_row.prokind,
              'language', language_row.lanname
            )::text, 'UTF8'), 'sha256'), 'hex')
          ORDER BY function_row.oid::regprocedure::text
        ), '{}'::jsonb) AS value
        FROM required_functions AS required
        JOIN pg_catalog.pg_proc AS function_row ON function_row.oid = required.function_id
        JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner
        JOIN pg_catalog.pg_language AS language_row ON language_row.oid = function_row.prolang
      ), constraint_fingerprints AS (
        SELECT COALESCE(pg_catalog.jsonb_object_agg(
          relation.relname || '.' || constraint_row.conname,
          pg_catalog.encode(public.digest(pg_catalog.convert_to(
            pg_catalog.jsonb_build_object(
              'definition', pg_catalog.pg_get_constraintdef(constraint_row.oid, true),
              'type', constraint_row.contype,
              'validated', constraint_row.convalidated,
              'deferrable', constraint_row.condeferrable,
              'initially_deferred', constraint_row.condeferred,
              'local', constraint_row.conislocal,
              'inheritance_count', constraint_row.coninhcount,
              'no_inherit', constraint_row.connoinherit
            )::text, 'UTF8'), 'sha256'), 'hex')
          ORDER BY relation.relname, constraint_row.conname
        ), '{}'::jsonb) AS value
        FROM required_relations AS required
        JOIN pg_catalog.pg_class AS relation ON relation.oid = required.relation_id
        JOIN pg_catalog.pg_constraint AS constraint_row
          ON constraint_row.conrelid = required.relation_id
      ), index_fingerprints AS (
        SELECT COALESCE(pg_catalog.jsonb_object_agg(
          relation.relname || '.' || index_relation.relname,
          pg_catalog.encode(public.digest(pg_catalog.convert_to(
            pg_catalog.jsonb_build_object(
              'definition', pg_catalog.pg_get_indexdef(index_relation.oid),
              'owner', owner_row.rolname,
              'acl', index_relation.relacl,
              'valid', index_row.indisvalid,
              'ready', index_row.indisready,
              'live', index_row.indislive,
              'unique', index_row.indisunique,
              'primary', index_row.indisprimary,
              'exclusion', index_row.indisexclusion,
              'immediate', index_row.indimmediate,
              'clustered', index_row.indisclustered,
              'replica_identity', index_row.indisreplident,
              'check_xmin', index_row.indcheckxmin
            )::text, 'UTF8'), 'sha256'), 'hex')
          ORDER BY relation.relname, index_relation.relname
        ), '{}'::jsonb) AS value
        FROM required_relations AS required
        JOIN pg_catalog.pg_class AS relation ON relation.oid = required.relation_id
        JOIN pg_catalog.pg_index AS index_row ON index_row.indrelid = required.relation_id
        JOIN pg_catalog.pg_class AS index_relation ON index_relation.oid = index_row.indexrelid
        JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = index_relation.relowner
      ), trigger_fingerprints AS (
        SELECT COALESCE(pg_catalog.jsonb_object_agg(
          relation.relname || '.' || trigger_row.tgname,
          pg_catalog.encode(public.digest(pg_catalog.convert_to(
            pg_catalog.jsonb_build_object(
              'definition', pg_catalog.pg_get_triggerdef(trigger_row.oid, true),
              'enabled', trigger_row.tgenabled,
              'type', trigger_row.tgtype,
              'constraint', trigger_row.tgconstraint,
              'deferrable', trigger_row.tgdeferrable,
              'initially_deferred', trigger_row.tginitdeferred,
              'function', trigger_row.tgfoid::regprocedure::text
            )::text, 'UTF8'), 'sha256'), 'hex')
          ORDER BY relation.relname, trigger_row.tgname
        ), '{}'::jsonb) AS value
        FROM required_relations AS required
        JOIN pg_catalog.pg_class AS relation ON relation.oid = required.relation_id
        JOIN pg_catalog.pg_trigger AS trigger_row
          ON trigger_row.tgrelid = required.relation_id
         AND NOT trigger_row.tgisinternal
      ), catalog_fingerprints AS (
        SELECT pg_catalog.jsonb_object_agg(
          relation.oid::regclass::text,
          public.runtime_catalog_table_fingerprint(relation.oid)
          ORDER BY relation.oid::regclass::text
        ) AS value
        FROM required_relations AS required
        JOIN pg_catalog.pg_class AS relation ON relation.oid = required.relation_id
      ), missing_functions AS (
        SELECT COALESCE(pg_catalog.jsonb_agg(required.function_name ORDER BY required.function_name),
                        '[]'::jsonb) AS value
        FROM explicit_function_names AS required
        WHERE NOT EXISTS (
          SELECT 1
          FROM pg_catalog.pg_proc AS function_row
          JOIN pg_catalog.pg_namespace AS namespace
            ON namespace.oid = function_row.pronamespace
           AND namespace.nspname = 'public'
          WHERE function_row.proname = required.function_name
        )
      ), ambiguous_functions AS (
        SELECT COALESCE(
          pg_catalog.jsonb_agg(required.function_name ORDER BY required.function_name),
          '[]'::jsonb
        ) AS value
        FROM explicit_function_names AS required
        WHERE (
          SELECT count(*)
          FROM pg_catalog.pg_proc AS function_row
          JOIN pg_catalog.pg_namespace AS namespace
            ON namespace.oid = function_row.pronamespace
           AND namespace.nspname = 'public'
          WHERE function_row.proname = required.function_name
        ) <> 1
      ), unexpected_column_acl_grantees AS (
        SELECT COALESCE(
          pg_catalog.jsonb_agg(
            DISTINCT pg_catalog.jsonb_build_object(
              'relation', relation.oid::regclass::text,
              'column', attribute.attname,
              'grantee', COALESCE(grantee.rolname, 'PUBLIC')
            )
          ),
          '[]'::jsonb
        ) AS value
        FROM required_relations AS required
        JOIN pg_catalog.pg_class AS relation ON relation.oid = required.relation_id
        JOIN pg_catalog.pg_attribute AS attribute
          ON attribute.attrelid = relation.oid
         AND attribute.attnum > 0
         AND NOT attribute.attisdropped
        CROSS JOIN LATERAL pg_catalog.aclexplode(attribute.attacl) AS column_acl
        LEFT JOIN pg_catalog.pg_roles AS grantee ON grantee.oid = column_acl.grantee
        WHERE COALESCE(grantee.rolname, 'PUBLIC') NOT IN (
          'maraithon_object_owner', 'maraithon_migrator', 'maraithon_runtime',
          'maraithon_payload_verifier', 'maraithon_incident_operator',
          'maraithon_activation_operator'
        )
      ), schema_authority AS (
        SELECT pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.jsonb_build_object(
            'owner', owner_row.rolname,
            'acl', namespace.nspacl
          )::text, 'UTF8'), 'sha256'), 'hex') AS value
        FROM pg_catalog.pg_namespace AS namespace
        JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = namespace.nspowner
        WHERE namespace.nspname = 'public'
      )
      SELECT pg_catalog.jsonb_build_object(
        'functions', function_fingerprints.value,
        'constraints', constraint_fingerprints.value,
        'indexes', index_fingerprints.value,
        'triggers', trigger_fingerprints.value,
        'catalogs', catalog_fingerprints.value,
        'missing_functions', missing_functions.value,
        'ambiguous_functions', ambiguous_functions.value,
        'unexpected_column_acl_grantees', unexpected_column_acl_grantees.value,
        'source_acl_ready', public.durable_payload_source_acl_ready(),
        'role_topology', public.runtime_role_topology_fingerprint(),
        'schema_authority', schema_authority.value,
        'required_migrations', pg_catalog.to_jsonb(ARRAY[20260810132102, 20260810132103, 20260810140000, 20260810140001, 20260810140002, 20260810140003, 20260810140004, 20260810140005, 20260810140006, 20260810140007]::bigint[])
      )
      FROM function_fingerprints, constraint_fingerprints, index_fingerprints,
           trigger_fingerprints, catalog_fingerprints, missing_functions,
           ambiguous_functions, unexpected_column_acl_grantees, schema_authority
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.refresh_durable_payload_protocol_manifest()
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      runtime_mode text;
      effect_mode text;
      snapshot jsonb;
      prior_trigger_fingerprints jsonb;
      caller_superuser boolean;
    BEGIN
      SELECT rolsuper INTO STRICT caller_superuser
      FROM pg_catalog.pg_roles
      WHERE rolname = current_user;

      IF current_user IS DISTINCT FROM 'maraithon_migrator' AND NOT caller_superuser THEN
        RAISE EXCEPTION 'Durable payload manifest refresh requires migrator authority'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      SELECT mode INTO STRICT runtime_mode
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime'
      FOR SHARE;

      SELECT mode INTO STRICT effect_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF runtime_mode <> 'dark' OR effect_mode <> 'legacy' THEN
        RAISE EXCEPTION 'Durable payload manifest refresh is allowed only before exact activation'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT catalog_manifest -> 'triggers'
      INTO prior_trigger_fingerprints
      FROM public.durable_payload_protocol_manifests
      WHERE name = 'durable_payload_140005'
        AND migration_version = 20260810140005;

      snapshot := public.durable_payload_catalog_manifest_snapshot();

      IF snapshot -> 'ambiguous_functions' <> '[]'::jsonb OR
         snapshot -> 'unexpected_column_acl_grantees' <> '[]'::jsonb OR
         (snapshot ->> 'source_acl_ready')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'Durable payload manifest contains ambiguous functions or unreviewed source ACLs'
          USING ERRCODE = 'check_violation';
      END IF;

      IF prior_trigger_fingerprints IS NOT NULL AND EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_object_keys(snapshot -> 'triggers') AS current_trigger(key)
        WHERE NOT prior_trigger_fingerprints ? current_trigger.key
          AND current_trigger.key NOT IN (
           'connected_accounts.guard_durable_payload_retired_key_write_trigger',
           'oauth_tokens.guard_durable_payload_retired_key_write_trigger',
           'local_browser_visits.guard_durable_payload_retired_key_write_trigger',
           'local_calendar_events.guard_durable_payload_retired_key_write_trigger',
           'local_files.guard_durable_payload_retired_key_write_trigger',
           'memory_items.guard_durable_payload_retired_key_write_trigger',
           'effects.guard_durable_payload_retired_key_write_trigger',
           'agent_directives.guard_durable_payload_retired_key_write_trigger',
           'events.guard_durable_payload_retired_key_write_trigger',
           'agent_run_steps.guard_durable_payload_retired_key_write_trigger',
           'telegram_conversation_turns.guard_durable_payload_retired_key_write_trigger',
           'telegram_conversations.guard_durable_payload_retired_key_write_trigger',
           'telegram_assistant_runs.guard_durable_payload_retired_key_write_trigger',
           'telegram_assistant_steps.guard_durable_payload_retired_key_write_trigger',
           'telegram_prepared_actions.guard_durable_payload_retired_key_write_trigger',
           'agent_runs.guard_durable_payload_retired_key_write_trigger',
           'operator_events.guard_durable_payload_retired_key_write_trigger',
           'user_memory_profiles.guard_durable_payload_retired_key_write_trigger',
           'operator_memory_summaries.guard_durable_payload_retired_key_write_trigger',
           'background_jobs.guard_durable_payload_retired_key_write_trigger',
           'scheduled_jobs.guard_durable_payload_retired_key_write_trigger',
           'runtime_ingress_receipts.guard_durable_payload_retired_key_write_trigger',
           'agent_work_results.guard_durable_payload_retired_key_write_trigger',
           'snapshots.guard_durable_payload_retired_key_write_trigger',
           'connected_accounts.guard_durable_payload_operator_mutation_trigger',
           'oauth_tokens.guard_durable_payload_operator_mutation_trigger',
           'local_browser_visits.guard_durable_payload_operator_mutation_trigger',
           'local_calendar_events.guard_durable_payload_operator_mutation_trigger',
           'local_files.guard_durable_payload_operator_mutation_trigger',
           'memory_items.guard_durable_payload_operator_mutation_trigger',
           'effects.guard_durable_payload_operator_mutation_trigger',
           'agent_directives.guard_durable_payload_operator_mutation_trigger',
           'events.guard_durable_payload_operator_mutation_trigger',
           'agent_run_steps.guard_durable_payload_operator_mutation_trigger',
           'telegram_conversation_turns.guard_durable_payload_operator_mutation_trigger',
           'telegram_conversations.guard_durable_payload_operator_mutation_trigger',
           'telegram_assistant_runs.guard_durable_payload_operator_mutation_trigger',
           'telegram_assistant_steps.guard_durable_payload_operator_mutation_trigger',
           'telegram_prepared_actions.guard_durable_payload_operator_mutation_trigger',
           'agent_runs.guard_durable_payload_operator_mutation_trigger',
           'operator_events.guard_durable_payload_operator_mutation_trigger',
           'user_memory_profiles.guard_durable_payload_operator_mutation_trigger',
           'operator_memory_summaries.guard_durable_payload_operator_mutation_trigger',
           'background_jobs.guard_durable_payload_operator_mutation_trigger',
           'scheduled_jobs.guard_durable_payload_operator_mutation_trigger',
           'runtime_ingress_receipts.guard_durable_payload_operator_mutation_trigger',
           'agent_work_results.guard_durable_payload_operator_mutation_trigger',
           'snapshots.guard_durable_payload_operator_mutation_trigger',
           'snapshots.enforce_snapshot_payload_protocol_trigger',
           'agent_directives.enforce_agent_directives_operational_retention',
           'agent_run_steps.enforce_agent_run_steps_operational_retention',
           'agent_runs.enforce_agent_runs_operational_retention',
           'agent_work_results.enforce_agent_work_results_operational_retention',
           'background_jobs.enforce_background_jobs_operational_retention',
           'background_jobs.enforce_background_jobs_privacy_erasure_write_fence',
           'background_jobs.capture_privacy_erasure_job_deferral_receipt_trigger',
           'connected_accounts.enforce_connected_accounts_privacy_erasure_write_fence',
           'effect_execution_protocols.enforce_operational_privacy_activation_trigger',
           'effects.enforce_effects_operational_retention',
           'events.enforce_events_operational_retention',
           'oauth_tokens.enforce_oauth_tokens_privacy_erasure_write_fence',
           'operator_events.enforce_operator_events_operational_retention',
           'runtime_ingress_receipts.enforce_runtime_ingress_receipts_operational_retention',
           'scheduled_jobs.enforce_scheduled_jobs_operational_retention',
           'telegram_assistant_runs.enforce_telegram_assistant_runs_operational_retention',
           'telegram_assistant_steps.enforce_telegram_assistant_steps_operational_retention',
           'telegram_conversation_turns.enforce_telegram_conversation_turns_operational_retention',
           'telegram_conversations.enforce_telegram_conversations_operational_retention',
           'telegram_prepared_actions.enforce_telegram_prepared_actions_operational_retention',
           'key_retirement_zero_proofs.sync_durable_payload_key_fence_from_zero_proof_trigger',
           'durable_payload_key_fence_state.guard_durable_payload_key_fence_state_trigger',
           'durable_payload_key_fence_state.reject_durable_payload_key_fence_state_truncate_trigger',
           'retired_durable_payload_keys.guard_retired_durable_payload_key_trigger',
           'retired_durable_payload_keys.finalize_retired_durable_payload_key_fence_trigger',
           'retired_durable_payload_keys.reject_retired_durable_payload_keys_truncate_trigger'
          )
      ) THEN
        RAISE EXCEPTION 'Durable payload manifest contains an unexpected authority trigger'
          USING ERRCODE = 'check_violation';
      END IF;

      PERFORM set_config('maraithon.durable_payload_manifest_refresh',
                         'MIGRATOR_DARK_REFRESH_V1', true);

      INSERT INTO public.durable_payload_protocol_manifests (
        name, migration_version, catalog_manifest, manifest_digest,
        inserted_at, updated_at
      ) VALUES (
        'durable_payload_140005', 20260810140005, snapshot,
        public.digest(pg_catalog.convert_to(snapshot::text, 'UTF8'), 'sha256'),
        timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
      )
      ON CONFLICT (name) DO UPDATE SET
        migration_version = EXCLUDED.migration_version,
        catalog_manifest = EXCLUDED.catalog_manifest,
        manifest_digest = EXCLUDED.manifest_digest,
        updated_at = EXCLUDED.updated_at;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Durable payload manifest protocol authority is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_catalog_ready()
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      snapshot jsonb;
      stored_manifest jsonb;
      stored_digest bytea;
    BEGIN
      snapshot := public.durable_payload_catalog_manifest_snapshot();

      SELECT catalog_manifest, manifest_digest
      INTO STRICT stored_manifest, stored_digest
      FROM public.durable_payload_protocol_manifests
      WHERE name = 'durable_payload_140005'
        AND migration_version = 20260810140005;

      RETURN snapshot = stored_manifest
        AND stored_manifest -> 'missing_functions' = '[]'::jsonb
        AND stored_manifest -> 'ambiguous_functions' = '[]'::jsonb
        AND stored_manifest -> 'unexpected_column_acl_grantees' = '[]'::jsonb
        AND (stored_manifest ->> 'source_acl_ready')::boolean IS TRUE
        AND stored_digest = public.digest(
          pg_catalog.convert_to(stored_manifest::text, 'UTF8'), 'sha256'
        )
        AND (
          SELECT count(DISTINCT version) = 10
          FROM public.schema_migrations
          WHERE version IN (20260810132102, 20260810132103, 20260810140000, 20260810140001, 20260810140002, 20260810140003, 20260810140004, 20260810140005, 20260810140006, 20260810140007)
        );
    EXCEPTION WHEN no_data_found OR undefined_table OR undefined_function THEN
      RETURN false;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.reject_durable_payload_protocol_manifest_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      caller_superuser boolean;
    BEGIN
      SELECT rolsuper INTO STRICT caller_superuser
      FROM pg_catalog.pg_roles
      WHERE rolname = current_user;

      IF TG_OP = 'UPDATE' AND
         (current_user = 'maraithon_migrator' OR caller_superuser) AND
         current_setting('maraithon.durable_payload_manifest_refresh', true)
           = 'MIGRATOR_DARK_REFRESH_V1' THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'Durable payload protocol manifest is immutable'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute("""
    DROP TRIGGER IF EXISTS reject_durable_payload_protocol_manifest_mutation_trigger
      ON public.durable_payload_protocol_manifests
    """)

    execute("""
    CREATE TRIGGER reject_durable_payload_protocol_manifest_mutation_trigger
      BEFORE UPDATE OR DELETE ON public.durable_payload_protocol_manifests
      FOR EACH ROW EXECUTE FUNCTION public.reject_durable_payload_protocol_manifest_mutation()
    """)

    execute("""
    DROP TRIGGER IF EXISTS reject_durable_payload_protocol_manifest_truncate_trigger
      ON public.durable_payload_protocol_manifests
    """)

    execute("""
    CREATE TRIGGER reject_durable_payload_protocol_manifest_truncate_trigger
      BEFORE TRUNCATE ON public.durable_payload_protocol_manifests
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_payload_protocol_manifest_mutation()
    """)

    execute("""
    DO $payload_manifest_authority$
    BEGIN
      REVOKE ALL ON TABLE public.durable_payload_protocol_manifests
        FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier,
          maraithon_incident_operator, maraithon_activation_operator;
      REVOKE ALL ON FUNCTION
        public.durable_payload_catalog_manifest_snapshot(),
        public.refresh_durable_payload_protocol_manifest(),
        public.durable_payload_catalog_ready(),
        public.reject_durable_payload_protocol_manifest_mutation()
        FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier,
          maraithon_incident_operator, maraithon_activation_operator;
      GRANT SELECT ON TABLE public.durable_payload_protocol_manifests
        TO maraithon_runtime, maraithon_activation_operator;
      GRANT EXECUTE ON FUNCTION
        public.durable_payload_catalog_manifest_snapshot(),
        public.durable_payload_catalog_ready()
        TO maraithon_runtime, maraithon_incident_operator,
          maraithon_activation_operator;
      ALTER TABLE public.durable_payload_protocol_manifests OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.durable_payload_catalog_manifest_snapshot()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.refresh_durable_payload_protocol_manifest()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.durable_payload_catalog_ready()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.reject_durable_payload_protocol_manifest_mutation()
        OWNER TO maraithon_object_owner;
    END
    $payload_manifest_authority$
    """)

    execute("SELECT public.refresh_durable_payload_protocol_manifest()")
  end

  defp add_not_valid_constraint(table, name, expression) do
    ensure_constraint(table, name, expression, false)
  end

  defp add_valid_constraint(table, name, expression) do
    ensure_constraint(table, name, expression, true)
  end

  defp ensure_constraint(table, name, expression, validate?) do
    fingerprint =
      :crypto.hash(:sha256, "#{table}:#{name}:#{expression}")
      |> Base.encode16(case: :lower)

    execute("""
    DO $constraint$
    DECLARE
      constraint_oid oid;
      recorded_fingerprint text;
    BEGIN
      SELECT constraint_row.oid,
             pg_catalog.obj_description(constraint_row.oid, 'pg_constraint')
      INTO constraint_oid, recorded_fingerprint
      FROM pg_catalog.pg_constraint AS constraint_row
      WHERE constraint_row.conrelid = 'public.#{table}'::regclass
        AND constraint_row.conname = '#{name}';

      IF constraint_oid IS NOT NULL AND
         recorded_fingerprint IS DISTINCT FROM 'maraithon:#{fingerprint}' THEN
        ALTER TABLE public.#{table} DROP CONSTRAINT #{name};
        constraint_oid := NULL;
      END IF;

      IF constraint_oid IS NULL THEN
        ALTER TABLE public.#{table}
          ADD CONSTRAINT #{name} CHECK (#{expression}) NOT VALID;
        COMMENT ON CONSTRAINT #{name} ON public.#{table}
          IS 'maraithon:#{fingerprint}';
      END IF;
    END
    $constraint$;
    """)

    if validate? do
      execute("ALTER TABLE public.#{table} VALIDATE CONSTRAINT #{name}")
    end
  end

  defp ensure_index(table, name, columns, unique?) do
    columns_sql = Enum.join(columns, ", ")
    uniqueness = if unique?, do: "UNIQUE ", else: ""

    fingerprint =
      :crypto.hash(:sha256, "#{table}:#{name}:#{columns_sql}:#{unique?}")
      |> Base.encode16(case: :lower)

    execute("""
    DO $index$
    DECLARE
      index_oid oid;
      index_valid boolean;
      recorded_fingerprint text;
      owning_constraint text;
    BEGIN
      SELECT index_row.indexrelid,
             index_row.indisvalid AND index_row.indisready,
             pg_catalog.obj_description(index_row.indexrelid, 'pg_class')
      INTO index_oid, index_valid, recorded_fingerprint
      FROM pg_catalog.pg_index AS index_row
      WHERE index_row.indexrelid = pg_catalog.to_regclass('public.#{name}');

      IF index_oid IS NOT NULL AND
         (NOT index_valid OR
          recorded_fingerprint IS DISTINCT FROM 'maraithon:#{fingerprint}') THEN
        SELECT constraint_row.conname
        INTO owning_constraint
        FROM pg_catalog.pg_constraint AS constraint_row
        WHERE constraint_row.conindid = index_oid;

        IF owning_constraint IS NOT NULL THEN
          EXECUTE pg_catalog.format(
            'ALTER TABLE public.#{table} DROP CONSTRAINT %I',
            owning_constraint
          );
        ELSE
          DROP INDEX public.#{name};
        END IF;
      END IF;
    END
    $index$;
    """)

    execute(
      "CREATE #{uniqueness}INDEX IF NOT EXISTS #{name} " <>
        "ON public.#{table} (#{columns_sql})"
    )

    execute("COMMENT ON INDEX public.#{name} IS 'maraithon:#{fingerprint}'")
  end

  def down do
    raise "durable payload authentication proofs are an irreversible activation safety layer"
  end
end
