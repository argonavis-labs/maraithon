defmodule Maraithon.Repo.Migrations.CreateChiefAcquisitionLineage do
  use Ecto.Migration

  @db_now "timezone('UTC', clock_timestamp())"

  def change do
    create table(:runtime_ingress_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :receipt_key, :binary, null: false
      add :user_id, :string, null: false
      add :agent_id, :binary_id, null: false
      add :connected_account_id, :bigint, null: false
      add :provider, :string, null: false
      add :provider_account_key, :string, null: false
      add :ingress_kind, :string, null: false
      add :provider_event_key, :string, null: false
      add :payload, :map, null: false
      add :request_fingerprint, :binary, null: false
      add :provider_occurred_at, :utc_datetime_usec
      add :received_at, :utc_datetime_usec, null: false, default: fragment(@db_now)

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:runtime_ingress_receipts, [:receipt_key],
             name: :runtime_ingress_receipts_receipt_key_unique_index
           )

    create unique_index(
             :runtime_ingress_receipts,
             [
               :user_id,
               :agent_id,
               :connected_account_id,
               :provider,
               :provider_account_key,
               :ingress_kind,
               :provider_event_key
             ],
             name: :runtime_ingress_receipts_provider_identity_unique_index
           )

    create unique_index(
             :runtime_ingress_receipts,
             [
               :id,
               :agent_id,
               :user_id,
               :connected_account_id,
               :provider,
               :provider_account_key
             ],
             name: :runtime_ingress_receipts_exact_owner_unique_index
           )

    create index(:runtime_ingress_receipts, [:user_id, :received_at, :id],
             name: :runtime_ingress_receipts_user_received_index
           )

    create index(:runtime_ingress_receipts, [:agent_id, :received_at, :id],
             name: :runtime_ingress_receipts_agent_received_index
           )

    execute(
      """
      ALTER TABLE runtime_ingress_receipts
      ADD CONSTRAINT runtime_ingress_receipts_agent_owner_fkey
      FOREIGN KEY (agent_id, user_id) REFERENCES agents(id, user_id) ON DELETE CASCADE
      """,
      "ALTER TABLE runtime_ingress_receipts DROP CONSTRAINT runtime_ingress_receipts_agent_owner_fkey"
    )

    execute(
      """
      ALTER TABLE runtime_ingress_receipts
      ADD CONSTRAINT runtime_ingress_receipts_account_owner_fkey
      FOREIGN KEY (connected_account_id, user_id, provider)
      REFERENCES connected_accounts(id, user_id, provider) ON DELETE CASCADE
      """,
      "ALTER TABLE runtime_ingress_receipts DROP CONSTRAINT runtime_ingress_receipts_account_owner_fkey"
    )

    create constraint(:runtime_ingress_receipts, :runtime_ingress_receipts_kind_check,
             check: "ingress_kind IN ('webhook','push','poll','scheduled','manual','replay')"
           )

    create constraint(:runtime_ingress_receipts, :runtime_ingress_receipts_identity_check,
             check: """
             octet_length(user_id) BETWEEN 1 AND 320 AND user_id !~ '[[:space:][:cntrl:]]' AND
             octet_length(provider) BETWEEN 1 AND 80 AND provider !~ '[[:space:][:cntrl:]]' AND
             octet_length(provider_account_key) BETWEEN 1 AND 255 AND provider_account_key !~ '[[:cntrl:]]' AND
             octet_length(provider_event_key) BETWEEN 1 AND 512 AND provider_event_key !~ '[[:cntrl:]]'
             """
           )

    create constraint(:runtime_ingress_receipts, :runtime_ingress_receipts_digest_check,
             check: "octet_length(receipt_key) = 32 AND octet_length(request_fingerprint) = 32"
           )

    create constraint(:runtime_ingress_receipts, :runtime_ingress_receipts_payload_check,
             check: "jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 160000"
           )

    create table(:chief_acquisition_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :acquisition_key, :binary, null: false
      add :user_id, :string, null: false
      add :agent_id, :binary_id, null: false
      add :agent_directive_id, :binary_id, null: false
      add :runtime_ingress_receipt_id, :binary_id, null: false
      add :connected_account_id, :bigint, null: false
      add :source_cursor_id, :binary_id
      add :cursor_kind, :string
      add :provider, :string, null: false
      add :provider_account_key, :string, null: false
      add :source, :string, null: false
      add :scope_key, :string, null: false
      add :request_key, :string, null: false
      add :request_fingerprint, :binary, null: false
      add :contract_version, :integer, null: false, default: 1
      add :status, :string, null: false, default: "fetching"
      add :start_cursor, :text
      add :proposed_cursor, :text
      add :continuation, :map
      add :pagination_exhausted, :boolean, null: false, default: false
      add :page_count, :integer, null: false, default: 0
      add :item_count, :integer, null: false, default: 0
      add :manifest_digest, :binary
      add :failure_code, :string
      add :started_at, :utc_datetime_usec, null: false, default: fragment(@db_now)
      add :sealed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, default: fragment(@db_now))
    end

    create unique_index(:chief_acquisition_runs, [:acquisition_key],
             name: :chief_acquisition_runs_acquisition_key_unique_index
           )

    create unique_index(:chief_acquisition_runs, [:agent_directive_id, :request_key],
             name: :chief_acquisition_runs_directive_request_unique_index
           )

    create unique_index(
             :chief_acquisition_runs,
             [
               :id,
               :agent_id,
               :user_id,
               :connected_account_id,
               :provider,
               :provider_account_key
             ],
             name: :chief_acquisition_runs_exact_owner_unique_index
           )

    create unique_index(
             :chief_acquisition_runs,
             [:id, :agent_id, :user_id],
             name: :chief_acquisition_runs_agent_owner_unique_index
           )

    create_if_not_exists unique_index(
                           :chief_acquisition_runs,
                           [:id, :agent_directive_id, :agent_id, :user_id],
                           name: :chief_acquisition_runs_directive_owner_unique_index
                         )

    create unique_index(
             :chief_acquisition_runs,
             [:id, :user_id, :connected_account_id, :provider, :provider_account_key],
             name: :chief_acquisition_runs_source_owner_unique_index
           )

    create index(:chief_acquisition_runs, [:agent_directive_id, :status, :started_at])

    create index(:chief_acquisition_runs, [:status, :updated_at, :id],
             where: "status = 'incomplete'",
             name: :chief_acquisition_runs_incomplete_index
           )

    create index(:chief_acquisition_runs, [:user_id, :source, :scope_key, :started_at],
             name: :chief_acquisition_runs_provenance_index
           )

    execute(
      """
      ALTER TABLE chief_acquisition_runs
      ADD CONSTRAINT chief_acquisition_runs_agent_owner_fkey
      FOREIGN KEY (agent_id, user_id) REFERENCES agents(id, user_id) ON DELETE CASCADE
      """,
      "ALTER TABLE chief_acquisition_runs DROP CONSTRAINT chief_acquisition_runs_agent_owner_fkey"
    )

    execute(
      """
      ALTER TABLE chief_acquisition_runs
      ADD CONSTRAINT chief_acquisition_runs_directive_owner_fkey
      FOREIGN KEY (agent_directive_id, agent_id, user_id)
      REFERENCES agent_directives(id, agent_id, user_id) ON DELETE CASCADE
      """,
      "ALTER TABLE chief_acquisition_runs DROP CONSTRAINT chief_acquisition_runs_directive_owner_fkey"
    )

    execute(
      """
      ALTER TABLE chief_acquisition_runs
      ADD CONSTRAINT chief_acquisition_runs_ingress_owner_fkey
      FOREIGN KEY (
        runtime_ingress_receipt_id, agent_id, user_id, connected_account_id, provider,
        provider_account_key
      )
      REFERENCES runtime_ingress_receipts(
        id, agent_id, user_id, connected_account_id, provider, provider_account_key
      )
      ON DELETE CASCADE
      """,
      "ALTER TABLE chief_acquisition_runs DROP CONSTRAINT chief_acquisition_runs_ingress_owner_fkey"
    )

    execute(
      """
      ALTER TABLE chief_acquisition_runs
      ADD CONSTRAINT chief_acquisition_runs_cursor_owner_fkey
      FOREIGN KEY (source_cursor_id, connected_account_id, user_id, provider, cursor_kind)
      REFERENCES source_cursors(id, connected_account_id, user_id, provider, kind)
      ON DELETE RESTRICT
      """,
      "ALTER TABLE chief_acquisition_runs DROP CONSTRAINT chief_acquisition_runs_cursor_owner_fkey"
    )

    create constraint(:chief_acquisition_runs, :chief_acquisition_runs_identity_check,
             check: """
             octet_length(user_id) BETWEEN 1 AND 320 AND user_id !~ '[[:space:][:cntrl:]]' AND
             octet_length(provider) BETWEEN 1 AND 80 AND provider !~ '[[:space:][:cntrl:]]' AND
             octet_length(provider_account_key) BETWEEN 1 AND 255 AND provider_account_key !~ '[[:cntrl:]]' AND
             octet_length(source) BETWEEN 1 AND 80 AND source !~ '[[:space:][:cntrl:]]' AND
             octet_length(scope_key) BETWEEN 1 AND 255 AND scope_key !~ '[[:cntrl:]]' AND
             octet_length(request_key) BETWEEN 1 AND 255 AND request_key !~ '[[:cntrl:]]' AND
             (cursor_kind IS NULL OR (octet_length(cursor_kind) BETWEEN 1 AND 80 AND cursor_kind !~ '[[:cntrl:]]')) AND
             (start_cursor IS NULL OR (octet_length(start_cursor) BETWEEN 1 AND 4096 AND start_cursor !~ '[[:cntrl:]]')) AND
             (proposed_cursor IS NULL OR (octet_length(proposed_cursor) BETWEEN 1 AND 4096 AND proposed_cursor !~ '[[:cntrl:]]'))
             """
           )

    create constraint(:chief_acquisition_runs, :chief_acquisition_runs_digest_check,
             check: """
             octet_length(acquisition_key) = 32 AND octet_length(request_fingerprint) = 32 AND
             (manifest_digest IS NULL OR octet_length(manifest_digest) = 32)
             """
           )

    create constraint(:chief_acquisition_runs, :chief_acquisition_runs_counts_check,
             check: "contract_version BETWEEN 1 AND 100 AND page_count >= 0 AND item_count >= 0"
           )

    create constraint(:chief_acquisition_runs, :chief_acquisition_runs_cursor_shape_check,
             check: """
             (source_cursor_id IS NULL AND cursor_kind IS NULL AND start_cursor IS NULL AND proposed_cursor IS NULL)
             OR
             (source_cursor_id IS NOT NULL AND cursor_kind IS NOT NULL)
             """
           )

    create constraint(:chief_acquisition_runs, :chief_acquisition_runs_continuation_check,
             check:
               "continuation IS NULL OR (jsonb_typeof(continuation) = 'object' AND octet_length(continuation::text) <= 16000)"
           )

    create constraint(:chief_acquisition_runs, :chief_acquisition_runs_state_check,
             check: """
             (status = 'fetching' AND proposed_cursor IS NULL AND sealed_at IS NULL AND manifest_digest IS NULL AND failure_code IS NULL)
             OR
             (status = 'incomplete' AND proposed_cursor IS NULL AND pagination_exhausted = FALSE AND continuation IS NOT NULL AND continuation <> '{}'::jsonb AND sealed_at IS NOT NULL AND manifest_digest IS NOT NULL AND failure_code IS NOT NULL)
             OR
             (status = 'complete' AND pagination_exhausted = TRUE AND continuation IS NULL AND sealed_at IS NOT NULL AND manifest_digest IS NOT NULL AND failure_code IS NULL AND (source_cursor_id IS NULL OR proposed_cursor IS NOT NULL))
             OR
             (status IN ('failed','cancelled') AND proposed_cursor IS NULL AND pagination_exhausted = FALSE AND sealed_at IS NOT NULL AND manifest_digest IS NOT NULL AND failure_code IS NOT NULL)
             """
           )

    create table(:chief_acquisition_pages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :acquisition_run_id,
          references(:chief_acquisition_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :ordinal, :integer, null: false
      add :request_cursor, :text
      add :next_cursor, :text
      add :terminal, :boolean, null: false
      add :item_count, :integer, null: false
      add :request_fingerprint, :binary, null: false
      add :response_digest, :binary, null: false
      add :fetched_at, :utc_datetime_usec, null: false, default: fragment(@db_now)

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:chief_acquisition_pages, [:acquisition_run_id, :ordinal])

    create unique_index(:chief_acquisition_pages, [:id, :acquisition_run_id],
             name: :chief_acquisition_pages_id_run_unique_index
           )

    create index(:chief_acquisition_pages, [:acquisition_run_id, :ordinal, :id])

    create constraint(:chief_acquisition_pages, :chief_acquisition_pages_counts_check,
             check: "ordinal >= 0 AND item_count >= 0"
           )

    create constraint(:chief_acquisition_pages, :chief_acquisition_pages_digest_check,
             check:
               "octet_length(request_fingerprint) = 32 AND octet_length(response_digest) = 32"
           )

    create constraint(:chief_acquisition_pages, :chief_acquisition_pages_cursor_check,
             check: """
             (request_cursor IS NULL OR (octet_length(request_cursor) BETWEEN 1 AND 4096 AND request_cursor !~ '[[:cntrl:]]')) AND
             (next_cursor IS NULL OR (octet_length(next_cursor) BETWEEN 1 AND 4096 AND next_cursor !~ '[[:cntrl:]]'))
             """
           )

    create constraint(:chief_acquisition_pages, :chief_acquisition_pages_terminal_check,
             check:
               "(terminal = TRUE AND next_cursor IS NULL) OR (terminal = FALSE AND next_cursor IS NOT NULL)"
           )

    create table(:chief_source_envelopes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :envelope_key, :binary, null: false
      add :user_id, :string, null: false
      add :connected_account_id, :bigint, null: false
      add :provider, :string, null: false
      add :provider_account_key, :string, null: false
      add :source, :string, null: false
      add :scope_key, :string, null: false
      add :source_item_key, :string, null: false
      add :source_revision_key, :string, null: false
      add :raw_payload, :map, null: false
      add :normalized_payload, :map, null: false
      add :raw_digest, :binary, null: false
      add :normalized_digest, :binary, null: false
      add :occurred_at, :utc_datetime_usec
      add :received_at, :utc_datetime_usec, null: false, default: fragment(@db_now)

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:chief_source_envelopes, [:envelope_key],
             name: :chief_source_envelopes_envelope_key_unique_index
           )

    create unique_index(
             :chief_source_envelopes,
             [
               :user_id,
               :connected_account_id,
               :provider,
               :provider_account_key,
               :source,
               :scope_key,
               :source_item_key,
               :source_revision_key
             ],
             name: :chief_source_envelopes_provider_revision_unique_index
           )

    create unique_index(
             :chief_source_envelopes,
             [:id, :user_id, :connected_account_id, :provider, :provider_account_key],
             name: :chief_source_envelopes_exact_owner_unique_index
           )

    create index(
             :chief_source_envelopes,
             [:user_id, :source, :scope_key, :source_item_key, :received_at],
             name: :chief_source_envelopes_provenance_index
           )

    execute(
      """
      ALTER TABLE chief_source_envelopes
      ADD CONSTRAINT chief_source_envelopes_account_owner_fkey
      FOREIGN KEY (connected_account_id, user_id, provider)
      REFERENCES connected_accounts(id, user_id, provider) ON DELETE CASCADE
      """,
      "ALTER TABLE chief_source_envelopes DROP CONSTRAINT chief_source_envelopes_account_owner_fkey"
    )

    create constraint(:chief_source_envelopes, :chief_source_envelopes_identity_check,
             check: """
             octet_length(user_id) BETWEEN 1 AND 320 AND user_id !~ '[[:space:][:cntrl:]]' AND
             octet_length(provider) BETWEEN 1 AND 80 AND provider !~ '[[:space:][:cntrl:]]' AND
             octet_length(provider_account_key) BETWEEN 1 AND 255 AND provider_account_key !~ '[[:cntrl:]]' AND
             octet_length(source) BETWEEN 1 AND 80 AND source !~ '[[:space:][:cntrl:]]' AND
             octet_length(scope_key) BETWEEN 1 AND 255 AND scope_key !~ '[[:cntrl:]]' AND
             octet_length(source_item_key) BETWEEN 1 AND 512 AND source_item_key !~ '[[:cntrl:]]' AND
             octet_length(source_revision_key) BETWEEN 1 AND 255 AND source_revision_key !~ '[[:cntrl:]]'
             """
           )

    create constraint(:chief_source_envelopes, :chief_source_envelopes_digest_check,
             check:
               "octet_length(envelope_key) = 32 AND octet_length(raw_digest) = 32 AND octet_length(normalized_digest) = 32"
           )

    create constraint(:chief_source_envelopes, :chief_source_envelopes_payload_check,
             check: """
             jsonb_typeof(raw_payload) = 'object' AND octet_length(raw_payload::text) <= 320000 AND
             jsonb_typeof(normalized_payload) = 'object' AND octet_length(normalized_payload::text) <= 160000
             """
           )

    create table(:chief_acquisition_envelopes, primary_key: false) do
      add :acquisition_run_id, :binary_id, primary_key: true
      add :source_envelope_id, :binary_id, primary_key: true
      add :acquisition_page_id, :binary_id, null: false
      add :user_id, :string, null: false
      add :connected_account_id, :bigint, null: false
      add :provider, :string, null: false
      add :provider_account_key, :string, null: false
      add :item_ordinal, :integer, null: false
      add :provenance, :map, null: false, default: %{}

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:chief_acquisition_envelopes, [:acquisition_page_id, :item_ordinal],
             name: :chief_acquisition_envelopes_page_ordinal_unique_index
           )

    create index(:chief_acquisition_envelopes, [:source_envelope_id, :acquisition_run_id],
             name: :chief_acquisition_envelopes_provenance_index
           )

    execute(
      """
      ALTER TABLE chief_acquisition_envelopes
      ADD CONSTRAINT chief_acquisition_envelopes_run_owner_fkey
      FOREIGN KEY (
        acquisition_run_id, user_id, connected_account_id, provider, provider_account_key
      )
      REFERENCES chief_acquisition_runs(
        id, user_id, connected_account_id, provider, provider_account_key
      )
      ON DELETE CASCADE
      """,
      "ALTER TABLE chief_acquisition_envelopes DROP CONSTRAINT chief_acquisition_envelopes_run_owner_fkey"
    )

    execute(
      """
      ALTER TABLE chief_acquisition_envelopes
      ADD CONSTRAINT chief_acquisition_envelopes_envelope_owner_fkey
      FOREIGN KEY (
        source_envelope_id, user_id, connected_account_id, provider, provider_account_key
      )
      REFERENCES chief_source_envelopes(
        id, user_id, connected_account_id, provider, provider_account_key
      )
      ON DELETE RESTRICT
      """,
      "ALTER TABLE chief_acquisition_envelopes DROP CONSTRAINT chief_acquisition_envelopes_envelope_owner_fkey"
    )

    execute(
      """
      ALTER TABLE chief_acquisition_envelopes
      ADD CONSTRAINT chief_acquisition_envelopes_page_run_fkey
      FOREIGN KEY (acquisition_page_id, acquisition_run_id)
      REFERENCES chief_acquisition_pages(id, acquisition_run_id) ON DELETE CASCADE
      """,
      "ALTER TABLE chief_acquisition_envelopes DROP CONSTRAINT chief_acquisition_envelopes_page_run_fkey"
    )

    create constraint(:chief_acquisition_envelopes, :chief_acquisition_envelopes_ordinal_check,
             check: "item_ordinal >= 0"
           )

    create constraint(:chief_acquisition_envelopes, :chief_acquisition_envelopes_provenance_check,
             check:
               "jsonb_typeof(provenance) = 'object' AND octet_length(provenance::text) <= 16000"
           )
  end
end
