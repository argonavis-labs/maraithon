defmodule Maraithon.Repo.Migrations.RefreshTodoPrivacyManifest do
  use Ecto.Migration

  def up do
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
         (live_catalogs - 'todos') IS DISTINCT FROM (stored_catalogs - 'todos') OR
         NOT (live_catalogs ? 'todos') THEN
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

      IF public.privacy_protocol_catalog_ready() IS NOT TRUE THEN
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
    raise "the reviewed privacy manifest refresh is not automatically reversible"
  end

  defp execute_compatible(statement) do
    statement
    |> Maraithon.DatabaseRoleCompatibility.rewrite_migration_sql()
    |> Ecto.Migration.execute()
  end
end
