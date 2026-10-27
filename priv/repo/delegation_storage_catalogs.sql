-- Frozen registration for migration 20260915124134. No application registry is
-- read here: a later code release cannot silently broaden this migration.
DO $catalogs$
DECLARE
  prior record;
  stored_functions jsonb; stored_triggers jsonb; stored_catalogs jsonb;
  live_functions jsonb; live_triggers jsonb; live_catalogs jsonb;
  payload jsonb; reviewed jsonb; item record; section text; table_name text;
  tables constant text[] := ARRAY['assistant_identities','delegation_preferences',
    'delegations','delegation_grants','delegation_events','delegation_turns'];
  changed_functions constant text[] := ARRAY[
    'guard_delegation_record()', 'guard_durable_payload_retired_key_write()',
    'durable_payload_operator_row_mutation_authorized(regclass,text,jsonb,jsonb)',
    'lock_durable_runtime_activation_sources()', 'lock_durable_payload_binding_sources()',
    'lock_durable_payload_contraction_sources()', 'durable_payload_old_key_live_count(text,text)',
    'durable_payload_key_registry_definition(text)', 'durable_payload_old_key_source_digest(text,text)',
    'durable_payload_row_identity(text,text)', 'durable_payload_digest_part(text,jsonb,text)',
    'durable_payload_proof_failures()', 'durable_payload_source_acl_ready()',
    'durable_payload_catalog_manifest_snapshot()'];
BEGIN
  SELECT * INTO STRICT prior FROM delegation_prior_catalogs;
  stored_functions := prior.functions || jsonb_build_object('guard_delegation_record()', NULL);
  stored_triggers := prior.triggers;
  stored_catalogs := prior.catalogs;
  FOREACH table_name IN ARRAY tables LOOP
    stored_catalogs := stored_catalogs || jsonb_build_object(table_name, NULL);
    stored_triggers := stored_triggers || jsonb_build_object(
      'public.' || table_name || '.guard_' || table_name, NULL,
      'public.' || table_name || '.enforce_' || table_name || '_privacy_erasure_write_fence', NULL);
  END LOOP;
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


  IF (live_functions - ARRAY['privacy_protocol_catalog_ready()', 'guard_delegation_record()'])
       IS DISTINCT FROM (prior.functions - 'privacy_protocol_catalog_ready()') OR
     EXISTS (SELECT 1 FROM jsonb_each(prior.triggers) p WHERE live_triggers->p.key IS DISTINCT FROM p.value) OR
     EXISTS (SELECT 1 FROM jsonb_each(prior.catalogs) p
       WHERE p.key <> 'durable_payload_binding_operations' AND live_catalogs->p.key IS DISTINCT FROM p.value) THEN
    RAISE EXCEPTION 'Delegation registration found unrelated privacy catalog drift';
  END IF;
  ALTER TABLE public.privacy_protocol_manifests DISABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger;
  UPDATE public.privacy_protocol_manifests SET
    function_fingerprints = live_functions, trigger_fingerprints = live_triggers,
    catalog_fingerprints = live_catalogs,
    manifest_digest = public.digest(convert_to(jsonb_build_object(
      'functions', live_functions, 'triggers', live_triggers, 'catalogs', live_catalogs)::text, 'UTF8'), 'sha256'),
    updated_at = timezone('UTC', clock_timestamp())
    WHERE name = 'operational_privacy_140007' AND migration_version = 20260810140007;
  ALTER TABLE public.privacy_protocol_manifests ENABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger;

  payload := public.durable_payload_catalog_manifest_snapshot();
  reviewed := prior.payload;
  FOREACH section IN ARRAY ARRAY['functions','catalogs','constraints','indexes','triggers'] LOOP
    FOR item IN SELECT * FROM jsonb_each(payload->section) LOOP
      IF (section = 'functions' AND item.key = ANY(changed_functions)) OR
         (section = 'catalogs' AND item.key = 'durable_payload_binding_operations') OR
         (section = 'constraints' AND item.key = 'durable_payload_binding_operations.durable_payload_binding_operations_shape') OR
         (section <> 'functions' AND split_part(item.key, '.', 1) = ANY(tables)) THEN
        reviewed := jsonb_set(reviewed, ARRAY[section, item.key], item.value, true);
      END IF;
    END LOOP;
  END LOOP;
  IF reviewed IS DISTINCT FROM payload THEN
    RAISE EXCEPTION 'Delegation registration found unrelated durable catalog drift';
  END IF;
  PERFORM set_config('maraithon.durable_payload_manifest_refresh', 'MIGRATOR_DARK_REFRESH_V1', true);
  UPDATE public.durable_payload_protocol_manifests SET
    catalog_manifest = reviewed,
    manifest_digest = public.digest(convert_to(reviewed::text, 'UTF8'), 'sha256'),
    updated_at = timezone('UTC', clock_timestamp())
  WHERE name = 'durable_payload_140005' AND migration_version = 20260810140005;
  IF NOT public.privacy_protocol_catalog_ready() OR NOT public.durable_payload_catalog_ready() OR
     public.runtime_coordination_catalog_ready_count() <> 120 THEN
    RAISE EXCEPTION 'Delegation registration did not preserve protocol readiness';
  END IF;
END $catalogs$;
