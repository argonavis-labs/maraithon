defmodule Maraithon.Repo.Migrations.CreateSourceCycleProofs do
  use Ecto.Migration

  @db_now "timezone('UTC', clock_timestamp())"

  def change do
    create table(:source_cycles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cycle_key, :binary, null: false
      add :proof_version, :integer, null: false, default: 1
      add :user_id, :string, null: false
      add :connected_account_id, :bigint, null: false
      add :provider, :string, null: false
      add :role, :string, null: false
      add :cursor_kind, :string, null: false
      add :lower_cursor, :text
      add :upper_cursor, :text, null: false
      add :boundary, :string, null: false
      add :acquisition_job_id, :binary_id, null: false
      add :reason_job_ids, {:array, :uuid}, null: false, default: []
      add :finalizer_job_id, :binary_id
      add :reason_job_count, :integer, null: false
      add :job_manifest_digest, :binary, null: false
      add :source_item_count, :integer, null: false
      add :source_manifest_digest, :binary, null: false
      add :todo_snapshot_count, :integer, null: false
      add :todo_snapshot_manifest_digest, :binary, null: false
      add :captured_at, :utc_datetime_usec, null: false, default: fragment(@db_now)
      add :sealed_at, :utc_datetime_usec, null: false, default: fragment(@db_now)

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:source_cycles, [:cycle_key], name: :source_cycles_cycle_key_unique_index)

    create unique_index(
             :source_cycles,
             [:id, :user_id, :connected_account_id, :provider],
             name: :source_cycles_exact_owner_unique_index
           )

    create unique_index(:source_cycles, [:acquisition_job_id],
             name: :source_cycles_acquisition_job_unique_index
           )

    create unique_index(:source_cycles, [:finalizer_job_id],
             name: :source_cycles_finalizer_job_unique_index
           )

    create index(
             :source_cycles,
             [:user_id, :connected_account_id, :role, :captured_at, :id],
             name: :source_cycles_bounded_audit_index
           )

    execute(
      """
      ALTER TABLE source_cycles
      ADD CONSTRAINT source_cycles_account_owner_fkey
      FOREIGN KEY (connected_account_id, user_id, provider)
      REFERENCES connected_accounts(id, user_id, provider) ON DELETE CASCADE
      """,
      "ALTER TABLE source_cycles DROP CONSTRAINT source_cycles_account_owner_fkey"
    )

    alter table(:source_cycles) do
      modify :acquisition_job_id,
             references(:background_jobs, type: :binary_id, on_delete: :restrict),
             from: :binary_id

      modify :finalizer_job_id,
             references(:background_jobs, type: :binary_id, on_delete: :restrict),
             from: :binary_id
    end

    create constraint(:source_cycles, :source_cycles_shape_check,
             check: """
             proof_version = 1 AND
             role IN ('discovery','closure') AND
             boundary IN ('lower_inclusive_upper_exclusive','lower_exclusive_upper_inclusive','provider_native') AND
             octet_length(user_id) BETWEEN 1 AND 320 AND user_id !~ '[[:space:][:cntrl:]]' AND
             octet_length(provider) BETWEEN 1 AND 80 AND provider !~ '[[:space:][:cntrl:]]' AND
             octet_length(cursor_kind) BETWEEN 1 AND 80 AND cursor_kind !~ '[[:space:][:cntrl:]]' AND
             (lower_cursor IS NULL OR octet_length(lower_cursor) BETWEEN 1 AND 4096) AND
             octet_length(upper_cursor) BETWEEN 1 AND 4096 AND
             reason_job_count >= 0 AND reason_job_count <= 20000 AND
             cardinality(reason_job_ids) = reason_job_count AND
             ((reason_job_count = 0 AND finalizer_job_id IS NULL) OR
              (reason_job_count > 0 AND finalizer_job_id IS NOT NULL)) AND
             source_item_count >= 0 AND source_item_count <= 50000 AND
             todo_snapshot_count >= 0 AND todo_snapshot_count <= 20000 AND
             (role = 'closure' OR todo_snapshot_count = 0) AND
             ((role = 'discovery' AND
               ((source_item_count = 0 AND reason_job_count = 0) OR
                (source_item_count > 0 AND reason_job_count > 0))) OR
              (role = 'closure' AND
               ((todo_snapshot_count = 0 AND reason_job_count = 0) OR
                (todo_snapshot_count > 0 AND reason_job_count > 0)))) AND
             captured_at <= sealed_at
             """
           )

    create constraint(:source_cycles, :source_cycles_digest_check,
             check: """
             octet_length(cycle_key) = 32 AND
             octet_length(job_manifest_digest) = 32 AND
             octet_length(source_manifest_digest) = 32 AND
             octet_length(todo_snapshot_manifest_digest) = 32
             """
           )

    create table(:source_cycle_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cycle_id, :binary_id, null: false
      add :user_id, :string, null: false
      add :connected_account_id, :bigint, null: false
      add :provider, :string, null: false
      add :ordinal, :integer, null: false
      add :source_ref_digest, :binary, null: false
      add :source_identity_digest, :binary, null: false
      add :source_revision_digest, :binary, null: false
      add :provider_occurred_at, :utc_datetime_usec
      add :ingress_sequence, :bigint

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:source_cycle_items, [:cycle_id, :ordinal],
             name: :source_cycle_items_ordinal_unique_index
           )

    create unique_index(:source_cycle_items, [:cycle_id, :source_ref_digest],
             name: :source_cycle_items_ref_unique_index
           )

    create index(:source_cycle_items, [:cycle_id, :ingress_sequence],
             name: :source_cycle_items_ingress_index
           )

    execute(
      """
      ALTER TABLE source_cycle_items
      ADD CONSTRAINT source_cycle_items_cycle_owner_fkey
      FOREIGN KEY (cycle_id, user_id, connected_account_id, provider)
      REFERENCES source_cycles(id, user_id, connected_account_id, provider) ON DELETE CASCADE
      """,
      "ALTER TABLE source_cycle_items DROP CONSTRAINT source_cycle_items_cycle_owner_fkey"
    )

    create constraint(:source_cycle_items, :source_cycle_items_shape_check,
             check: "ordinal >= 0 AND (ingress_sequence IS NULL OR ingress_sequence >= 0)"
           )

    create constraint(:source_cycle_items, :source_cycle_items_digest_check,
             check: """
             octet_length(source_ref_digest) = 32 AND
             octet_length(source_identity_digest) = 32 AND
             octet_length(source_revision_digest) = 32
             """
           )

    create table(:source_decision_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cycle_id, :binary_id, null: false
      add :user_id, :string, null: false
      add :connected_account_id, :bigint, null: false
      add :provider, :string, null: false
      add :source_ref_digest, :binary, null: false
      add :reason_job_id, :binary_id, null: false
      add :action, :string, null: false
      add :todo_id, :binary_id
      add :todo_state_digest, :binary
      add :evaluator, :string, null: false
      add :reason_code, :string, null: false
      add :evidence_digest, :binary
      add :decision_digest, :binary, null: false
      add :decided_at, :utc_datetime_usec, null: false, default: fragment(@db_now)

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:source_decision_receipts, [:cycle_id, :source_ref_digest],
             name: :source_decision_receipts_ref_unique_index
           )

    create index(:source_decision_receipts, [:cycle_id, :reason_job_id],
             name: :source_decision_receipts_job_index
           )

    execute(
      """
      ALTER TABLE source_decision_receipts
      ADD CONSTRAINT source_decision_receipts_cycle_owner_fkey
      FOREIGN KEY (cycle_id, user_id, connected_account_id, provider)
      REFERENCES source_cycles(id, user_id, connected_account_id, provider) ON DELETE CASCADE
      """,
      "ALTER TABLE source_decision_receipts DROP CONSTRAINT source_decision_receipts_cycle_owner_fkey"
    )

    execute(
      """
      ALTER TABLE source_decision_receipts
      ADD CONSTRAINT source_decision_receipts_item_fkey
      FOREIGN KEY (cycle_id, source_ref_digest)
      REFERENCES source_cycle_items(cycle_id, source_ref_digest) ON DELETE CASCADE
      """,
      "ALTER TABLE source_decision_receipts DROP CONSTRAINT source_decision_receipts_item_fkey"
    )

    create constraint(:source_decision_receipts, :source_decision_receipts_shape_check,
             check: """
             action IN ('create','update','skip') AND
             evaluator IN ('model','deterministic','policy') AND
             octet_length(reason_code) BETWEEN 1 AND 80 AND
             reason_code ~ '^[a-z][a-z0-9_]*$' AND
             ((action = 'skip' AND todo_id IS NULL AND todo_state_digest IS NULL) OR
              (action IN ('create','update') AND todo_id IS NOT NULL AND todo_state_digest IS NOT NULL))
             """
           )

    create constraint(:source_decision_receipts, :source_decision_receipts_digest_check,
             check: """
             octet_length(source_ref_digest) = 32 AND
             (todo_state_digest IS NULL OR octet_length(todo_state_digest) = 32) AND
             (evidence_digest IS NULL OR octet_length(evidence_digest) = 32) AND
             octet_length(decision_digest) = 32
             """
           )

    create table(:todo_snapshot_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cycle_id, :binary_id, null: false
      add :user_id, :string, null: false
      add :connected_account_id, :bigint, null: false
      add :provider, :string, null: false
      add :ordinal, :integer, null: false
      add :todo_id, :binary_id, null: false
      add :eligible_status, :string, null: false
      add :todo_state_digest, :binary, null: false
      add :todo_updated_at, :utc_datetime_usec, null: false

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:todo_snapshot_items, [:cycle_id, :ordinal],
             name: :todo_snapshot_items_ordinal_unique_index
           )

    create unique_index(
             :todo_snapshot_items,
             [:cycle_id, :todo_id, :todo_state_digest],
             name: :todo_snapshot_items_state_unique_index
           )

    execute(
      """
      ALTER TABLE todo_snapshot_items
      ADD CONSTRAINT todo_snapshot_items_cycle_owner_fkey
      FOREIGN KEY (cycle_id, user_id, connected_account_id, provider)
      REFERENCES source_cycles(id, user_id, connected_account_id, provider) ON DELETE CASCADE
      """,
      "ALTER TABLE todo_snapshot_items DROP CONSTRAINT todo_snapshot_items_cycle_owner_fkey"
    )

    create constraint(:todo_snapshot_items, :todo_snapshot_items_shape_check,
             check: "ordinal >= 0 AND eligible_status IN ('open','snoozed')"
           )

    create constraint(:todo_snapshot_items, :todo_snapshot_items_digest_check,
             check: "octet_length(todo_state_digest) = 32"
           )

    create table(:todo_closure_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cycle_id, :binary_id, null: false
      add :user_id, :string, null: false
      add :connected_account_id, :bigint, null: false
      add :provider, :string, null: false
      add :todo_id, :binary_id, null: false
      add :reason_job_id, :binary_id, null: false
      add :todo_before_digest, :binary, null: false
      add :todo_after_digest, :binary, null: false
      add :outcome, :string, null: false
      add :evaluator, :string, null: false
      add :reason_code, :string, null: false
      add :evidence_digest, :binary
      add :decision_digest, :binary, null: false
      add :decided_at, :utc_datetime_usec, null: false, default: fragment(@db_now)

      timestamps(
        type: :utc_datetime_usec,
        updated_at: false,
        default: fragment(@db_now)
      )
    end

    create unique_index(:todo_closure_receipts, [:cycle_id, :todo_id],
             name: :todo_closure_receipts_todo_unique_index
           )

    create index(:todo_closure_receipts, [:cycle_id, :reason_job_id],
             name: :todo_closure_receipts_job_index
           )

    execute(
      """
      ALTER TABLE todo_closure_receipts
      ADD CONSTRAINT todo_closure_receipts_cycle_owner_fkey
      FOREIGN KEY (cycle_id, user_id, connected_account_id, provider)
      REFERENCES source_cycles(id, user_id, connected_account_id, provider) ON DELETE CASCADE
      """,
      "ALTER TABLE todo_closure_receipts DROP CONSTRAINT todo_closure_receipts_cycle_owner_fkey"
    )

    execute(
      """
      ALTER TABLE todo_closure_receipts
      ADD CONSTRAINT todo_closure_receipts_snapshot_fkey
      FOREIGN KEY (cycle_id, todo_id, todo_before_digest)
      REFERENCES todo_snapshot_items(cycle_id, todo_id, todo_state_digest) ON DELETE CASCADE
      """,
      "ALTER TABLE todo_closure_receipts DROP CONSTRAINT todo_closure_receipts_snapshot_fkey"
    )

    create constraint(:todo_closure_receipts, :todo_closure_receipts_shape_check,
             check: """
             outcome IN ('completed','still_open','acknowledged','superseded') AND
             evaluator IN ('model','deterministic','policy') AND
             octet_length(reason_code) BETWEEN 1 AND 80 AND
             reason_code ~ '^[a-z][a-z0-9_]*$' AND
             (outcome <> 'completed' OR evidence_digest IS NOT NULL)
             """
           )

    create constraint(:todo_closure_receipts, :todo_closure_receipts_digest_check,
             check: """
             octet_length(todo_before_digest) = 32 AND
             octet_length(todo_after_digest) = 32 AND
             (evidence_digest IS NULL OR octet_length(evidence_digest) = 32) AND
             octet_length(decision_digest) = 32
             """
           )

    execute(
      """
      CREATE FUNCTION public.reject_source_cycle_proof_update()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      BEGIN
        RAISE EXCEPTION 'immutable source-cycle proof row: %', TG_TABLE_NAME
          USING ERRCODE = '23514';
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.reject_source_cycle_proof_update() CASCADE"
    )

    for table <- [
          :source_cycles,
          :source_cycle_items,
          :source_decision_receipts,
          :todo_snapshot_items,
          :todo_closure_receipts
        ] do
      execute(
        """
        CREATE TRIGGER #{table}_immutable_update
        BEFORE UPDATE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION public.reject_source_cycle_proof_update()
        """,
        "DROP TRIGGER IF EXISTS #{table}_immutable_update ON #{table}"
      )
    end

    execute(
      """
      CREATE FUNCTION public.guard_source_cycle_insert()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      DECLARE
        acquisition_type text;
        reason_type text;
        finalizer_type text;
        actual_acquisition_type text;
        actual_acquisition_user_id text;
        actual_finalizer_type text;
        actual_finalizer_user_id text;
        actual_reason_count bigint;
        actual_job_digest bytea;
      BEGIN
        IF NEW.role = 'discovery' THEN
          acquisition_type := 'runtime_partition:source_account_discovery';
          reason_type := 'runtime_partition:source_account_discovery_reason';
          finalizer_type := 'runtime_partition:source_account_discovery_finalize';
        ELSE
          acquisition_type := 'runtime_partition:source_account_closure_acquire';
          reason_type := 'runtime_partition:source_account_closure_reason';
          finalizer_type := 'runtime_partition:source_account_closure_finalize';
        END IF;

        SELECT job.job_type, job.user_id
        INTO actual_acquisition_type, actual_acquisition_user_id
        FROM public.background_jobs job
        WHERE job.id = NEW.acquisition_job_id;

        IF actual_acquisition_type IS DISTINCT FROM acquisition_type OR
           actual_acquisition_user_id IS DISTINCT FROM NEW.user_id THEN
          RAISE EXCEPTION 'source cycle acquisition job owner or type mismatch'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.finalizer_job_id IS NOT NULL THEN
          SELECT job.job_type, job.user_id
          INTO actual_finalizer_type, actual_finalizer_user_id
          FROM public.background_jobs job
          WHERE job.id = NEW.finalizer_job_id;

          IF actual_finalizer_type IS DISTINCT FROM finalizer_type OR
             actual_finalizer_user_id IS DISTINCT FROM NEW.user_id THEN
            RAISE EXCEPTION 'source cycle finalizer job owner or type mismatch'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        SELECT count(*) INTO actual_reason_count
        FROM unnest(NEW.reason_job_ids) AS expected(id)
        JOIN public.background_jobs job ON job.id = expected.id
        WHERE job.user_id = NEW.user_id AND job.job_type = reason_type;

        IF actual_reason_count <> NEW.reason_job_count OR
           (SELECT count(DISTINCT id) FROM unnest(NEW.reason_job_ids) AS ids(id)) <>
             NEW.reason_job_count THEN
          RAISE EXCEPTION 'source cycle reason job manifest mismatch' USING ERRCODE = '23514';
        END IF;

        SELECT public.digest(pg_catalog.convert_to(
          array_to_string(
            ARRAY[NEW.acquisition_job_id::text] ||
            ARRAY(
              SELECT id::text FROM unnest(NEW.reason_job_ids) AS ids(id) ORDER BY id::text
            ) ||
            CASE WHEN NEW.finalizer_job_id IS NULL
              THEN ARRAY[]::text[]
              ELSE ARRAY[NEW.finalizer_job_id::text]
            END,
            '|'
          ),
          'UTF8'
        ), 'sha256') INTO actual_job_digest;

        IF actual_job_digest IS DISTINCT FROM NEW.job_manifest_digest THEN
          RAISE EXCEPTION 'source cycle job digest mismatch' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.guard_source_cycle_insert() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER source_cycles_insert_guard
      BEFORE INSERT ON source_cycles
      FOR EACH ROW EXECUTE FUNCTION public.guard_source_cycle_insert()
      """,
      "DROP TRIGGER IF EXISTS source_cycles_insert_guard ON source_cycles"
    )

    execute(
      """
      CREATE FUNCTION public.validate_source_cycle_manifests()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      DECLARE
        cycle public.source_cycles%ROWTYPE;
        actual_source_count bigint;
        actual_source_digest bytea;
        actual_todo_count bigint;
        actual_todo_digest bytea;
      BEGIN
        IF TG_TABLE_NAME = 'source_cycles' THEN
          cycle := NEW;
        ELSE
          SELECT * INTO cycle FROM public.source_cycles WHERE id = NEW.cycle_id;
        END IF;

        IF cycle.id IS NULL THEN
          RETURN NEW;
        END IF;

        SELECT count(*), public.digest(pg_catalog.convert_to(coalesce(string_agg(
          pg_catalog.encode(item.source_ref_digest, 'hex') || ':' ||
          pg_catalog.encode(item.source_identity_digest, 'hex') || ':' ||
          pg_catalog.encode(item.source_revision_digest, 'hex'),
          '|' ORDER BY item.ordinal
        ), ''), 'UTF8'), 'sha256')
        INTO actual_source_count, actual_source_digest
        FROM public.source_cycle_items item
        WHERE item.cycle_id = cycle.id;

        SELECT count(*), public.digest(pg_catalog.convert_to(coalesce(string_agg(
          snapshot.todo_id::text || ':' ||
          pg_catalog.encode(snapshot.todo_state_digest, 'hex'),
          '|' ORDER BY snapshot.ordinal
        ), ''), 'UTF8'), 'sha256')
        INTO actual_todo_count, actual_todo_digest
        FROM public.todo_snapshot_items snapshot
        WHERE snapshot.cycle_id = cycle.id;

        IF actual_source_count <> cycle.source_item_count OR
           actual_source_digest IS DISTINCT FROM cycle.source_manifest_digest OR
           actual_todo_count <> cycle.todo_snapshot_count OR
           actual_todo_digest IS DISTINCT FROM cycle.todo_snapshot_manifest_digest THEN
          RAISE EXCEPTION 'source cycle declared manifest does not match immutable rows'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.validate_source_cycle_manifests() CASCADE"
    )

    for table <- [:source_cycles, :source_cycle_items, :todo_snapshot_items] do
      execute(
        """
        CREATE CONSTRAINT TRIGGER #{table}_manifest_guard
        AFTER INSERT ON #{table}
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION public.validate_source_cycle_manifests()
        """,
        "DROP TRIGGER IF EXISTS #{table}_manifest_guard ON #{table}"
      )
    end

    execute(
      """
      CREATE FUNCTION public.guard_source_cycle_receipt_insert()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      DECLARE
        cycle public.source_cycles%ROWTYPE;
        expected_role text;
      BEGIN
        SELECT * INTO cycle FROM public.source_cycles WHERE id = NEW.cycle_id;
        expected_role := CASE
          WHEN TG_TABLE_NAME = 'source_decision_receipts' THEN 'discovery'
          ELSE 'closure'
        END;

        IF cycle.id IS NULL OR cycle.role <> expected_role OR
           NOT NEW.reason_job_id = ANY(cycle.reason_job_ids) THEN
          RAISE EXCEPTION 'source cycle receipt is outside its exact fanout manifest'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.guard_source_cycle_receipt_insert() CASCADE"
    )

    for table <- [:source_decision_receipts, :todo_closure_receipts] do
      execute(
        """
        CREATE TRIGGER #{table}_insert_guard
        BEFORE INSERT ON #{table}
        FOR EACH ROW EXECUTE FUNCTION public.guard_source_cycle_receipt_insert()
        """,
        "DROP TRIGGER IF EXISTS #{table}_insert_guard ON #{table}"
      )
    end

    execute(
      """
      DO $source_cycle_acl$
      DECLARE
      relation_name text;
      function_name text;
      BEGIN
      FOREACH relation_name IN ARRAY ARRAY[
        'source_cycles', 'source_cycle_items', 'source_decision_receipts',
        'todo_snapshot_items', 'todo_closure_receipts'
      ] LOOP
        EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier, maraithon_incident_operator, maraithon_activation_operator', relation_name);
        EXECUTE format('GRANT ALL ON TABLE public.%I TO maraithon_migrator', relation_name);
        EXECUTE format('GRANT SELECT, INSERT ON TABLE public.%I TO maraithon_runtime', relation_name);
        EXECUTE format('GRANT SELECT ON TABLE public.%I TO maraithon_payload_verifier', relation_name);
        EXECUTE format('ALTER TABLE public.%I OWNER TO maraithon_object_owner', relation_name);
      END LOOP;

      FOREACH function_name IN ARRAY ARRAY[
        'reject_source_cycle_proof_update()',
        'guard_source_cycle_insert()',
        'validate_source_cycle_manifests()',
        'guard_source_cycle_receipt_insert()'
      ] LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier, maraithon_incident_operator, maraithon_activation_operator', function_name);
        EXECUTE format('GRANT ALL ON FUNCTION public.%s TO maraithon_migrator', function_name);
        EXECUTE format('ALTER FUNCTION public.%s OWNER TO maraithon_object_owner', function_name);
      END LOOP;
      END
      $source_cycle_acl$;
      """,
      "SELECT 1"
    )
  end
end
