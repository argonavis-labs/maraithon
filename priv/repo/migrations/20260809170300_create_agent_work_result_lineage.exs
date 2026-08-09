defmodule Maraithon.Repo.Migrations.CreateAgentWorkResultLineage do
  use Ecto.Migration

  @db_now "timezone('UTC', clock_timestamp())"

  def change do
    create table(:agent_work_results, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :result_key, :binary, null: false
      add :agent_directive_id, :binary_id, null: false
      add :agent_id, :binary_id, null: false
      add :user_id, :string, null: false
      add :agent_run_id, :binary_id, null: false
      add :claim_generation, :binary_id, null: false
      add :claim_token, :binary_id, null: false
      add :status, :string, null: false, default: "provisional"
      add :outcome, :string, null: false
      add :terminal_event, :string, null: false
      add :result, :map, null: false
      add :result_digest, :binary, null: false
      add :provisional_at, :utc_datetime_usec, null: false, default: fragment(@db_now)
      add :committed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, default: fragment(@db_now))
    end

    create unique_index(:agent_work_results, [:result_key],
             name: :agent_work_results_result_key_unique_index
           )

    create unique_index(:agent_work_results, [:agent_directive_id],
             name: :agent_work_results_directive_unique_index
           )

    create unique_index(:agent_work_results, [:id, :agent_id, :user_id],
             name: :agent_work_results_exact_owner_unique_index
           )

    create_if_not_exists unique_index(
                           :agent_work_results,
                           [:id, :agent_directive_id, :agent_id, :user_id],
                           name: :agent_work_results_directive_owner_unique_index
                         )

    create index(:agent_work_results, [:status, :inserted_at, :id],
             where: "status = 'provisional'",
             name: :agent_work_results_provisional_index
           )

    create index(:agent_work_results, [:user_id, :committed_at, :id],
             where: "status = 'committed'",
             name: :agent_work_results_committed_provenance_index
           )

    execute(
      """
      ALTER TABLE agent_work_results
      ADD CONSTRAINT agent_work_results_agent_owner_fkey
      FOREIGN KEY (agent_id, user_id) REFERENCES agents(id, user_id) ON DELETE CASCADE
      """,
      "ALTER TABLE agent_work_results DROP CONSTRAINT agent_work_results_agent_owner_fkey"
    )

    execute(
      """
      ALTER TABLE agent_work_results
      ADD CONSTRAINT agent_work_results_run_owner_fkey
      FOREIGN KEY (agent_run_id, agent_id, user_id)
      REFERENCES agent_runs(id, agent_id, user_id) ON DELETE RESTRICT
      """,
      "ALTER TABLE agent_work_results DROP CONSTRAINT agent_work_results_run_owner_fkey"
    )

    execute(
      """
      ALTER TABLE agent_work_results
      ADD CONSTRAINT agent_work_results_terminal_claim_fkey
      FOREIGN KEY (agent_directive_id, agent_id, user_id, claim_generation, claim_token)
      REFERENCES agent_directives(id, agent_id, user_id, terminal_by_generation, terminal_claim_token)
      ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
      """,
      "ALTER TABLE agent_work_results DROP CONSTRAINT agent_work_results_terminal_claim_fkey"
    )

    create constraint(:agent_work_results, :agent_work_results_state_check,
             check: """
             (status = 'provisional' AND committed_at IS NULL)
             OR
             (status = 'committed' AND committed_at IS NOT NULL AND committed_at >= provisional_at)
             """
           )

    create constraint(:agent_work_results, :agent_work_results_outcome_check,
             check: "outcome IN ('completed','failed','dead_letter','cancelled')"
           )

    create constraint(:agent_work_results, :agent_work_results_identity_check,
             check: """
             octet_length(user_id) BETWEEN 1 AND 320 AND user_id !~ '[[:space:][:cntrl:]]' AND
             octet_length(terminal_event) BETWEEN 1 AND 80 AND terminal_event !~ '[^a-z0-9_]'
             """
           )

    create constraint(:agent_work_results, :agent_work_results_digest_check,
             check: "octet_length(result_key) = 32 AND octet_length(result_digest) = 32"
           )

    create constraint(:agent_work_results, :agent_work_results_result_check,
             check: "jsonb_typeof(result) = 'object' AND octet_length(result::text) <= 160000"
           )

    create table(:agent_work_result_acquisitions, primary_key: false) do
      add :agent_work_result_id, :binary_id, primary_key: true
      add :acquisition_run_id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :agent_id, :binary_id, null: false
      add :agent_directive_id, :binary_id, null: false

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:agent_work_result_acquisitions, [:acquisition_run_id],
             name: :agent_work_result_acquisitions_run_unique_index
           )

    create index(:agent_work_result_acquisitions, [:agent_work_result_id, :acquisition_run_id],
             name: :agent_work_result_acquisitions_result_index
           )

    execute(
      """
      ALTER TABLE agent_work_result_acquisitions
      ADD CONSTRAINT agent_work_result_acquisitions_result_owner_fkey
      FOREIGN KEY (agent_work_result_id, agent_directive_id, agent_id, user_id)
      REFERENCES agent_work_results(id, agent_directive_id, agent_id, user_id)
      ON DELETE CASCADE
      """,
      "ALTER TABLE agent_work_result_acquisitions DROP CONSTRAINT agent_work_result_acquisitions_result_owner_fkey"
    )

    execute(
      """
      ALTER TABLE agent_work_result_acquisitions
      ADD CONSTRAINT agent_work_result_acquisitions_acquisition_owner_fkey
      FOREIGN KEY (acquisition_run_id, agent_directive_id, agent_id, user_id)
      REFERENCES chief_acquisition_runs(id, agent_directive_id, agent_id, user_id)
      ON DELETE RESTRICT
      """,
      "ALTER TABLE agent_work_result_acquisitions DROP CONSTRAINT agent_work_result_acquisitions_acquisition_owner_fkey"
    )

    create table(:source_cursor_advancements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :advance_key, :binary, null: false
      add :agent_work_result_id, :binary_id, null: false
      add :acquisition_run_id, :binary_id, null: false
      add :source_cursor_id, :binary_id, null: false
      add :user_id, :string, null: false
      add :agent_id, :binary_id, null: false
      add :connected_account_id, :bigint, null: false
      add :provider, :string, null: false
      add :provider_account_key, :string, null: false
      add :cursor_kind, :string, null: false
      add :expected_value, :text
      add :advanced_value, :text, null: false
      add :advance_digest, :binary, null: false
      add :advanced_at, :utc_datetime_usec, null: false, default: fragment(@db_now)

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:source_cursor_advancements, [:advance_key],
             name: :source_cursor_advancements_advance_key_unique_index
           )

    create unique_index(:source_cursor_advancements, [:acquisition_run_id, :source_cursor_id],
             name: :source_cursor_advancements_acquisition_cursor_unique_index
           )

    create unique_index(:source_cursor_advancements, [:agent_work_result_id, :source_cursor_id],
             name: :source_cursor_advancements_result_cursor_unique_index
           )

    create index(:source_cursor_advancements, [:source_cursor_id, :advanced_at, :id],
             name: :source_cursor_advancements_cursor_provenance_index
           )

    create index(:source_cursor_advancements, [:user_id, :provider, :cursor_kind, :advanced_at],
             name: :source_cursor_advancements_user_provenance_index
           )

    execute(
      """
      ALTER TABLE source_cursor_advancements
      ADD CONSTRAINT source_cursor_advancements_result_owner_fkey
      FOREIGN KEY (agent_work_result_id, agent_id, user_id)
      REFERENCES agent_work_results(id, agent_id, user_id) ON DELETE CASCADE
      """,
      "ALTER TABLE source_cursor_advancements DROP CONSTRAINT source_cursor_advancements_result_owner_fkey"
    )

    execute(
      """
      ALTER TABLE source_cursor_advancements
      ADD CONSTRAINT source_cursor_advancements_acquisition_owner_fkey
      FOREIGN KEY (
        acquisition_run_id, agent_id, user_id, connected_account_id, provider,
        provider_account_key
      )
      REFERENCES chief_acquisition_runs(
        id, agent_id, user_id, connected_account_id, provider, provider_account_key
      )
      ON DELETE RESTRICT
      """,
      "ALTER TABLE source_cursor_advancements DROP CONSTRAINT source_cursor_advancements_acquisition_owner_fkey"
    )

    execute(
      """
      ALTER TABLE source_cursor_advancements
      ADD CONSTRAINT source_cursor_advancements_cursor_owner_fkey
      FOREIGN KEY (source_cursor_id, connected_account_id, user_id, provider, cursor_kind)
      REFERENCES source_cursors(id, connected_account_id, user_id, provider, kind)
      ON DELETE RESTRICT
      """,
      "ALTER TABLE source_cursor_advancements DROP CONSTRAINT source_cursor_advancements_cursor_owner_fkey"
    )

    create constraint(:source_cursor_advancements, :source_cursor_advancements_value_check,
             check: """
             (expected_value IS NULL OR (octet_length(expected_value) BETWEEN 1 AND 4096 AND expected_value !~ '[[:cntrl:]]')) AND
             octet_length(advanced_value) BETWEEN 1 AND 4096 AND advanced_value !~ '[[:cntrl:]]'
             """
           )

    create constraint(:source_cursor_advancements, :source_cursor_advancements_identity_check,
             check: """
             octet_length(user_id) BETWEEN 1 AND 320 AND user_id !~ '[[:space:][:cntrl:]]' AND
             octet_length(provider) BETWEEN 1 AND 80 AND provider !~ '[[:space:][:cntrl:]]' AND
             octet_length(provider_account_key) BETWEEN 1 AND 255 AND provider_account_key !~ '[[:cntrl:]]' AND
             octet_length(cursor_kind) BETWEEN 1 AND 80 AND cursor_kind !~ '[[:cntrl:]]'
             """
           )

    create constraint(:source_cursor_advancements, :source_cursor_advancements_digest_check,
             check: "octet_length(advance_key) = 32 AND octet_length(advance_digest) = 32"
           )

    create table(:chief_projection_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :receipt_key, :binary, null: false
      add :agent_work_result_id, :binary_id, null: false
      add :semantic_effect_id, :binary_id, null: false
      add :user_id, :string, null: false
      add :agent_id, :binary_id, null: false
      add :projection_kind, :string, null: false
      add :projection_key, :string, null: false
      add :todo_id, :binary_id
      add :decision_id, :binary_id
      add :attrs_digest, :binary, null: false
      add :projected_at, :utc_datetime_usec, null: false, default: fragment(@db_now)

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:chief_projection_receipts, [:receipt_key],
             name: :chief_projection_receipts_receipt_key_unique_index
           )

    create unique_index(
             :chief_projection_receipts,
             [:semantic_effect_id, :projection_kind, :projection_key],
             name: :chief_projection_receipts_effect_projection_unique_index
           )

    create index(:chief_projection_receipts, [:agent_work_result_id, :semantic_effect_id],
             name: :chief_projection_receipts_result_index
           )

    create index(:chief_projection_receipts, [:todo_id],
             where: "todo_id IS NOT NULL",
             name: :chief_projection_receipts_todo_index
           )

    create index(:chief_projection_receipts, [:decision_id],
             where: "decision_id IS NOT NULL",
             name: :chief_projection_receipts_decision_index
           )

    execute(
      """
      ALTER TABLE chief_projection_receipts
      ADD CONSTRAINT chief_projection_receipts_result_owner_fkey
      FOREIGN KEY (agent_work_result_id, agent_id, user_id)
      REFERENCES agent_work_results(id, agent_id, user_id) ON DELETE CASCADE
      """,
      "ALTER TABLE chief_projection_receipts DROP CONSTRAINT chief_projection_receipts_result_owner_fkey"
    )

    execute(
      """
      ALTER TABLE chief_projection_receipts
      ADD CONSTRAINT chief_projection_receipts_effect_owner_fkey
      FOREIGN KEY (semantic_effect_id, agent_id, user_id)
      REFERENCES chief_semantic_effects(id, agent_id, user_id) ON DELETE RESTRICT
      """,
      "ALTER TABLE chief_projection_receipts DROP CONSTRAINT chief_projection_receipts_effect_owner_fkey"
    )

    execute(
      """
      ALTER TABLE chief_projection_receipts
      ADD CONSTRAINT chief_projection_receipts_todo_owner_fkey
      FOREIGN KEY (todo_id, user_id) REFERENCES todos(id, user_id) ON DELETE RESTRICT
      """,
      "ALTER TABLE chief_projection_receipts DROP CONSTRAINT chief_projection_receipts_todo_owner_fkey"
    )

    execute(
      """
      ALTER TABLE chief_projection_receipts
      ADD CONSTRAINT chief_projection_receipts_decision_owner_fkey
      FOREIGN KEY (decision_id, agent_id, user_id, semantic_effect_id)
      REFERENCES chief_decisions(id, agent_id, user_id, semantic_effect_id) ON DELETE RESTRICT
      """,
      "ALTER TABLE chief_projection_receipts DROP CONSTRAINT chief_projection_receipts_decision_owner_fkey"
    )

    create constraint(:chief_projection_receipts, :chief_projection_receipts_target_check,
             check: """
             (projection_kind = 'todo' AND todo_id IS NOT NULL AND decision_id IS NULL)
             OR
             (projection_kind = 'decision' AND decision_id IS NOT NULL AND todo_id IS NULL)
             """
           )

    create constraint(:chief_projection_receipts, :chief_projection_receipts_identity_check,
             check: """
             octet_length(user_id) BETWEEN 1 AND 320 AND user_id !~ '[[:space:][:cntrl:]]' AND
             octet_length(projection_key) BETWEEN 1 AND 512 AND projection_key !~ '[[:cntrl:]]'
             """
           )

    create constraint(:chief_projection_receipts, :chief_projection_receipts_digest_check,
             check: "octet_length(receipt_key) = 32 AND octet_length(attrs_digest) = 32"
           )
  end
end
