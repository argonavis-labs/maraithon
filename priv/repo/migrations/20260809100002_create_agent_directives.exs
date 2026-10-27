defmodule Maraithon.Repo.Migrations.CreateAgentDirectives do
  use Ecto.Migration

  def change do
    create table(:agent_directives, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, :binary_id, null: false
      add :user_id, :string, null: false
      add :kind, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :dedupe_key, :string, null: false
      add :request_fingerprint, :binary, null: false
      add :status, :string, null: false, default: "pending"
      add :available_at, :utc_datetime_usec, null: false
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 3
      add :claim_token, :binary_id
      add :claimed_by_generation, :binary_id
      add :claimed_at, :utc_datetime_usec
      add :claim_expires_at, :utc_datetime_usec
      add :processing_started_at, :utc_datetime_usec
      add :terminal_at, :utc_datetime_usec
      add :terminal_claim_token, :binary_id
      add :terminal_by_generation, :binary_id
      add :last_error_code, :string

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      """
      ALTER TABLE agent_directives
      ADD CONSTRAINT agent_directives_agent_owner_fkey
      FOREIGN KEY (agent_id, user_id)
      REFERENCES agents(id, user_id)
      ON DELETE CASCADE
      """,
      "ALTER TABLE agent_directives DROP CONSTRAINT agent_directives_agent_owner_fkey"
    )

    create unique_index(:agent_directives, [:agent_id, :dedupe_key])

    create unique_index(:agent_directives, [:claim_token],
             where: "claim_token IS NOT NULL",
             name: :agent_directives_claim_token_index
           )

    create unique_index(:agent_directives, [:agent_id],
             where: "status = 'processing'",
             name: :agent_directives_one_processing_per_agent_index
           )

    create index(:agent_directives, [:available_at, :inserted_at, :id],
             where: "status = 'pending'",
             name: :agent_directives_due_index
           )

    create index(
             :agent_directives,
             [:claim_expires_at, :id],
             where: "status = 'processing'",
             name: :agent_directives_processing_recovery_index
           )

    create index(:agent_directives, [:agent_id, :available_at, :inserted_at, :id],
             where: "status = 'pending'",
             name: :agent_directives_agent_due_index
           )

    create unique_index(:agent_directives, [:terminal_claim_token],
             where: "terminal_claim_token IS NOT NULL",
             name: :agent_directives_terminal_claim_token_index
           )

    create index(:agent_directives, [:user_id, :status, :available_at])

    create constraint(:agent_directives, :agent_directives_kind_check,
             check:
               "kind IN ('message', 'channel_ingress', 'connector_sync', 'scheduled_wakeup', 'manual_wake', 'background_job', 'runtime_control')"
           )

    create constraint(:agent_directives, :agent_directives_status_check,
             check: "status IN ('pending', 'processing', 'completed', 'dead_letter', 'cancelled')"
           )

    create constraint(:agent_directives, :agent_directives_user_id_check,
             check:
               "octet_length(user_id) BETWEEN 1 AND 320 AND user_id !~ '[[:space:][:cntrl:]]'"
           )

    create constraint(:agent_directives, :agent_directives_dedupe_key_check,
             check: "octet_length(dedupe_key) BETWEEN 1 AND 255 AND dedupe_key !~ '[[:cntrl:]]'"
           )

    create constraint(:agent_directives, :agent_directives_fingerprint_check,
             check: "octet_length(request_fingerprint) = 32"
           )

    create constraint(:agent_directives, :agent_directives_payload_check,
             check: "jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 160000"
           )

    create constraint(:agent_directives, :agent_directives_attempts_check,
             check:
               "attempts >= 0 AND max_attempts BETWEEN 1 AND 100 AND attempts <= max_attempts"
           )

    create constraint(:agent_directives, :agent_directives_pending_attempts_check,
             check: "status <> 'pending' OR attempts < max_attempts"
           )

    create constraint(:agent_directives, :agent_directives_claim_check,
             check: """
             (status = 'processing' AND claim_token IS NOT NULL AND claimed_by_generation IS NOT NULL AND claimed_at IS NOT NULL AND claim_expires_at IS NOT NULL AND processing_started_at IS NOT NULL AND terminal_at IS NULL AND claim_expires_at > claimed_at)
             OR
             (status <> 'processing' AND claim_token IS NULL AND claimed_by_generation IS NULL AND claimed_at IS NULL AND claim_expires_at IS NULL AND processing_started_at IS NULL)
             """
           )

    create constraint(:agent_directives, :agent_directives_terminal_check,
             check: """
             (status IN ('completed', 'dead_letter') AND terminal_at IS NOT NULL AND terminal_claim_token IS NOT NULL AND terminal_by_generation IS NOT NULL)
             OR
             (status = 'cancelled' AND terminal_at IS NOT NULL AND ((terminal_claim_token IS NULL AND terminal_by_generation IS NULL) OR (terminal_claim_token IS NOT NULL AND terminal_by_generation IS NOT NULL)))
             OR
             (status IN ('pending', 'processing') AND terminal_at IS NULL AND terminal_claim_token IS NULL AND terminal_by_generation IS NULL)
             """
           )

    create constraint(:agent_directives, :agent_directives_error_check,
             check:
               "last_error_code IS NULL OR (octet_length(last_error_code) BETWEEN 1 AND 64 AND last_error_code !~ '[^a-z0-9_]')"
           )
  end
end
