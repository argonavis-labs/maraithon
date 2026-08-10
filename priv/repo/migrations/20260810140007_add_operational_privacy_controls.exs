defmodule Maraithon.Repo.Migrations.AddOperationalPrivacyControls do
  use Ecto.Migration

  @moduledoc false

  # Existing durable tables can be large. Every heap change is a nullable,
  # metadata-only expansion and every index over an existing table is built
  # online. The operator code performs all cleanup in bounded locked batches.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute(
      "ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_erasure_requested_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE agent_directives ADD COLUMN IF NOT EXISTS terminal_acknowledged_at timestamp(6) without time zone"
    )

    for table <-
          ~w(telegram_assistant_runs telegram_prepared_actions operator_events background_jobs scheduled_jobs) do
      execute(
        "ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS content_purged_at timestamp(6) without time zone"
      )
    end

    create_privacy_retention_statuses()
    create_privacy_erasure_requests()
    create_privacy_erasure_agent_targets()
    create_privacy_erasure_provider_revocations()
    create_privacy_erasure_receipts()
    add_erasure_constraints()
    add_legacy_cascade_constraints()
    create_online_indexes()
  end

  def down do
    raise "operational privacy controls are irreversible after erasure or payload retention"
  end

  defp create_privacy_retention_statuses do
    execute("""
    CREATE TABLE IF NOT EXISTS privacy_retention_statuses (
      handler varchar(80) PRIMARY KEY,
      tenant_cursor varchar(320),
      backlog_count bigint NOT NULL DEFAULT 0,
      oldest_age_seconds bigint NOT NULL DEFAULT 0,
      consecutive_failures integer NOT NULL DEFAULT 0,
      alert_state varchar(16) NOT NULL DEFAULT 'ok',
      last_error_code varchar(128),
      last_started_at timestamp(6) without time zone,
      last_finished_at timestamp(6) without time zone,
      last_succeeded_at timestamp(6) without time zone,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_retention_statuses_shape_check CHECK (
        octet_length(handler) BETWEEN 1 AND 80
        AND backlog_count >= 0
        AND oldest_age_seconds >= 0
        AND consecutive_failures >= 0
        AND alert_state IN ('ok', 'warning', 'critical')
        AND (last_error_code IS NULL OR last_error_code ~ '^[a-z0-9_]{1,128}$')
      )
    )
    """)
  end

  defp create_privacy_erasure_requests do
    execute("""
    CREATE TABLE IF NOT EXISTS privacy_erasure_requests (
      id uuid PRIMARY KEY,
      scope varchar(16) NOT NULL,
      subject_user_id varchar(320),
      subject_agent_id uuid,
      idempotency_digest bytea,
      state varchar(32) NOT NULL DEFAULT 'requested',
      blocker_code varchar(128),
      target_agent_count integer NOT NULL DEFAULT 0,
      credentials_locally_revoked boolean NOT NULL DEFAULT false,
      provider_revocation_override boolean NOT NULL DEFAULT false,
      claim_token uuid,
      claimed_at timestamp(6) without time zone,
      claim_expires_at timestamp(6) without time zone,
      requested_at timestamp(6) without time zone NOT NULL,
      last_attempted_at timestamp(6) without time zone,
      completed_at timestamp(6) without time zone,
      expires_at timestamp(6) without time zone,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_erasure_requests_shape_check CHECK (
        scope IN ('user', 'agent')
        AND state IN ('requested', 'draining', 'revoking_credentials', 'erasing', 'completed')
        AND target_agent_count >= 0
        AND (idempotency_digest IS NULL OR octet_length(idempotency_digest) = 32)
        AND (blocker_code IS NULL OR blocker_code ~ '^[a-z0-9_]{1,128}$')
        AND ((claim_token IS NULL AND claimed_at IS NULL AND claim_expires_at IS NULL)
             OR (claim_token IS NOT NULL AND claimed_at IS NOT NULL
                 AND claim_expires_at IS NOT NULL AND claim_expires_at > claimed_at))
        AND ((state = 'completed' AND completed_at IS NOT NULL AND expires_at IS NOT NULL
              AND subject_user_id IS NULL AND subject_agent_id IS NULL
              AND idempotency_digest IS NULL)
             OR state <> 'completed')
      )
    )
    """)
  end

  defp create_privacy_erasure_agent_targets do
    execute("""
    CREATE TABLE IF NOT EXISTS privacy_erasure_agent_targets (
      id bigserial PRIMARY KEY,
      request_id uuid NOT NULL,
      agent_id uuid NOT NULL,
      state varchar(24) NOT NULL DEFAULT 'pending',
      blocker_code varchar(128),
      last_attempted_at timestamp(6) without time zone,
      drained_at timestamp(6) without time zone,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_erasure_agent_targets_shape_check CHECK (
        state IN ('pending', 'draining', 'drained', 'erasing')
        AND (blocker_code IS NULL OR blocker_code ~ '^[a-z0-9_]{1,128}$')
      ),
      CONSTRAINT privacy_erasure_agent_targets_request_id_fkey
        FOREIGN KEY (request_id) REFERENCES privacy_erasure_requests(id) ON DELETE CASCADE,
      CONSTRAINT privacy_erasure_agent_targets_agent_id_fkey
        FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
    )
    """)
  end

  defp create_privacy_erasure_provider_revocations do
    execute("""
    CREATE TABLE IF NOT EXISTS privacy_erasure_provider_revocations (
      id bigserial PRIMARY KEY,
      request_id uuid NOT NULL,
      credential_table varchar(32) NOT NULL,
      credential_row_id bigint NOT NULL,
      provider_code varchar(80) NOT NULL,
      state varchar(24) NOT NULL DEFAULT 'pending',
      attempt_count integer NOT NULL DEFAULT 0,
      error_code varchar(128),
      last_attempted_at timestamp(6) without time zone,
      completed_at timestamp(6) without time zone,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_erasure_provider_revocations_shape_check CHECK (
        credential_table IN ('oauth_tokens')
        AND credential_row_id >= 0
        AND octet_length(provider_code) BETWEEN 1 AND 80
        AND state IN ('pending', 'confirmed', 'unavailable', 'failed')
        AND attempt_count >= 0
        AND (error_code IS NULL OR error_code ~ '^[a-z0-9_]{1,128}$')
      ),
      CONSTRAINT privacy_erasure_provider_revocations_request_id_fkey
        FOREIGN KEY (request_id) REFERENCES privacy_erasure_requests(id) ON DELETE CASCADE
    )
    """)
  end

  defp create_privacy_erasure_receipts do
    execute("""
    CREATE TABLE IF NOT EXISTS privacy_erasure_receipts (
      id uuid PRIMARY KEY,
      request_id uuid NOT NULL,
      classification varchar(64) NOT NULL,
      scope varchar(16) NOT NULL,
      outcome varchar(24) NOT NULL,
      local_data_deleted boolean NOT NULL,
      credentials_locally_revoked boolean NOT NULL,
      provider_revocation_outcome varchar(32) NOT NULL,
      erased_agent_count integer NOT NULL DEFAULT 0,
      issued_at timestamp(6) without time zone NOT NULL,
      expires_at timestamp(6) without time zone NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_erasure_receipts_shape_check CHECK (
        classification = 'content_free_erasure_authority_v1'
        AND scope IN ('user', 'agent')
        AND outcome = 'completed'
        AND provider_revocation_outcome IN ('confirmed', 'partial_unverified', 'not_applicable')
        AND erased_agent_count >= 0
        AND expires_at > issued_at
      ),
      CONSTRAINT privacy_erasure_receipts_request_id_fkey
        FOREIGN KEY (request_id) REFERENCES privacy_erasure_requests(id) ON DELETE CASCADE
    )
    """)
  end

  defp add_erasure_constraints do
    add_constraint_unless_present(
      "privacy_erasure_requests",
      "privacy_erasure_requests_subject_user_id_fkey",
      "FOREIGN KEY (subject_user_id) REFERENCES users(id) ON DELETE SET NULL"
    )

    add_constraint_unless_present(
      "privacy_erasure_requests",
      "privacy_erasure_requests_subject_agent_id_fkey",
      "FOREIGN KEY (subject_agent_id) REFERENCES agents(id) ON DELETE SET NULL"
    )
  end

  defp add_legacy_cascade_constraints do
    # Fresh 140003 installs already have this FK. An already-expanded database
    # may have applied the earlier no-FK shape; NOT VALID avoids a table scan,
    # enforces all future writes/deletes, and is validated only after orphan
    # cleanup in the storage-only privacy operator.
    add_constraint_unless_present(
      "snapshot_quarantines",
      "snapshot_quarantines_agent_id_fkey",
      "FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE NOT VALID"
    )

    # Termination attestations contain operator/evidence identifiers and are not
    # legal receipts. They must follow the exact Effect row during erasure.
    add_constraint_unless_present(
      "effect_termination_attestations",
      "effect_termination_attestations_effect_id_fkey",
      "FOREIGN KEY (effect_id) REFERENCES effects(id) ON DELETE CASCADE NOT VALID"
    )
  end

  defp create_online_indexes do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS privacy_erasure_requests_active_user_index
    ON privacy_erasure_requests (subject_user_id)
    WHERE scope = 'user' AND state <> 'completed' AND subject_user_id IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS privacy_erasure_requests_active_agent_index
    ON privacy_erasure_requests (subject_agent_id)
    WHERE scope = 'agent' AND state <> 'completed' AND subject_agent_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS privacy_erasure_requests_work_index
    ON privacy_erasure_requests (last_attempted_at NULLS FIRST, requested_at, id)
    WHERE state <> 'completed'
    """)

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS privacy_erasure_agent_targets_identity_index
    ON privacy_erasure_agent_targets (request_id, agent_id)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS privacy_erasure_agent_targets_work_index
    ON privacy_erasure_agent_targets (request_id, state, last_attempted_at, id)
    """)

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS privacy_erasure_provider_revocations_identity_index
    ON privacy_erasure_provider_revocations (request_id, credential_table, credential_row_id)
    """)

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS privacy_erasure_receipts_request_index
    ON privacy_erasure_receipts (request_id)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS privacy_erasure_receipts_expiry_index
    ON privacy_erasure_receipts (expires_at, id)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS agent_directives_unpurged_ack_retention_index
    ON agent_directives (terminal_acknowledged_at, id)
    WHERE payload_purged_at IS NULL
      AND terminal_acknowledged_at IS NOT NULL
      AND status IN ('completed', 'dead_letter', 'cancelled')
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS telegram_assistant_runs_content_retention_index
    ON telegram_assistant_runs (finished_at, id)
    WHERE content_purged_at IS NULL AND finished_at IS NOT NULL
      AND status IN ('completed', 'failed', 'cancelled', 'degraded')
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS telegram_prepared_actions_content_retention_index
    ON telegram_prepared_actions (updated_at, id)
    WHERE content_purged_at IS NULL
      AND status IN ('executed', 'rejected', 'expired', 'failed')
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS operator_events_content_retention_index
    ON operator_events (occurred_at, id)
    WHERE content_purged_at IS NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS background_jobs_content_retention_index
    ON background_jobs (completed_at, failed_at, cancelled_at, id)
    WHERE content_purged_at IS NULL
      AND status IN ('completed', 'failed', 'cancelled')
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS scheduled_jobs_content_retention_index
    ON scheduled_jobs (delivered_at, id)
    WHERE content_purged_at IS NULL
      AND status IN ('delivered', 'cancelled')
    """)
  end

  defp add_constraint_unless_present(table, name, definition) do
    execute("""
    DO $privacy$
    BEGIN
      IF to_regclass('public.#{table}') IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.#{table}'::regclass AND conname = '#{name}'
      ) THEN
        ALTER TABLE public.#{table} ADD CONSTRAINT #{name} #{definition};
      END IF;
    END
    $privacy$
    """)
  end
end
