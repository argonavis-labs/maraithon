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
                    WHEN 'agent_work_results' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id', source_row -> 'agent_id', source_row -> 'agent_directive_id', source_row -> 'agent_run_id', source_row -> 'result_digest_version', source_row -> 'result_digest_key_tag', source_row -> 'result_digest')
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
    CREATE OR REPLACE FUNCTION public.durable_payload_roles_ready()
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      roles_ready boolean;
    BEGIN
      SELECT COALESCE((
        SELECT
          NOT owner.rolcanlogin AND NOT owner.rolsuper AND NOT owner.rolcreatedb
          AND NOT owner.rolcreaterole AND NOT owner.rolreplication AND NOT owner.rolbypassrls
          AND NOT migrator.rolcanlogin AND NOT migrator.rolsuper AND NOT migrator.rolcreatedb
          AND NOT migrator.rolcreaterole AND NOT migrator.rolreplication AND NOT migrator.rolbypassrls
          AND NOT runtime.rolcanlogin AND NOT runtime.rolsuper AND NOT runtime.rolcreatedb
          AND NOT runtime.rolcreaterole AND NOT runtime.rolreplication AND NOT runtime.rolbypassrls
          AND NOT verifier.rolcanlogin AND NOT verifier.rolsuper AND NOT verifier.rolcreatedb
          AND NOT verifier.rolcreaterole AND NOT verifier.rolreplication AND NOT verifier.rolbypassrls
          AND NOT incident.rolcanlogin AND NOT incident.rolsuper AND NOT incident.rolcreatedb
          AND NOT incident.rolcreaterole AND NOT incident.rolreplication AND NOT incident.rolbypassrls
          AND NOT activation.rolcanlogin AND NOT activation.rolsuper AND NOT activation.rolcreatedb
          AND NOT activation.rolcreaterole AND NOT activation.rolreplication AND NOT activation.rolbypassrls
          AND pg_has_role(migrator.oid, owner.oid, 'member')
          AND NOT pg_has_role(runtime.oid, owner.oid, 'member')
          AND NOT pg_has_role(runtime.oid, migrator.oid, 'member')
          AND NOT pg_has_role(runtime.oid, verifier.oid, 'member')
          AND NOT pg_has_role(runtime.oid, incident.oid, 'member')
          AND NOT pg_has_role(runtime.oid, activation.oid, 'member')
          AND NOT pg_has_role(verifier.oid, owner.oid, 'member')
          AND NOT pg_has_role(verifier.oid, migrator.oid, 'member')
          AND NOT pg_has_role(verifier.oid, incident.oid, 'member')
          AND NOT pg_has_role(verifier.oid, activation.oid, 'member')
          AND NOT pg_has_role(incident.oid, verifier.oid, 'member')
          AND NOT pg_has_role(activation.oid, verifier.oid, 'member')
          AND NOT pg_has_role(verifier.oid, runtime.oid, 'member')
          AND NOT pg_has_role(incident.oid, owner.oid, 'member')
          AND NOT pg_has_role(incident.oid, migrator.oid, 'member')
          AND NOT pg_has_role(incident.oid, runtime.oid, 'member')
          AND NOT pg_has_role(incident.oid, verifier.oid, 'member')
          AND NOT pg_has_role(incident.oid, activation.oid, 'member')
          AND NOT pg_has_role(activation.oid, owner.oid, 'member')
          AND NOT pg_has_role(activation.oid, migrator.oid, 'member')
          AND NOT pg_has_role(activation.oid, runtime.oid, 'member')
          AND NOT pg_has_role(activation.oid, verifier.oid, 'member')
          AND NOT pg_has_role(activation.oid, incident.oid, 'member')
          AND NOT pg_has_role(owner.oid, runtime.oid, 'member')
          AND NOT pg_has_role(owner.oid, verifier.oid, 'member')
          AND NOT pg_has_role(owner.oid, incident.oid, 'member')
          AND NOT pg_has_role(owner.oid, activation.oid, 'member')
          AND NOT pg_has_role(migrator.oid, runtime.oid, 'member')
          AND NOT pg_has_role(migrator.oid, verifier.oid, 'member')
          AND NOT pg_has_role(migrator.oid, incident.oid, 'member')
          AND NOT pg_has_role(migrator.oid, activation.oid, 'member')
          AND (SELECT relowner = owner.oid FROM pg_catalog.pg_class
               WHERE oid = 'public.durable_payload_verifications'::regclass)
          AND (SELECT relowner = owner.oid FROM pg_catalog.pg_class
               WHERE oid = 'public.durable_payload_verification_failures'::regclass)
          AND has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'SELECT')
          AND has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'INSERT')
          AND has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'DELETE')
          AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'UPDATE')
          AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'TRUNCATE')
          AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'REFERENCES')
          AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'TRIGGER')
          AND has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'SELECT')
          AND has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'INSERT')
          AND has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'DELETE')
          AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'UPDATE')
          AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'TRUNCATE')
          AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'REFERENCES')
          AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'TRIGGER')
          AND NOT has_table_privilege(runtime.rolname, 'public.durable_payload_verifications', 'INSERT')
          AND NOT has_table_privilege(runtime.rolname, 'public.durable_payload_verifications', 'UPDATE')
          AND NOT has_table_privilege(runtime.rolname, 'public.durable_payload_verifications', 'TRUNCATE')
          AND NOT has_table_privilege(runtime.rolname, 'public.durable_payload_verification_failures', 'INSERT')
          AND NOT has_table_privilege(runtime.rolname, 'public.durable_payload_verification_failures', 'UPDATE')
          AND NOT has_table_privilege(runtime.rolname, 'public.durable_payload_verification_failures', 'TRUNCATE')
          AND has_function_privilege(runtime.rolname, 'public.delete_durable_payload_verification(text,text)', 'EXECUTE')
          AND has_function_privilege(verifier.rolname, 'public.delete_durable_payload_verification(text,text)', 'EXECUTE')
          AND NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_proc AS function_row
            CROSS JOIN LATERAL pg_catalog.aclexplode(
              COALESCE(function_row.proacl, pg_catalog.acldefault('f', function_row.proowner))
            ) AS acl
            WHERE function_row.oid =
                    'public.delete_durable_payload_verification(text,text)'::regprocedure
              AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE'
          )
          AND NOT EXISTS (
            SELECT 1
            FROM (
              VALUES
                ('effects'), ('agent_directives'), ('events'), ('agent_run_steps'),
                ('telegram_conversation_turns'), ('telegram_conversations'),
                ('telegram_assistant_runs'), ('telegram_assistant_steps'),
                ('telegram_prepared_actions'), ('agent_runs'), ('operator_events'),
                ('user_memory_profiles'), ('operator_memory_summaries'),
                ('background_jobs'), ('scheduled_jobs'),
                ('runtime_ingress_receipts'), ('agent_work_results'), ('snapshots')
            ) AS source(table_name)
            WHERE NOT has_table_privilege(verifier.rolname, 'public.' || source.table_name, 'SELECT')
               OR has_table_privilege(verifier.rolname, 'public.' || source.table_name, 'INSERT')
               OR has_table_privilege(verifier.rolname, 'public.' || source.table_name, 'UPDATE')
               OR has_table_privilege(verifier.rolname, 'public.' || source.table_name, 'DELETE')
               OR has_table_privilege(verifier.rolname, 'public.' || source.table_name, 'TRUNCATE')
               OR has_table_privilege(verifier.rolname, 'public.' || source.table_name, 'REFERENCES')
               OR has_table_privilege(verifier.rolname, 'public.' || source.table_name, 'TRIGGER')
          )
          AND NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_class AS relation
            CROSS JOIN LATERAL pg_catalog.aclexplode(
              COALESCE(relation.relacl, pg_catalog.acldefault('r', relation.relowner))
            ) AS acl
            WHERE relation.oid IN (
              'public.durable_payload_verifications'::regclass,
              'public.durable_payload_verification_failures'::regclass
            ) AND acl.grantee NOT IN (owner.oid, verifier.oid)
          )
        FROM pg_catalog.pg_roles AS owner
        JOIN pg_catalog.pg_roles AS migrator ON migrator.rolname = 'maraithon_migrator'
        JOIN pg_catalog.pg_roles AS runtime ON runtime.rolname = 'maraithon_runtime'
        JOIN pg_catalog.pg_roles AS verifier ON verifier.rolname = 'maraithon_payload_verifier'
        JOIN pg_catalog.pg_roles AS incident ON incident.rolname = 'maraithon_incident_operator'
        JOIN pg_catalog.pg_roles AS activation ON activation.rolname = 'maraithon_activation_operator'
        WHERE owner.rolname = 'maraithon_object_owner'
      ), false)
      INTO roles_ready;

      RETURN roles_ready;
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
    BEGIN
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
            AND (NEW.payload_ciphertext IS NULL) = (OLD.payload_ciphertext IS NULL)
            AND (to_jsonb(NEW) - ARRAY['payload_ciphertext']::text[])
                  IS NOT DISTINCT FROM
                (to_jsonb(OLD) - ARRAY['payload_ciphertext']::text[])
            AND NEW.payload_ciphertext IS DISTINCT FROM OLD.payload_ciphertext) OR
           (TG_TABLE_NAME = 'agent_run_steps'
            AND (NEW.request_payload_ciphertext IS NULL) =
                  (OLD.request_payload_ciphertext IS NULL)
            AND (NEW.response_payload_ciphertext IS NULL) =
                  (OLD.response_payload_ciphertext IS NULL)
            AND (to_jsonb(NEW) - ARRAY[
                  'request_payload_ciphertext', 'response_payload_ciphertext', 'updated_at'
                ]::text[]) IS NOT DISTINCT FROM
                (to_jsonb(OLD) - ARRAY[
                  'request_payload_ciphertext', 'response_payload_ciphertext', 'updated_at'
                ]::text[])
            AND (NEW.request_payload_ciphertext IS DISTINCT FROM
                   OLD.request_payload_ciphertext OR
                 NEW.response_payload_ciphertext IS DISTINCT FROM
                   OLD.response_payload_ciphertext))
         ) THEN
        RETURN NEW;
      END IF;

      valid_shape := CASE TG_TABLE_NAME
        WHEN 'events' THEN
          NEW.payload = '{}'::jsonb
          AND (
            (NEW.payload_purged_at IS NULL
              AND NEW.payload_encryption_version = 1
              AND NEW.payload_ciphertext IS NOT NULL
              AND NEW.payload_binding_version = 1
              AND NEW.payload_binding_key_tag IS NOT NULL
              AND octet_length(NEW.payload_binding_mac) = 32) OR
            (NEW.payload_purged_at IS NOT NULL
              AND NEW.payload_ciphertext IS NULL
              AND NEW.payload_binding_version IS NULL
              AND NEW.payload_binding_key_tag IS NULL
              AND NEW.payload_binding_mac IS NULL)
          )
        WHEN 'agent_run_steps' THEN
          NEW.request_payload = '{}'::jsonb
          AND NEW.response_payload = '{}'::jsonb
          AND (
            (NEW.payload_purged_at IS NULL
              AND NEW.payload_encryption_version = 1
              AND NEW.request_payload_ciphertext IS NOT NULL
              AND NEW.response_payload_ciphertext IS NOT NULL
              AND NEW.payload_binding_version = 1
              AND NEW.payload_binding_key_tag IS NOT NULL
              AND octet_length(NEW.payload_binding_mac) = 32) OR
            (NEW.payload_purged_at IS NOT NULL
              AND NEW.request_payload_ciphertext IS NULL
              AND NEW.response_payload_ciphertext IS NULL
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
    CREATE OR REPLACE FUNCTION public.guard_durable_payload_binding_operation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Durable payload binding progress cannot be deleted'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF NEW.operation_kind = 'legacy_context_rebind_v1' THEN
        IF current_user IS DISTINCT FROM 'maraithon_activation_operator' OR
           current_setting('maraithon.payload_contraction', true)
             IS DISTINCT FROM 'STOPPED_FLEET_EVIDENCE_V1' THEN
          RAISE EXCEPTION 'Legacy binding context promotion requires stopped-fleet activation authority'
            USING ERRCODE = 'insufficient_privilege';
        END IF;
      ELSIF NEW.operation_kind = 'binding_key_rotation_v1' THEN
        IF current_user IS DISTINCT FROM 'maraithon_incident_operator' OR
           current_setting('maraithon.binding_key_rotation', true)
             IS DISTINCT FROM 'BINDING_KEY_ROTATION_V1' THEN
          RAISE EXCEPTION 'Binding key rotation progress requires incident authority'
            USING ERRCODE = 'insufficient_privilege';
        END IF;
      ELSE
        RAISE EXCEPTION 'Unknown durable payload binding operation'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND (
        NEW.operation_kind IS DISTINCT FROM OLD.operation_kind OR
        NEW.payload_table IS DISTINCT FROM OLD.payload_table OR
        NEW.row_identity IS DISTINCT FROM OLD.row_identity OR
        NEW.target_key_tag IS DISTINCT FROM OLD.target_key_tag
      ) THEN
        RAISE EXCEPTION 'Durable payload binding progress identity is immutable'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      NEW.attempted_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
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
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Key retirement zero proofs are append-only'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF current_user IS DISTINCT FROM 'maraithon_incident_operator' OR
         current_setting('maraithon.key_retirement_zero_proof', true)
           IS DISTINCT FROM 'LIVE_ZERO_PROOF_V1' THEN
        RAISE EXCEPTION 'Key retirement zero proof requires incident authority'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      NEW.proved_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
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
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Vault backup retirement evidence is append-only'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF current_user IS DISTINCT FROM 'maraithon_incident_operator' OR
         current_setting('maraithon.vault_backup_evidence', true)
           IS DISTINCT FROM 'BACKUP_CATALOG_ATTESTED_V1' THEN
        RAISE EXCEPTION 'Vault backup evidence requires incident operator attestation'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      NEW.attested_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
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
    CREATE OR REPLACE FUNCTION public.enforce_snapshot_payload_protocol()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      protocol_mode text;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      SELECT mode INTO STRICT protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects';

      IF protocol_mode = 'legacy' THEN
        RETURN NEW;
      END IF;

      IF protocol_mode IS DISTINCT FROM 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Effect execution protocol mode is invalid'
          USING ERRCODE = 'check_violation';
      END IF;

      IF current_user NOT IN ('maraithon_runtime', 'maraithon_incident_operator',
                              'maraithon_activation_operator') THEN
        RAISE EXCEPTION 'Exact Snapshot mutation requires canonical role'
          USING ERRCODE = 'insufficient_privilege';
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

    execute("REVOKE ALL ON public.vault_backup_retirement_evidence FROM PUBLIC")
    execute("REVOKE ALL ON FUNCTION public.guard_vault_backup_retirement_evidence() FROM PUBLIC")
    execute("REVOKE ALL ON public.vault_reencryption_failures FROM PUBLIC")
    execute("REVOKE ALL ON FUNCTION public.guard_vault_reencryption_failure_write() FROM PUBLIC")

    execute("REVOKE ALL ON public.durable_payload_verifications FROM PUBLIC")
    execute("REVOKE ALL ON public.durable_payload_verification_failures FROM PUBLIC")

    execute(
      "REVOKE ALL ON FUNCTION public.delete_durable_payload_verification(text, text) FROM PUBLIC"
    )

    execute("REVOKE ALL ON FUNCTION public.enforce_snapshot_payload_protocol() FROM PUBLIC")

    execute("""
    DO $grants$
    BEGIN
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
        GRANT EXECUTE
          ON FUNCTION public.delete_durable_payload_verification(text, text)
          TO maraithon_payload_verifier;
      END IF;

      IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'maraithon_runtime'
      ) THEN
        GRANT EXECUTE
          ON FUNCTION public.delete_durable_payload_verification(text, text)
          TO maraithon_runtime;
      END IF;


      IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'maraithon_incident_operator'
      ) THEN
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
             public.vault_backup_retirement_evidence
          TO maraithon_incident_operator;
        GRANT INSERT ON public.vault_backup_retirement_evidence
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
        GRANT SELECT, UPDATE
          ON public.effects, public.agent_directives, public.events, public.agent_run_steps,
             public.telegram_conversation_turns, public.telegram_conversations,
             public.telegram_assistant_runs, public.telegram_assistant_steps,
             public.telegram_prepared_actions, public.agent_runs, public.operator_events,
             public.user_memory_profiles, public.operator_memory_summaries,
             public.background_jobs, public.scheduled_jobs,
             public.runtime_ingress_receipts, public.agent_work_results, public.snapshots
          TO maraithon_activation_operator;
        GRANT SELECT
          ON public.agent_runtime_leases, public.agent_runs,
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
      END IF;
    END
    $grants$
    """)

    execute("""
    DO $ownership$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'maraithon_object_owner'
      ) THEN
        ALTER TABLE public.durable_payload_verifications OWNER TO maraithon_object_owner;
        ALTER TABLE public.durable_payload_verification_failures OWNER TO maraithon_object_owner;
        ALTER TABLE public.vault_reencryption_failures OWNER TO maraithon_object_owner;
        ALTER TABLE public.vault_backup_retirement_evidence OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.delete_durable_payload_verification(text, text)
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.enforce_snapshot_payload_protocol()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_vault_reencryption_failure_write()
          OWNER TO maraithon_object_owner;
        ALTER FUNCTION public.guard_vault_backup_retirement_evidence()
          OWNER TO maraithon_object_owner;
      END IF;
    END
    $ownership$
    """)
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
