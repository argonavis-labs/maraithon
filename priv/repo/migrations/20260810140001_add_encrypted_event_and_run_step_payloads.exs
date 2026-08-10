defmodule Maraithon.Repo.Migrations.AddEncryptedEventAndRunStepPayloads do
  use Ecto.Migration

  # The heap changes below are nullable, metadata-only column additions. Keep
  # the retention indexes online so this migration never rewrites either
  # durable history table or holds a transaction open while indexing it.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("ALTER TABLE events ADD COLUMN IF NOT EXISTS payload_ciphertext bytea")

    execute(
      "ALTER TABLE events ADD COLUMN IF NOT EXISTS payload_purged_at timestamp(6) without time zone"
    )

    execute("ALTER TABLE events ADD COLUMN IF NOT EXISTS spend_total_cost double precision")
    execute("ALTER TABLE events ADD COLUMN IF NOT EXISTS spend_input_tokens bigint")
    execute("ALTER TABLE events ADD COLUMN IF NOT EXISTS spend_output_tokens bigint")
    execute("ALTER TABLE events ADD COLUMN IF NOT EXISTS spend_llm_calls bigint")

    execute(
      "ALTER TABLE agent_run_steps ADD COLUMN IF NOT EXISTS request_payload_ciphertext bytea"
    )

    execute(
      "ALTER TABLE agent_run_steps ADD COLUMN IF NOT EXISTS response_payload_ciphertext bytea"
    )

    execute(
      "ALTER TABLE agent_run_steps ADD COLUMN IF NOT EXISTS payload_purged_at timestamp(6) without time zone"
    )

    add_constraint_unless_present(
      "events",
      "events_encrypted_payload_storage_bound",
      "payload_ciphertext IS NULL OR octet_length(payload_ciphertext) <= 700000"
    )

    add_constraint_unless_present(
      "events",
      "events_purged_payload_is_empty",
      "payload_purged_at IS NULL OR (payload_ciphertext IS NULL AND payload = '{}'::jsonb)"
    )

    add_constraint_unless_present(
      "events",
      "events_spend_facts_are_bounded",
      """
      (spend_total_cost IS NULL OR (spend_total_cost >= 0 AND spend_total_cost <= 1000000000))
      AND (spend_input_tokens IS NULL OR (spend_input_tokens >= 0 AND spend_input_tokens <= 9223372036854775807))
      AND (spend_output_tokens IS NULL OR (spend_output_tokens >= 0 AND spend_output_tokens <= 9223372036854775807))
      AND (spend_llm_calls IS NULL OR spend_llm_calls BETWEEN 0 AND 1)
      """
    )

    add_constraint_unless_present(
      "agent_run_steps",
      "agent_run_steps_encrypted_payload_storage_bound",
      """
      (request_payload_ciphertext IS NULL OR octet_length(request_payload_ciphertext) <= 300000)
      AND (response_payload_ciphertext IS NULL OR octet_length(response_payload_ciphertext) <= 700000)
      """
    )

    add_constraint_unless_present(
      "agent_run_steps",
      "agent_run_steps_purged_payloads_are_empty",
      """
      payload_purged_at IS NULL OR (
        request_payload_ciphertext IS NULL
        AND response_payload_ciphertext IS NULL
        AND request_payload = '{}'::jsonb
        AND response_payload = '{}'::jsonb
      )
      """
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS events_unpurged_payload_retention_idx")

    execute("""
    CREATE INDEX CONCURRENTLY events_unpurged_payload_retention_idx
    ON events (inserted_at, id)
    WHERE payload_purged_at IS NULL
    """)

    execute("DROP INDEX CONCURRENTLY IF EXISTS agent_run_steps_unpurged_payload_retention_idx")

    execute("""
    CREATE INDEX CONCURRENTLY agent_run_steps_unpurged_payload_retention_idx
    ON agent_run_steps (completed_at, id)
    WHERE payload_purged_at IS NULL
      AND completed_at IS NOT NULL
      AND status IN ('completed', 'failed')
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS agent_run_steps_unpurged_payload_retention_idx")

    execute("DROP INDEX CONCURRENTLY IF EXISTS events_unpurged_payload_retention_idx")

    execute(
      "ALTER TABLE agent_run_steps DROP CONSTRAINT IF EXISTS agent_run_steps_purged_payloads_are_empty"
    )

    execute(
      "ALTER TABLE agent_run_steps DROP CONSTRAINT IF EXISTS agent_run_steps_encrypted_payload_storage_bound"
    )

    execute("ALTER TABLE events DROP CONSTRAINT IF EXISTS events_spend_facts_are_bounded")
    execute("ALTER TABLE events DROP CONSTRAINT IF EXISTS events_purged_payload_is_empty")
    execute("ALTER TABLE events DROP CONSTRAINT IF EXISTS events_encrypted_payload_storage_bound")

    execute("ALTER TABLE agent_run_steps DROP COLUMN IF EXISTS payload_purged_at")
    execute("ALTER TABLE agent_run_steps DROP COLUMN IF EXISTS response_payload_ciphertext")
    execute("ALTER TABLE agent_run_steps DROP COLUMN IF EXISTS request_payload_ciphertext")
    execute("ALTER TABLE events DROP COLUMN IF EXISTS spend_llm_calls")
    execute("ALTER TABLE events DROP COLUMN IF EXISTS spend_output_tokens")
    execute("ALTER TABLE events DROP COLUMN IF EXISTS spend_input_tokens")
    execute("ALTER TABLE events DROP COLUMN IF EXISTS spend_total_cost")
    execute("ALTER TABLE events DROP COLUMN IF EXISTS payload_purged_at")
    execute("ALTER TABLE events DROP COLUMN IF EXISTS payload_ciphertext")
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
end
