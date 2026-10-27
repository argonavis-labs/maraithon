defmodule Maraithon.Repo.Migrations.CreateChiefSemanticLineage do
  use Ecto.Migration

  @db_now "timezone('UTC', clock_timestamp())"

  def change do
    create table(:chief_semantic_effects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :effect_key, :binary, null: false
      add :user_id, :string, null: false
      add :agent_id, :binary_id, null: false
      add :agent_directive_id, :binary_id, null: false
      add :acquisition_run_id, :binary_id, null: false
      add :kind, :string, null: false
      add :subject_key, :string, null: false
      add :contract_version, :integer, null: false
      add :extractor_version, :string, null: false
      add :payload, :map, null: false
      add :payload_digest, :binary, null: false

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:chief_semantic_effects, [:user_id, :effect_key],
             name: :chief_semantic_effects_user_key_unique_index
           )

    create unique_index(
             :chief_semantic_effects,
             [:id, :acquisition_run_id],
             name: :chief_semantic_effects_id_acquisition_unique_index
           )

    create unique_index(
             :chief_semantic_effects,
             [:id, :agent_id, :user_id],
             name: :chief_semantic_effects_exact_owner_unique_index
           )

    create index(:chief_semantic_effects, [:acquisition_run_id, :kind, :id],
             name: :chief_semantic_effects_acquisition_index
           )

    create index(:chief_semantic_effects, [:user_id, :kind, :subject_key, :inserted_at],
             name: :chief_semantic_effects_subject_index
           )

    execute(
      """
      ALTER TABLE chief_semantic_effects
      ADD CONSTRAINT chief_semantic_effects_agent_owner_fkey
      FOREIGN KEY (agent_id, user_id) REFERENCES agents(id, user_id) ON DELETE CASCADE
      """,
      "ALTER TABLE chief_semantic_effects DROP CONSTRAINT chief_semantic_effects_agent_owner_fkey"
    )

    execute(
      """
      ALTER TABLE chief_semantic_effects
      ADD CONSTRAINT chief_semantic_effects_directive_owner_fkey
      FOREIGN KEY (agent_directive_id, agent_id, user_id)
      REFERENCES agent_directives(id, agent_id, user_id) ON DELETE CASCADE
      """,
      "ALTER TABLE chief_semantic_effects DROP CONSTRAINT chief_semantic_effects_directive_owner_fkey"
    )

    execute(
      """
      ALTER TABLE chief_semantic_effects
      ADD CONSTRAINT chief_semantic_effects_acquisition_owner_fkey
      FOREIGN KEY (acquisition_run_id, agent_directive_id, agent_id, user_id)
      REFERENCES chief_acquisition_runs(id, agent_directive_id, agent_id, user_id)
      ON DELETE CASCADE
      """,
      "ALTER TABLE chief_semantic_effects DROP CONSTRAINT chief_semantic_effects_acquisition_owner_fkey"
    )

    create constraint(:chief_semantic_effects, :chief_semantic_effects_kind_check,
             check: "kind IN ('todo','decision')"
           )

    create constraint(:chief_semantic_effects, :chief_semantic_effects_identity_check,
             check: """
             octet_length(user_id) BETWEEN 1 AND 320 AND user_id !~ '[[:space:][:cntrl:]]' AND
             octet_length(subject_key) BETWEEN 1 AND 1024 AND subject_key !~ '[[:cntrl:]]' AND
             octet_length(extractor_version) BETWEEN 1 AND 80 AND extractor_version !~ '[[:space:][:cntrl:]]' AND
             contract_version BETWEEN 1 AND 100
             """
           )

    create constraint(:chief_semantic_effects, :chief_semantic_effects_digest_check,
             check: "octet_length(effect_key) = 32 AND octet_length(payload_digest) = 32"
           )

    create constraint(:chief_semantic_effects, :chief_semantic_effects_payload_check,
             check: "jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 160000"
           )

    create table(:chief_semantic_effect_sources, primary_key: false) do
      add :semantic_effect_id, :binary_id, primary_key: true
      add :source_envelope_id, :binary_id, primary_key: true
      add :acquisition_run_id, :binary_id, null: false

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create index(:chief_semantic_effect_sources, [:source_envelope_id, :semantic_effect_id],
             name: :chief_semantic_effect_sources_envelope_index
           )

    execute(
      """
      ALTER TABLE chief_semantic_effect_sources
      ADD CONSTRAINT chief_semantic_effect_sources_effect_run_fkey
      FOREIGN KEY (semantic_effect_id, acquisition_run_id)
      REFERENCES chief_semantic_effects(id, acquisition_run_id) ON DELETE CASCADE
      """,
      "ALTER TABLE chief_semantic_effect_sources DROP CONSTRAINT chief_semantic_effect_sources_effect_run_fkey"
    )

    execute(
      """
      ALTER TABLE chief_semantic_effect_sources
      ADD CONSTRAINT chief_semantic_effect_sources_acquisition_envelope_fkey
      FOREIGN KEY (acquisition_run_id, source_envelope_id)
      REFERENCES chief_acquisition_envelopes(acquisition_run_id, source_envelope_id)
      ON DELETE RESTRICT
      """,
      "ALTER TABLE chief_semantic_effect_sources DROP CONSTRAINT chief_semantic_effect_sources_acquisition_envelope_fkey"
    )

    create table(:chief_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :decision_key, :binary, null: false
      add :decision_identity, :string, null: false
      add :user_id, :string, null: false
      add :agent_id, :binary_id, null: false
      add :semantic_effect_id, :binary_id, null: false
      add :kind, :string, null: false
      add :payload, :map, null: false
      add :payload_digest, :binary, null: false

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:chief_decisions, [:user_id, :decision_key],
             name: :chief_decisions_user_key_unique_index
           )

    create unique_index(:chief_decisions, [:semantic_effect_id],
             name: :chief_decisions_semantic_effect_unique_index
           )

    create unique_index(:chief_decisions, [:id, :agent_id, :user_id, :semantic_effect_id],
             name: :chief_decisions_exact_owner_unique_index
           )

    create index(:chief_decisions, [:user_id, :kind, :inserted_at, :id],
             name: :chief_decisions_user_kind_index
           )

    execute(
      """
      ALTER TABLE chief_decisions
      ADD CONSTRAINT chief_decisions_agent_owner_fkey
      FOREIGN KEY (agent_id, user_id) REFERENCES agents(id, user_id) ON DELETE CASCADE
      """,
      "ALTER TABLE chief_decisions DROP CONSTRAINT chief_decisions_agent_owner_fkey"
    )

    execute(
      """
      ALTER TABLE chief_decisions
      ADD CONSTRAINT chief_decisions_effect_owner_fkey
      FOREIGN KEY (semantic_effect_id, agent_id, user_id)
      REFERENCES chief_semantic_effects(id, agent_id, user_id) ON DELETE RESTRICT
      """,
      "ALTER TABLE chief_decisions DROP CONSTRAINT chief_decisions_effect_owner_fkey"
    )

    create constraint(:chief_decisions, :chief_decisions_kind_check,
             check: "kind IN ('approval','choice','clarification','review')"
           )

    create constraint(:chief_decisions, :chief_decisions_identity_check,
             check: """
             octet_length(user_id) BETWEEN 1 AND 320 AND user_id !~ '[[:space:][:cntrl:]]' AND
             octet_length(decision_identity) BETWEEN 1 AND 512 AND decision_identity !~ '[[:cntrl:]]'
             """
           )

    create constraint(:chief_decisions, :chief_decisions_digest_check,
             check: "octet_length(decision_key) = 32 AND octet_length(payload_digest) = 32"
           )

    create constraint(:chief_decisions, :chief_decisions_payload_check,
             check: "jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 160000"
           )
  end
end
