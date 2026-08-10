defmodule Maraithon.Repo.Migrations.EncryptTelegramConversationPayloads do
  use Ecto.Migration

  @moduledoc """
  Adds encrypted storage and content-erasure markers for conversation content
  and its durable derivatives without loading or rewriting an existing row.

  Legacy mode is a true expansion: application writers mirror bounded payloads
  into both the old and encrypted columns. The stopped-fleet contraction is a
  separate Vault/Repo-only operator action. Exact mode accepts only ciphertext
  plus legacy tombstones, and the transition is intentionally irreversible.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @binding_tables [
    {"telegram_conversation_turns", "content_scrubbed_at"},
    {"telegram_conversations", "content_scrubbed_at"},
    {"telegram_assistant_runs", "payload_purged_at"},
    {"telegram_assistant_steps", "payload_purged_at"},
    {"telegram_prepared_actions", "payload_purged_at"},
    {"agent_runs", "private_payload_purged_at"},
    {"operator_events", "payload_purged_at"},
    {"user_memory_profiles", "content_erased_at"},
    {"operator_memory_summaries", "content_erased_at"},
    {"background_jobs", "payload_purged_at"},
    {"scheduled_jobs", "payload_purged_at"},
    {"runtime_ingress_receipts", "payload_purged_at"},
    {"agent_work_results", "result_purged_at"}
  ]

  def up do
    add_columns()
    add_constraints()
    add_indexes()
    install_exact_mode_guards()
  end

  def down do
    raise """
    irreversible migration: conversation and derivative plaintext may have
    been erased after ciphertext promotion; dropping these columns could
    destroy the only retained copy
    """
  end

  defp add_columns do
    execute(
      "ALTER TABLE telegram_conversation_turns ADD COLUMN IF NOT EXISTS text_ciphertext bytea"
    )

    execute(
      "ALTER TABLE telegram_conversation_turns ADD COLUMN IF NOT EXISTS structured_data_ciphertext bytea"
    )

    execute(
      "ALTER TABLE telegram_conversation_turns ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute("ALTER TABLE telegram_conversation_turns ADD COLUMN IF NOT EXISTS text_bytes integer")

    execute(
      "ALTER TABLE telegram_conversation_turns ADD COLUMN IF NOT EXISTS assistant_run_id uuid"
    )

    execute(
      "ALTER TABLE telegram_conversation_turns ADD COLUMN IF NOT EXISTS message_class varchar(255)"
    )

    execute(
      "ALTER TABLE telegram_conversation_turns ADD COLUMN IF NOT EXISTS prepared_action_id uuid"
    )

    execute(
      "ALTER TABLE telegram_conversation_turns ADD COLUMN IF NOT EXISTS linked_todo_id uuid"
    )

    execute(
      "ALTER TABLE telegram_conversation_turns ADD COLUMN IF NOT EXISTS terminal_response boolean"
    )

    execute(
      "ALTER TABLE telegram_conversation_turns ADD COLUMN IF NOT EXISTS content_scrubbed_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE telegram_conversations ADD COLUMN IF NOT EXISTS summary_ciphertext bytea"
    )

    execute(
      "ALTER TABLE telegram_conversations ADD COLUMN IF NOT EXISTS historical_summary_ciphertext bytea"
    )

    execute(
      "ALTER TABLE telegram_conversations ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE telegram_conversations ADD COLUMN IF NOT EXISTS content_scrubbed_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE telegram_assistant_runs ADD COLUMN IF NOT EXISTS prompt_snapshot_ciphertext bytea"
    )

    execute(
      "ALTER TABLE telegram_assistant_runs ADD COLUMN IF NOT EXISTS result_summary_ciphertext bytea"
    )

    execute(
      "ALTER TABLE telegram_assistant_runs ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE telegram_assistant_runs ADD COLUMN IF NOT EXISTS payload_purged_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE telegram_assistant_runs ADD COLUMN IF NOT EXISTS delivery_checkpoint_source_message_id varchar(255)"
    )

    execute(
      "ALTER TABLE telegram_assistant_steps ADD COLUMN IF NOT EXISTS request_payload_ciphertext bytea"
    )

    execute(
      "ALTER TABLE telegram_assistant_steps ADD COLUMN IF NOT EXISTS response_payload_ciphertext bytea"
    )

    execute(
      "ALTER TABLE telegram_assistant_steps ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE telegram_assistant_steps ADD COLUMN IF NOT EXISTS payload_purged_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE telegram_prepared_actions ADD COLUMN IF NOT EXISTS payload_ciphertext bytea"
    )

    execute(
      "ALTER TABLE telegram_prepared_actions ADD COLUMN IF NOT EXISTS preview_text_ciphertext bytea"
    )

    execute(
      "ALTER TABLE telegram_prepared_actions ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE telegram_prepared_actions ADD COLUMN IF NOT EXISTS payload_purged_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE telegram_prepared_actions ADD COLUMN IF NOT EXISTS payload_todo_id varchar(255)"
    )

    execute(
      "ALTER TABLE telegram_prepared_actions ADD COLUMN IF NOT EXISTS payload_surviving_person_id varchar(255)"
    )

    execute(
      "ALTER TABLE telegram_prepared_actions ADD COLUMN IF NOT EXISTS payload_merged_person_id varchar(255)"
    )

    execute(
      "ALTER TABLE runtime_ingress_receipts ADD COLUMN IF NOT EXISTS payload_ciphertext bytea"
    )

    execute(
      "ALTER TABLE runtime_ingress_receipts ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE runtime_ingress_receipts ADD COLUMN IF NOT EXISTS payload_purged_at timestamp(6) without time zone"
    )

    execute("ALTER TABLE agent_work_results ADD COLUMN IF NOT EXISTS result_ciphertext bytea")

    execute(
      "ALTER TABLE agent_work_results ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE agent_work_results ADD COLUMN IF NOT EXISTS result_purged_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE agent_work_results ADD COLUMN IF NOT EXISTS result_digest_version smallint"
    )

    execute(
      "ALTER TABLE agent_work_results ADD COLUMN IF NOT EXISTS result_digest_key_tag varchar(64)"
    )

    execute("ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS trigger_ciphertext bytea")
    execute("ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS metadata_ciphertext bytea")

    execute(
      "ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS private_payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS private_payload_purged_at timestamp(6) without time zone"
    )

    execute("ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS budget_llm_calls integer")
    execute("ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS budget_tool_calls integer")

    execute("ALTER TABLE operator_events ADD COLUMN IF NOT EXISTS payload_ciphertext bytea")
    execute("ALTER TABLE operator_events ADD COLUMN IF NOT EXISTS metadata_ciphertext bytea")

    execute(
      "ALTER TABLE operator_events ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE operator_events ADD COLUMN IF NOT EXISTS payload_purged_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE operator_events ADD COLUMN IF NOT EXISTS conversation_content_redacted_at timestamp(6) without time zone"
    )

    execute("ALTER TABLE user_memory_profiles ADD COLUMN IF NOT EXISTS summary_ciphertext bytea")
    execute("ALTER TABLE user_memory_profiles ADD COLUMN IF NOT EXISTS profile_ciphertext bytea")

    execute(
      "ALTER TABLE user_memory_profiles ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE user_memory_profiles ADD COLUMN IF NOT EXISTS content_erased_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE operator_memory_summaries ADD COLUMN IF NOT EXISTS content_ciphertext bytea"
    )

    execute(
      "ALTER TABLE operator_memory_summaries ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE operator_memory_summaries ADD COLUMN IF NOT EXISTS content_erased_at timestamp(6) without time zone"
    )

    execute("ALTER TABLE background_jobs ADD COLUMN IF NOT EXISTS payload_ciphertext bytea")
    execute("ALTER TABLE background_jobs ADD COLUMN IF NOT EXISTS result_ciphertext bytea")

    execute(
      "ALTER TABLE background_jobs ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE background_jobs ADD COLUMN IF NOT EXISTS payload_purged_at timestamp(6) without time zone"
    )

    execute("ALTER TABLE scheduled_jobs ADD COLUMN IF NOT EXISTS payload_ciphertext bytea")

    execute(
      "ALTER TABLE scheduled_jobs ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE scheduled_jobs ADD COLUMN IF NOT EXISTS payload_purged_at timestamp(6) without time zone"
    )

    execute("ALTER TABLE scheduled_jobs ADD COLUMN IF NOT EXISTS payload_scope_key varchar(255)")

    execute(
      "ALTER TABLE scheduled_jobs ADD COLUMN IF NOT EXISTS payload_scope_value varchar(255)"
    )

    execute("ALTER TABLE scheduled_jobs ADD COLUMN IF NOT EXISTS payload_dedupe_key varchar(255)")
    execute("ALTER TABLE scheduled_jobs ADD COLUMN IF NOT EXISTS payload_empty boolean")

    Enum.each(@binding_tables, fn {table, _purge_column} -> add_binding_columns(table) end)
  end

  defp add_constraints do
    add_constraint_unless_present(
      "telegram_conversation_turns",
      "telegram_conversation_turns_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (text_bytes IS NULL OR text_bytes BETWEEN 0 AND 64000)
      AND (message_class IS NULL OR octet_length(message_class) BETWEEN 1 AND 100)
      AND (text_ciphertext IS NULL OR octet_length(text_ciphertext) <= 70000)
      AND (structured_data_ciphertext IS NULL OR octet_length(structured_data_ciphertext) <= 200000)
      """
    )

    add_constraint_unless_present(
      "telegram_conversation_turns",
      "telegram_conversation_turns_scrubbed_payload_empty",
      """
      content_scrubbed_at IS NULL OR (
        text_ciphertext IS NULL
        AND structured_data_ciphertext IS NULL
        AND text = '[encrypted]'
        AND structured_data = '{}'::jsonb
      )
      """
    )

    add_constraint_unless_present(
      "telegram_conversations",
      "telegram_conversations_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (summary_ciphertext IS NULL OR octet_length(summary_ciphertext) <= 40000)
      AND (historical_summary_ciphertext IS NULL OR octet_length(historical_summary_ciphertext) <= 40000)
      """
    )

    add_constraint_unless_present(
      "telegram_conversations",
      "telegram_conversations_scrubbed_payload_empty",
      """
      content_scrubbed_at IS NULL OR (
        summary_ciphertext IS NULL
        AND historical_summary_ciphertext IS NULL
        AND summary IS NULL
        AND NOT jsonb_exists(metadata, 'historical_summary')
      )
      """
    )

    add_constraint_unless_present(
      "telegram_assistant_runs",
      "telegram_assistant_runs_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (prompt_snapshot_ciphertext IS NULL OR octet_length(prompt_snapshot_ciphertext) <= 700000)
      AND (result_summary_ciphertext IS NULL OR octet_length(result_summary_ciphertext) <= 300000)
      AND (delivery_checkpoint_source_message_id IS NULL OR octet_length(delivery_checkpoint_source_message_id) BETWEEN 1 AND 255)
      AND (
        payload_purged_at IS NULL OR (
          prompt_snapshot_ciphertext IS NULL
          AND result_summary_ciphertext IS NULL
          AND prompt_snapshot = '{}'::jsonb
          AND result_summary = '{}'::jsonb
        )
      )
      """
    )

    add_constraint_unless_present(
      "telegram_assistant_steps",
      "telegram_assistant_steps_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (request_payload_ciphertext IS NULL OR octet_length(request_payload_ciphertext) <= 300000)
      AND (response_payload_ciphertext IS NULL OR octet_length(response_payload_ciphertext) <= 700000)
      AND (
        payload_purged_at IS NULL OR (
          request_payload_ciphertext IS NULL
          AND response_payload_ciphertext IS NULL
          AND request_payload = '{}'::jsonb
          AND response_payload = '{}'::jsonb
        )
      )
      """
    )

    add_constraint_unless_present(
      "telegram_prepared_actions",
      "telegram_prepared_actions_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (payload_ciphertext IS NULL OR octet_length(payload_ciphertext) <= 600000)
      AND (preview_text_ciphertext IS NULL OR octet_length(preview_text_ciphertext) <= 12000)
      AND (payload_todo_id IS NULL OR octet_length(payload_todo_id) BETWEEN 1 AND 255)
      AND (payload_surviving_person_id IS NULL OR octet_length(payload_surviving_person_id) BETWEEN 1 AND 255)
      AND (payload_merged_person_id IS NULL OR octet_length(payload_merged_person_id) BETWEEN 1 AND 255)
      AND (
        payload_purged_at IS NULL OR (
          status IN ('executed', 'rejected', 'expired', 'failed')
          AND payload_ciphertext IS NULL
          AND preview_text_ciphertext IS NULL
          AND payload = '{}'::jsonb
          AND preview_text IS NULL
          AND payload_todo_id IS NULL
          AND payload_surviving_person_id IS NULL
          AND payload_merged_person_id IS NULL
        )
      )
      """
    )

    add_constraint_unless_present(
      "runtime_ingress_receipts",
      "runtime_ingress_receipts_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (payload_ciphertext IS NULL OR octet_length(payload_ciphertext) <= 160000)
      AND (payload_purged_at IS NULL OR (payload_ciphertext IS NULL AND payload = '{}'::jsonb))
      """
    )

    add_constraint_unless_present(
      "agent_work_results",
      "agent_work_results_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (result_ciphertext IS NULL OR octet_length(result_ciphertext) <= 160000)
      AND (
        (result_digest_version IS NULL AND result_digest_key_tag IS NULL)
        OR (
          result_digest_version = 1
          AND result_digest_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
          AND octet_length(result_digest) = 32
        )
      )
      AND (
        result_purged_at IS NULL OR (
          status = 'committed'
          AND result_ciphertext IS NULL
          AND result = '{}'::jsonb
        )
      )
      """
    )

    add_constraint_unless_present(
      "agent_runs",
      "agent_runs_private_payload_bound",
      """
      (private_payload_encryption_version IS NULL OR private_payload_encryption_version = 1)
      AND (trigger_ciphertext IS NULL OR octet_length(trigger_ciphertext) <= 300000)
      AND (metadata_ciphertext IS NULL OR octet_length(metadata_ciphertext) <= 160000)
      AND (budget_llm_calls IS NULL OR budget_llm_calls BETWEEN 0 AND 1000000)
      AND (budget_tool_calls IS NULL OR budget_tool_calls BETWEEN 0 AND 1000000)
      AND jsonb_typeof(budget_snapshot) = 'object'
      AND budget_snapshot - 'llm_calls' - 'tool_calls' = '{}'::jsonb
      AND (NOT jsonb_exists(budget_snapshot, 'llm_calls') OR jsonb_typeof(budget_snapshot->'llm_calls') = 'number')
      AND (NOT jsonb_exists(budget_snapshot, 'tool_calls') OR jsonb_typeof(budget_snapshot->'tool_calls') = 'number')
      AND (
        private_payload_purged_at IS NULL OR (
          trigger_ciphertext IS NULL
          AND metadata_ciphertext IS NULL
          AND trigger = '{}'::jsonb
          AND metadata = '{}'::jsonb
        )
      )
      """
    )

    add_constraint_unless_present(
      "operator_events",
      "operator_events_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (payload_ciphertext IS NULL OR octet_length(payload_ciphertext) <= 300000)
      AND (metadata_ciphertext IS NULL OR octet_length(metadata_ciphertext) <= 160000)
      AND (
        payload_purged_at IS NULL OR (
          payload_ciphertext IS NULL
          AND metadata_ciphertext IS NULL
          AND payload = '{}'::jsonb
          AND metadata = '{}'::jsonb
        )
      )
      """
    )

    add_constraint_unless_present(
      "operator_events",
      "operator_events_conversation_copy_redacted",
      """
      source <> 'telegram'
      OR event_type <> 'conversation_turn.recorded'
      OR (
        NOT (payload ?| ARRAY['text', 'structured_data', 'summary', 'historical_summary'])
        AND NOT (metadata ?| ARRAY['text', 'structured_data', 'summary', 'historical_summary'])
      )
      """
    )

    add_constraint_unless_present(
      "user_memory_profiles",
      "user_memory_profiles_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (summary_ciphertext IS NULL OR octet_length(summary_ciphertext) <= 8000)
      AND (profile_ciphertext IS NULL OR octet_length(profile_ciphertext) <= 80000)
      AND (
        content_erased_at IS NULL OR (
          summary_ciphertext IS NULL
          AND profile_ciphertext IS NULL
          AND summary = '[encrypted]'
          AND profile = '{}'::jsonb
        )
      )
      """
    )

    add_constraint_unless_present(
      "operator_memory_summaries",
      "operator_memory_summaries_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (content_ciphertext IS NULL OR octet_length(content_ciphertext) <= 8000)
      AND (
        content_erased_at IS NULL OR (
          content_ciphertext IS NULL
          AND content = '[encrypted]'
        )
      )
      """
    )

    add_constraint_unless_present(
      "background_jobs",
      "background_jobs_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (payload_ciphertext IS NULL OR octet_length(payload_ciphertext) <= 700000)
      AND (result_ciphertext IS NULL OR octet_length(result_ciphertext) <= 300000)
      AND (
        payload_purged_at IS NULL OR (
          payload_ciphertext IS NULL
          AND result_ciphertext IS NULL
          AND payload = '{}'::jsonb
          AND result = '{}'::jsonb
        )
      )
      """
    )

    add_constraint_unless_present(
      "scheduled_jobs",
      "scheduled_jobs_private_payload_bound",
      """
      (payload_encryption_version IS NULL OR payload_encryption_version = 1)
      AND (payload_ciphertext IS NULL OR octet_length(payload_ciphertext) <= 200000)
      AND (payload_scope_key IS NULL OR octet_length(payload_scope_key) BETWEEN 1 AND 255)
      AND (payload_scope_value IS NULL OR octet_length(payload_scope_value) BETWEEN 1 AND 255)
      AND (payload_dedupe_key IS NULL OR octet_length(payload_dedupe_key) BETWEEN 1 AND 255)
      AND ((payload_scope_key IS NULL) = (payload_scope_value IS NULL))
      AND (
        payload_purged_at IS NULL OR (
          payload_ciphertext IS NULL
          AND payload = '{}'::jsonb
        )
      )
      """
    )

    Enum.each(@binding_tables, fn {table, purge_column} ->
      add_binding_constraint(table, purge_column)
    end)
  end

  defp add_indexes do
    recreate_index(
      "telegram_conversation_turns_run_message_class_index",
      "telegram_conversation_turns (conversation_id, assistant_run_id, message_class) WHERE assistant_run_id IS NOT NULL"
    )

    recreate_index(
      "telegram_conversation_turns_prepared_action_id_index",
      "telegram_conversation_turns (prepared_action_id) WHERE prepared_action_id IS NOT NULL"
    )

    recreate_index(
      "telegram_conversation_turns_linked_todo_id_index",
      "telegram_conversation_turns (linked_todo_id) WHERE linked_todo_id IS NOT NULL"
    )

    recreate_index(
      "telegram_conversation_turns_unscrubbed_retention_index",
      "telegram_conversation_turns (inserted_at, id) WHERE content_scrubbed_at IS NULL"
    )

    recreate_index(
      "telegram_conversations_unscrubbed_retention_index",
      "telegram_conversations (last_turn_at, id) WHERE status = 'closed' AND content_scrubbed_at IS NULL"
    )

    recreate_index(
      "telegram_assistant_runs_unpurged_payload_index",
      "telegram_assistant_runs (finished_at, id) WHERE payload_purged_at IS NULL"
    )

    recreate_index(
      "telegram_assistant_runs_delivery_checkpoint_source_index",
      "telegram_assistant_runs (conversation_id, delivery_checkpoint_source_message_id, started_at) WHERE delivery_checkpoint_source_message_id IS NOT NULL"
    )

    recreate_index(
      "telegram_assistant_steps_unpurged_payload_index",
      "telegram_assistant_steps (finished_at, id) WHERE payload_purged_at IS NULL"
    )

    recreate_index(
      "agent_runs_unpurged_private_payload_index",
      "agent_runs (completed_at, id) WHERE private_payload_purged_at IS NULL"
    )

    recreate_index(
      "background_jobs_unpurged_payload_index",
      "background_jobs (completed_at, failed_at, cancelled_at, id) WHERE payload_purged_at IS NULL"
    )

    recreate_index(
      "telegram_prepared_actions_unpurged_payload_index",
      "telegram_prepared_actions (status, expires_at, id) WHERE payload_purged_at IS NULL"
    )

    recreate_index(
      "telegram_prepared_actions_awaiting_todo_index",
      "telegram_prepared_actions (user_id, action_type, COALESCE(payload_todo_id, payload->>'todo_id')) WHERE status = 'awaiting_confirmation' AND COALESCE(payload_todo_id, payload->>'todo_id') IS NOT NULL",
      unique: true
    )

    recreate_index(
      "runtime_ingress_receipts_unpurged_payload_index",
      "runtime_ingress_receipts (received_at, id) WHERE payload_purged_at IS NULL"
    )

    recreate_index(
      "agent_work_results_unpurged_payload_index",
      "agent_work_results (committed_at, id) WHERE result_purged_at IS NULL"
    )

    recreate_index(
      "operator_events_unpurged_payload_index",
      "operator_events (occurred_at, id) WHERE payload_purged_at IS NULL"
    )

    recreate_index(
      "scheduled_jobs_active_scope_index",
      "scheduled_jobs (agent_id, job_type, payload_scope_key, payload_scope_value) WHERE status IN ('pending', 'dispatched')"
    )

    recreate_index(
      "scheduled_jobs_payload_dedupe_index",
      "scheduled_jobs (agent_id, job_type, payload_dedupe_key, inserted_at) WHERE payload_dedupe_key IS NOT NULL"
    )
  end

  defp install_exact_mode_guards do
    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_conversation_privacy_protocol()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      protocol_mode text;
      writer_protocol text;
      privacy_marker text;
    BEGIN
      SELECT mode INTO STRICT protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF protocol_mode = 'legacy' THEN
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END IF;

      IF protocol_mode <> 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Unknown conversation privacy protocol mode'
          USING ERRCODE = 'check_violation';
      END IF;

      writer_protocol := current_setting('maraithon.effect_writer_protocol', true);

      IF writer_protocol IS DISTINCT FROM 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Exact private payload mutation requires generation-fenced writer marker'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      privacy_marker := COALESCE(
        to_jsonb(NEW)->>'content_scrubbed_at',
        to_jsonb(NEW)->>'payload_purged_at',
        to_jsonb(NEW)->>'private_payload_purged_at',
        to_jsonb(NEW)->>'content_erased_at',
        to_jsonb(NEW)->>'result_purged_at'
      );

      IF privacy_marker IS NULL THEN
        IF NOT ((NEW.payload_binding_version = 1
                 AND NEW.payload_binding_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
                 AND octet_length(NEW.payload_binding_mac) = 32) IS TRUE) THEN
          RAISE EXCEPTION 'Exact private payload binding is missing or invalid'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF NOT ((NEW.payload_binding_version IS NULL
                  AND NEW.payload_binding_key_tag IS NULL
                  AND NEW.payload_binding_mac IS NULL) IS TRUE) THEN
        RAISE EXCEPTION 'Purged private payload binding must remain empty'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_TABLE_NAME = 'telegram_conversation_turns' THEN
        IF NEW.content_scrubbed_at IS NULL THEN
          IF NOT ((NEW.payload_encryption_version = 1
                   AND NEW.text_ciphertext IS NOT NULL
                   AND NEW.structured_data_ciphertext IS NOT NULL
                   AND NEW.text = '[encrypted]'
                   AND NEW.structured_data = '{}'::jsonb) IS TRUE) THEN
            RAISE EXCEPTION 'Exact Turn payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.text_ciphertext IS NULL
                    AND NEW.structured_data_ciphertext IS NULL
                    AND NEW.text = '[encrypted]'
                    AND NEW.structured_data = '{}'::jsonb) IS TRUE) THEN
          RAISE EXCEPTION 'Scrubbed Turn payload must remain empty'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'telegram_conversations' THEN
        IF NOT ((NEW.summary IS NULL
                 AND NOT jsonb_exists(NEW.metadata, 'historical_summary')) IS TRUE) THEN
          RAISE EXCEPTION 'Exact Conversation summaries must be ciphertext-only'
            USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.content_scrubbed_at IS NULL
           AND (NEW.summary_ciphertext IS NOT NULL OR NEW.historical_summary_ciphertext IS NOT NULL)
           AND NEW.payload_encryption_version IS DISTINCT FROM 1 THEN
          RAISE EXCEPTION 'Exact Conversation ciphertext version is missing'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'telegram_assistant_runs' THEN
        IF NEW.payload_purged_at IS NULL THEN
          IF NOT ((NEW.payload_encryption_version = 1
                   AND NEW.prompt_snapshot_ciphertext IS NOT NULL
                   AND NEW.result_summary_ciphertext IS NOT NULL
                   AND NEW.prompt_snapshot = '{}'::jsonb
                   AND NEW.result_summary = '{}'::jsonb) IS TRUE) THEN
            RAISE EXCEPTION 'Exact assistant Run payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.prompt_snapshot_ciphertext IS NULL
                    AND NEW.result_summary_ciphertext IS NULL
                    AND NEW.prompt_snapshot = '{}'::jsonb
                    AND NEW.result_summary = '{}'::jsonb) IS TRUE) THEN
          RAISE EXCEPTION 'Purged assistant Run payload must remain empty'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'telegram_assistant_steps' THEN
        IF NEW.payload_purged_at IS NULL THEN
          IF NOT ((NEW.payload_encryption_version = 1
                   AND NEW.request_payload_ciphertext IS NOT NULL
                   AND NEW.response_payload_ciphertext IS NOT NULL
                   AND NEW.request_payload = '{}'::jsonb
                   AND NEW.response_payload = '{}'::jsonb) IS TRUE) THEN
            RAISE EXCEPTION 'Exact assistant Step payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.request_payload_ciphertext IS NULL
                    AND NEW.response_payload_ciphertext IS NULL
                    AND NEW.request_payload = '{}'::jsonb
                    AND NEW.response_payload = '{}'::jsonb) IS TRUE) THEN
          RAISE EXCEPTION 'Purged assistant Step payload must remain empty'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'telegram_prepared_actions' THEN
        IF NEW.payload_purged_at IS NULL THEN
          IF NOT ((NEW.payload_encryption_version = 1
                   AND NEW.payload_ciphertext IS NOT NULL
                   AND NEW.preview_text_ciphertext IS NOT NULL
                   AND NEW.payload = '{}'::jsonb
                   AND NEW.preview_text IS NULL) IS TRUE) THEN
            RAISE EXCEPTION 'Exact PreparedAction payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.status IN ('executed', 'rejected', 'expired', 'failed')
                    AND NEW.payload_ciphertext IS NULL
                    AND NEW.preview_text_ciphertext IS NULL
                    AND NEW.payload = '{}'::jsonb
                    AND NEW.preview_text IS NULL) IS TRUE) THEN
          RAISE EXCEPTION 'Purged PreparedAction payload must remain empty and terminal'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'runtime_ingress_receipts' THEN
        IF NEW.payload_purged_at IS NULL THEN
          IF NOT ((NEW.payload_encryption_version = 1
                   AND NEW.payload_ciphertext IS NOT NULL
                   AND NEW.payload = '{}'::jsonb) IS TRUE) THEN
            RAISE EXCEPTION 'Exact IngressReceipt payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.payload_ciphertext IS NULL
                    AND NEW.payload = '{}'::jsonb) IS TRUE) THEN
          RAISE EXCEPTION 'Purged IngressReceipt payload must remain empty'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'agent_work_results' THEN
        IF NEW.result_purged_at IS NULL THEN
          IF NOT ((NEW.payload_encryption_version = 1
                   AND NEW.result_ciphertext IS NOT NULL
                   AND NEW.result = '{}'::jsonb
                   AND NEW.result_digest_version = 1
                   AND NEW.result_digest_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
                   AND octet_length(NEW.result_digest) = 32) IS TRUE) THEN
            RAISE EXCEPTION 'Exact AgentWorkResult payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.status = 'committed'
                    AND NEW.result_ciphertext IS NULL
                    AND NEW.result = '{}'::jsonb) IS TRUE) THEN
          RAISE EXCEPTION 'Purged AgentWorkResult payload must remain empty and committed'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'agent_runs' THEN
        IF NEW.private_payload_purged_at IS NULL THEN
          IF NOT ((NEW.private_payload_encryption_version = 1
                   AND NEW.trigger_ciphertext IS NOT NULL
                   AND NEW.metadata_ciphertext IS NOT NULL
                   AND NEW.trigger = '{}'::jsonb
                   AND NEW.metadata = '{}'::jsonb
                   AND NEW.budget_snapshot = '{}'::jsonb
                   AND NEW.budget_llm_calls IS NOT NULL
                   AND NEW.budget_tool_calls IS NOT NULL) IS TRUE) THEN
            RAISE EXCEPTION 'Exact AgentRun private payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.trigger_ciphertext IS NULL
                    AND NEW.metadata_ciphertext IS NULL
                    AND NEW.trigger = '{}'::jsonb
                    AND NEW.metadata = '{}'::jsonb
                    AND NEW.budget_snapshot = '{}'::jsonb) IS TRUE) THEN
          RAISE EXCEPTION 'Purged AgentRun private payload must remain empty'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'operator_events' THEN
        IF NEW.payload_purged_at IS NULL THEN
          IF NOT ((NEW.payload_encryption_version = 1
                   AND NEW.payload_ciphertext IS NOT NULL
                   AND NEW.metadata_ciphertext IS NOT NULL
                   AND NEW.payload = '{}'::jsonb
                   AND NEW.metadata = '{}'::jsonb) IS TRUE) THEN
            RAISE EXCEPTION 'Exact OperatorEvent payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.payload_ciphertext IS NULL
                    AND NEW.metadata_ciphertext IS NULL
                    AND NEW.payload = '{}'::jsonb
                    AND NEW.metadata = '{}'::jsonb) IS TRUE) THEN
          RAISE EXCEPTION 'Purged OperatorEvent payload must remain empty'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'user_memory_profiles' THEN
        IF NEW.content_erased_at IS NULL THEN
          IF NOT ((NEW.payload_encryption_version = 1
                   AND NEW.summary_ciphertext IS NOT NULL
                   AND NEW.profile_ciphertext IS NOT NULL
                   AND NEW.summary = '[encrypted]'
                   AND NEW.profile = '{}'::jsonb) IS TRUE) THEN
            RAISE EXCEPTION 'Exact UserMemory payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.summary_ciphertext IS NULL
                    AND NEW.profile_ciphertext IS NULL
                    AND NEW.summary = '[encrypted]'
                    AND NEW.profile = '{}'::jsonb) IS TRUE) THEN
          RAISE EXCEPTION 'Erased UserMemory payload must remain empty'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'operator_memory_summaries' THEN
        IF NEW.content_erased_at IS NULL THEN
          IF NOT ((NEW.payload_encryption_version = 1
                   AND NEW.content_ciphertext IS NOT NULL
                   AND NEW.content = '[encrypted]') IS TRUE) THEN
            RAISE EXCEPTION 'Exact OperatorMemory payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.content_ciphertext IS NULL
                    AND NEW.content = '[encrypted]') IS TRUE) THEN
          RAISE EXCEPTION 'Erased OperatorMemory payload must remain empty'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'background_jobs' THEN
        IF NEW.payload_purged_at IS NULL THEN
          IF NOT ((NEW.payload_encryption_version = 1
                   AND NEW.payload_ciphertext IS NOT NULL
                   AND NEW.result_ciphertext IS NOT NULL
                   AND NEW.payload = '{}'::jsonb
                   AND NEW.result = '{}'::jsonb) IS TRUE) THEN
            RAISE EXCEPTION 'Exact BackgroundJob payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.payload_ciphertext IS NULL
                    AND NEW.result_ciphertext IS NULL
                    AND NEW.payload = '{}'::jsonb
                    AND NEW.result = '{}'::jsonb) IS TRUE) THEN
          RAISE EXCEPTION 'Purged BackgroundJob payload must remain empty'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_TABLE_NAME = 'scheduled_jobs' THEN
        IF NEW.payload_purged_at IS NULL THEN
          IF NOT ((NEW.payload_encryption_version = 1
                   AND NEW.payload_ciphertext IS NOT NULL
                   AND NEW.payload = '{}'::jsonb
                   AND NEW.payload_empty IS NOT NULL) IS TRUE) THEN
            RAISE EXCEPTION 'Exact ScheduledJob payload must be ciphertext-only'
              USING ERRCODE = 'check_violation';
          END IF;
        ELSIF NOT ((NEW.payload_ciphertext IS NULL
                    AND NEW.payload = '{}'::jsonb) IS TRUE) THEN
          RAISE EXCEPTION 'Purged ScheduledJob payload must remain empty'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN NEW;
    EXCEPTION
      WHEN no_data_found THEN
        RAISE EXCEPTION 'Effect execution protocol row is missing'
          USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    Enum.each(
      ~w(telegram_conversation_turns telegram_conversations telegram_assistant_runs telegram_assistant_steps telegram_prepared_actions runtime_ingress_receipts agent_work_results agent_runs operator_events user_memory_profiles operator_memory_summaries background_jobs scheduled_jobs),
      fn table ->
        trigger = "enforce_#{table}_privacy_protocol"
        execute("DROP TRIGGER IF EXISTS #{trigger} ON #{table}")

        execute("""
        CREATE TRIGGER #{trigger}
        BEFORE INSERT OR UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION public.enforce_conversation_privacy_protocol()
        """)
      end
    )
  end

  defp add_binding_columns(table) do
    execute("ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS payload_binding_version smallint")
    execute("ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS payload_binding_key_tag varchar(64)")
    execute("ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS payload_binding_mac bytea")
  end

  defp add_binding_constraint(table, _purge_column) do
    add_constraint_unless_present(
      table,
      "#{table}_payload_binding_shape",
      """
      (
        payload_binding_version = 1
        AND payload_binding_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
        AND octet_length(payload_binding_mac) = 32
      ) OR (
        payload_binding_version IS NULL
        AND payload_binding_key_tag IS NULL
        AND payload_binding_mac IS NULL
      )
      """
    )
  end

  defp add_constraint_unless_present(table, name, expression) do
    execute("""
    DO $migration$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = '#{table}'::regclass
          AND conname = '#{name}'
      ) THEN
        ALTER TABLE #{table}
        ADD CONSTRAINT #{name}
        CHECK (#{expression}) NOT VALID;
      END IF;
    END
    $migration$
    """)
  end

  defp recreate_index(name, definition, opts \\ []) do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
    unique = if Keyword.get(opts, :unique, false), do: "UNIQUE ", else: ""
    execute("CREATE #{unique}INDEX CONCURRENTLY #{name} ON #{definition}")
  end
end
