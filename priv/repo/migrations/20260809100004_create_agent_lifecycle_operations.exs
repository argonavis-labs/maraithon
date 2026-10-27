defmodule Maraithon.Repo.Migrations.CreateAgentLifecycleOperations do
  use Ecto.Migration

  def change do
    create table(:agent_lifecycle_operations, primary_key: false) do
      add :agent_id,
          references(:agents, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :operation_token, :uuid, null: false
      add :kind, :string, null: false
      add :state, :string, null: false, default: "draining"
      add :request_digest, :binary, null: false
      add :payload_digest, :binary, null: false
      add :payload, :map, null: false
      add :expected_owner_token, :uuid
      add :requires_external_drain, :boolean, null: false, default: false
      add :external_drain_confirmed_at, :utc_datetime_usec
      add :external_drain_evidence_digest, :binary
      add :initiated_at, :utc_datetime_usec, null: false
      add :last_attempted_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_lifecycle_operations, [:operation_token],
             name: :agent_lifecycle_operations_token_index
           )

    create index(:agent_lifecycle_operations, [:initiated_at, :agent_id],
             name: :agent_lifecycle_operations_reconcile_index
           )

    create constraint(:agent_lifecycle_operations, :agent_lifecycle_operations_kind_check,
             check: "kind IN ('stop', 'update', 'delete', 'pause', 'remove', 'upgrade')"
           )

    create constraint(:agent_lifecycle_operations, :agent_lifecycle_operations_state_check,
             check: "state = 'draining'"
           )

    create constraint(:agent_lifecycle_operations, :agent_lifecycle_operations_digest_check,
             check: "octet_length(request_digest) = 32 AND octet_length(payload_digest) = 32"
           )

    create constraint(:agent_lifecycle_operations, :agent_lifecycle_operations_payload_check,
             check: "jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 160000"
           )

    create constraint(
             :agent_lifecycle_operations,
             :agent_lifecycle_operations_external_drain_check,
             check: """
             (requires_external_drain = FALSE AND external_drain_confirmed_at IS NULL AND external_drain_evidence_digest IS NULL)
             OR
             (requires_external_drain = TRUE AND ((external_drain_confirmed_at IS NULL AND external_drain_evidence_digest IS NULL) OR (external_drain_confirmed_at IS NOT NULL AND octet_length(external_drain_evidence_digest) = 32)))
             """
           )

    alter table(:agent_isolation_bindings) do
      add :consent_token, :uuid
      add :consent_actor_id, :string
      add :consented_at, :utc_datetime_usec
      add :consent_digest, :binary
    end

    create unique_index(:agent_isolation_bindings, [:consent_token],
             where: "consent_token IS NOT NULL",
             name: :agent_isolation_bindings_consent_token_index
           )

    create constraint(:agent_isolation_bindings, :agent_isolation_bindings_consent_proof_check,
             check: """
             (consent_token IS NULL AND consent_actor_id IS NULL AND consented_at IS NULL AND consent_digest IS NULL)
             OR
             (consent_token IS NOT NULL AND consent_actor_id IS NOT NULL AND consented_at IS NOT NULL AND octet_length(consent_digest) = 32)
             """
           )
  end
end
