defmodule Maraithon.Repo.Migrations.AddOwnedTodoWorkflow do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute_compatible("""
    DO $workflow_preflight$
    BEGIN
      IF public.privacy_protocol_catalog_ready() IS NOT TRUE OR
         public.durable_payload_catalog_ready() IS NOT TRUE OR
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Todo workflow migration requires a valid privacy catalog';
      END IF;
    END;
    $workflow_preflight$;
    """)

    alter table(:todos) do
      add :workflow, :map, null: false, default: %{}
    end

    alter table(:telegram_prepared_actions) do
      add :workflow_handoff_state, :string
    end

    create index(:telegram_prepared_actions, [:user_id, :workflow_handoff_state, :executed_at],
             where: "status = 'executed' AND workflow_handoff_state = 'pending'",
             name: :telegram_prepared_actions_pending_handoff_index
           )

    create constraint(:todos, :todos_workflow_object, check: "jsonb_typeof(workflow) = 'object'")

    execute(
      "CREATE INDEX todos_user_workflow_state_index ON public.todos (user_id, (workflow->>'state'))"
    )

    create constraint(:todos, :todos_workflow_state,
             check:
               "workflow = '{}'::jsonb OR COALESCE(workflow->>'state' IN ('you_own', 'working', 'waiting', 'they_own', 'cancelled', 'done'), false)"
           )

    flush()

    execute_compatible("""
    DO $handoff_payload_catalog$
    DECLARE
      prior_snapshot jsonb;
      current_snapshot jsonb;
      reviewed_snapshot jsonb;
      index_key text := 'telegram_prepared_actions.telegram_prepared_actions_pending_handoff_index';
    BEGIN
      SELECT catalog_manifest INTO STRICT prior_snapshot
      FROM public.durable_payload_protocol_manifests
      WHERE name = 'durable_payload_140005' AND migration_version = 20260810140005
      FOR UPDATE;
      current_snapshot := public.durable_payload_catalog_manifest_snapshot();
      IF NOT (prior_snapshot->'catalogs' ? 'telegram_prepared_actions') OR
         NOT (current_snapshot->'indexes' ? index_key) OR
         (prior_snapshot->'indexes' ? index_key) THEN
        RAISE EXCEPTION 'Unexpected prepared-action handoff catalog baseline';
      END IF;
      reviewed_snapshot := pg_catalog.jsonb_set(prior_snapshot,
        '{catalogs,telegram_prepared_actions}',
        current_snapshot #> '{catalogs,telegram_prepared_actions}', false);
      reviewed_snapshot := pg_catalog.jsonb_set(reviewed_snapshot,
        ARRAY['indexes', index_key], current_snapshot->'indexes'->index_key, true);
      IF reviewed_snapshot IS DISTINCT FROM current_snapshot THEN
        RAISE EXCEPTION 'Todo handoff migration found unrelated durable catalog drift';
      END IF;
      PERFORM set_config('maraithon.durable_payload_manifest_refresh', 'MIGRATOR_DARK_REFRESH_V1', true);
      UPDATE public.durable_payload_protocol_manifests
      SET catalog_manifest = reviewed_snapshot,
          manifest_digest = public.digest(pg_catalog.convert_to(reviewed_snapshot::text, 'UTF8'), 'sha256'),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'durable_payload_140005' AND migration_version = 20260810140005;
      IF public.durable_payload_catalog_ready() IS NOT TRUE THEN
        RAISE EXCEPTION 'Todo handoff payload catalog readiness was not restored';
      END IF;
    END;
    $handoff_payload_catalog$;
    """)

    # Verify every unrelated fingerprint before refreshing the two changed
    # tables. The existing privacy manifest trigger is restored in this transaction.
    execute_compatible("""
    DO $todo_privacy_manifest_refresh$
    DECLARE
      mutation_trigger_present boolean;
      stored_functions jsonb;
      stored_triggers jsonb;
      stored_catalogs jsonb;
      live_functions jsonb;
      live_triggers jsonb;
      live_catalogs jsonb;
      digest_value bytea;
    BEGIN
      SELECT function_fingerprints, trigger_fingerprints, catalog_fingerprints
      INTO STRICT stored_functions, stored_triggers, stored_catalogs
      FROM public.privacy_protocol_manifests
      WHERE name = 'operational_privacy_140007'
        AND migration_version = 20260810140007
      FOR UPDATE;

      SELECT pg_catalog.jsonb_object_agg(
        key_name,
        pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.jsonb_build_object(
            'definition', pg_catalog.pg_get_functiondef(function_row.oid),
            'owner', owner_row.rolname,
            'acl', function_row.proacl
          )::text, 'UTF8'), 'sha256'), 'hex')
        ORDER BY key_name
      ) INTO live_functions
      FROM pg_catalog.jsonb_object_keys(stored_functions) AS keys(key_name)
      JOIN pg_catalog.pg_proc AS function_row
        ON function_row.oid = pg_catalog.to_regprocedure(key_name)
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = function_row.pronamespace AND namespace.nspname = 'public'
      JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner;

      SELECT pg_catalog.jsonb_object_agg(
        key_name,
        pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.jsonb_build_object(
            'definition', pg_catalog.pg_get_triggerdef(trigger_row.oid, true),
            'enabled', trigger_row.tgenabled,
            'type', trigger_row.tgtype,
            'function', trigger_row.tgfoid::regprocedure::text
          )::text, 'UTF8'), 'sha256'), 'hex')
        ORDER BY key_name
      ) INTO live_triggers
      FROM pg_catalog.jsonb_object_keys(stored_triggers) AS keys(key_name)
      JOIN pg_catalog.pg_trigger AS trigger_row
        ON 'public.' || trigger_row.tgrelid::regclass::text || '.' || trigger_row.tgname = key_name
       AND NOT trigger_row.tgisinternal
      JOIN pg_catalog.pg_class AS relation ON relation.oid = trigger_row.tgrelid
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = relation.relnamespace AND namespace.nspname = 'public';

      SELECT pg_catalog.jsonb_object_agg(
        key_name,
        CASE key_name
          WHEN 'role_topology' THEN public.runtime_role_topology_fingerprint()
          WHEN 'schema_authority' THEN (
            SELECT pg_catalog.encode(public.digest(pg_catalog.convert_to(
              pg_catalog.jsonb_build_object(
                'owner', owner_row.rolname,
                'acl', namespace.nspacl
              )::text, 'UTF8'), 'sha256'), 'hex')
            FROM pg_catalog.pg_namespace AS namespace
            JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = namespace.nspowner
            WHERE namespace.nspname = 'public'
          )
          ELSE public.runtime_catalog_table_fingerprint(
            pg_catalog.to_regclass('public.' || key_name)
          )
        END
        ORDER BY key_name
      ) INTO live_catalogs
      FROM pg_catalog.jsonb_object_keys(stored_catalogs) AS keys(key_name);

      IF live_functions IS DISTINCT FROM stored_functions OR
         live_triggers IS DISTINCT FROM stored_triggers OR
         (live_catalogs - 'todos' - 'telegram_prepared_actions') IS DISTINCT FROM
           (stored_catalogs - 'todos' - 'telegram_prepared_actions') OR
         NOT (live_catalogs ?& ARRAY['todos', 'telegram_prepared_actions']) THEN
        RAISE EXCEPTION 'Todo privacy manifest refresh found unrelated catalog drift'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_object_keys(live_catalogs) AS catalog_key(key_name)
        JOIN pg_catalog.pg_class AS relation
          ON relation.oid = pg_catalog.to_regclass('public.' || catalog_key.key_name)
        JOIN pg_catalog.pg_attribute AS attribute
          ON attribute.attrelid = relation.oid
         AND attribute.attnum > 0
         AND NOT attribute.attisdropped
        CROSS JOIN LATERAL pg_catalog.aclexplode(attribute.attacl) AS column_acl
        LEFT JOIN pg_catalog.pg_roles AS grantee ON grantee.oid = column_acl.grantee
        WHERE COALESCE(grantee.rolname, 'PUBLIC') NOT IN (
          'maraithon_object_owner', 'maraithon_migrator', 'maraithon_runtime',
          'maraithon_payload_verifier', 'maraithon_incident_operator',
          'maraithon_activation_operator'
        )
      ) THEN
        RAISE EXCEPTION 'Todo privacy manifest refresh found an unknown column ACL grantee'
          USING ERRCODE = 'check_violation';
      END IF;

      digest_value := public.digest(pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'functions', stored_functions,
          'triggers', stored_triggers,
          'catalogs', live_catalogs
        )::text, 'UTF8'), 'sha256');

      SELECT EXISTS (
        SELECT 1 FROM pg_catalog.pg_trigger
        WHERE tgrelid = 'public.privacy_protocol_manifests'::regclass
          AND tgname = 'reject_privacy_protocol_manifest_mutation_trigger'
          AND NOT tgisinternal
      ) INTO mutation_trigger_present;

      IF mutation_trigger_present THEN
        ALTER TABLE public.privacy_protocol_manifests
          DISABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger;
      END IF;

      UPDATE public.privacy_protocol_manifests
      SET catalog_fingerprints = live_catalogs,
          manifest_digest = digest_value,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'operational_privacy_140007'
        AND migration_version = 20260810140007;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Todo privacy manifest authority is missing'
          USING ERRCODE = 'check_violation';
      END IF;

      IF mutation_trigger_present THEN
        ALTER TABLE public.privacy_protocol_manifests
          ENABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger;
      END IF;

      IF public.privacy_protocol_catalog_ready() IS NOT TRUE OR
         public.durable_payload_catalog_ready() IS NOT TRUE OR
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Todo schema privacy manifest refresh did not restore readiness'
          USING ERRCODE = 'check_violation';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF mutation_trigger_present THEN
        ALTER TABLE public.privacy_protocol_manifests
          ENABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger;
      END IF;
      RAISE;
    END;
    $todo_privacy_manifest_refresh$;
    """)
  end

  def down do
    raise "Todo workflow history is not automatically reversible"
  end

  defp execute_compatible(statement) do
    statement
    |> Maraithon.DatabaseRoleCompatibility.rewrite_migration_sql()
    |> Ecto.Migration.execute()
  end
end
