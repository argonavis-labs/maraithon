defmodule Maraithon.Repo.Migrations.AllowProvenEffectRetries do
  use Ecto.Migration

  def up do
    old_fragment =
      "(OLD.status = 'claimed' AND NEW.status = 'pending' AND\n" <>
        "          OLD.cancellation_target_claim_token IS NULL) OR\n" <>
        "         (OLD.status = 'cancelling' AND NEW.status IN ('pending', 'cancelled') AND"

    new_fragment =
      "(OLD.status = 'claimed' AND NEW.status = 'pending' AND\n" <>
        "          OLD.cancellation_target_claim_token IS NULL) OR\n" <>
        "         (OLD.status = 'executing' AND NEW.status = 'pending' AND\n" <>
        "          OLD.cancellation_target_claim_token IS NULL AND\n" <>
        "          OLD.coordination_task_assignment_id IS NOT NULL AND EXISTS (\n" <>
        "            SELECT 1\n" <>
        "            FROM public.runtime_task_assignments AS settled_assignment\n" <>
        "            WHERE settled_assignment.id = OLD.coordination_task_assignment_id\n" <>
        "              AND settled_assignment.activation_epoch =\n" <>
        "                    OLD.coordination_activation_epoch\n" <>
        "              AND settled_assignment.claim_token = OLD.claim_token\n" <>
        "              AND settled_assignment.partition_id = OLD.coordination_partition_id\n" <>
        "              AND settled_assignment.partition_epoch =\n" <>
        "                    OLD.coordination_partition_epoch\n" <>
        "              AND settled_assignment.node_incarnation_id =\n" <>
        "                    OLD.coordination_node_incarnation_id\n" <>
        "              AND settled_assignment.supervisor_id = OLD.claim_supervisor_id\n" <>
        "              AND settled_assignment.local_task_id = OLD.claim_task_id\n" <>
        "              AND settled_assignment.state = 'settled'\n" <>
        "              AND settled_assignment.provider_boundary = 'outcome_known'\n" <>
        "              AND settled_assignment.outcome = 'retry_scheduled'\n" <>
        "          )) OR\n" <>
        "         (OLD.status = 'cancelling' AND NEW.status IN ('pending', 'cancelled') AND"

    execute("""
    DO $effect_retry_guard$
    DECLARE
      definition text;
      old_fragment text := #{quote_literal(old_fragment)};
      new_fragment text := #{quote_literal(new_fragment)};
    BEGIN
      SELECT pg_catalog.pg_get_functiondef(
        'public.enforce_effect_execution_protocol()'::regprocedure
      ) INTO STRICT definition;

      IF pg_catalog.strpos(definition, new_fragment) > 0 THEN
        RETURN;
      END IF;

      IF pg_catalog.strpos(definition, old_fragment) = 0 OR
         pg_catalog.strpos(
           pg_catalog.replace(definition, old_fragment, ''), old_fragment
         ) > 0 THEN
        RAISE EXCEPTION 'Effect execution guard does not match the expected definition'
          USING ERRCODE = 'check_violation';
      END IF;

      EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
    END;
    $effect_retry_guard$;
    """)

    execute("""
    ALTER TABLE public.effect_execution_protocol_manifests
      DISABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger
    """)

    execute("""
    UPDATE public.effect_execution_protocol_manifests AS manifest
    SET function_fingerprints = pg_catalog.jsonb_set(
          manifest.function_fingerprints,
          '{enforce_effect_execution_protocol}',
          pg_catalog.to_jsonb(pg_catalog.md5(function_row.prosrc)),
          false
        ),
        updated_at = timezone('UTC', clock_timestamp())
    FROM pg_catalog.pg_proc AS function_row
    WHERE manifest.name = 'effects'
      AND function_row.oid =
            'public.enforce_effect_execution_protocol()'::regprocedure
    """)

    execute("""
    ALTER TABLE public.effect_execution_protocol_manifests
      ENABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger
    """)

    execute("""
    ALTER TABLE public.privacy_protocol_manifests
      DISABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger
    """)

    execute("""
    DO $privacy_manifest_refresh$
    DECLARE
      function_key text;
      function_fingerprint text;
      functions jsonb;
      triggers jsonb;
      catalogs jsonb;
      digest_value bytea;
    BEGIN
      SELECT
        function_row.oid::regprocedure::text,
        pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.jsonb_build_object(
            'definition', pg_catalog.pg_get_functiondef(function_row.oid),
            'owner', owner_row.rolname,
            'acl', function_row.proacl
          )::text, 'UTF8'), 'sha256'), 'hex')
      INTO STRICT function_key, function_fingerprint
      FROM pg_catalog.pg_proc AS function_row
      JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner
      WHERE function_row.oid =
              'public.enforce_effect_execution_protocol()'::regprocedure;

      SELECT
        pg_catalog.jsonb_set(
          manifest.function_fingerprints,
          ARRAY[function_key],
          pg_catalog.to_jsonb(function_fingerprint),
          false
        ),
        manifest.trigger_fingerprints,
        manifest.catalog_fingerprints
      INTO STRICT functions, triggers, catalogs
      FROM public.privacy_protocol_manifests AS manifest
      WHERE manifest.name = 'operational_privacy_140007'
        AND manifest.migration_version = 20260810140007;

      digest_value := public.digest(pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'functions', functions,
          'triggers', triggers,
          'catalogs', catalogs
        )::text, 'UTF8'), 'sha256');

      UPDATE public.privacy_protocol_manifests
      SET function_fingerprints = functions,
          manifest_digest = digest_value,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'operational_privacy_140007'
        AND migration_version = 20260810140007;
    END;
    $privacy_manifest_refresh$;
    """)

    execute("""
    ALTER TABLE public.privacy_protocol_manifests
      ENABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger
    """)

    execute("""
    DO $durable_payload_manifest_refresh$
    DECLARE
      function_key text;
      prior_snapshot jsonb;
      current_snapshot jsonb;
      reviewed_snapshot jsonb;
    BEGIN
      SELECT function_row.oid::regprocedure::text
      INTO STRICT function_key
      FROM pg_catalog.pg_proc AS function_row
      WHERE function_row.oid =
              'public.enforce_effect_execution_protocol()'::regprocedure;

      SELECT manifest.catalog_manifest
      INTO STRICT prior_snapshot
      FROM public.durable_payload_protocol_manifests AS manifest
      WHERE manifest.name = 'durable_payload_140005'
        AND manifest.migration_version = 20260810140005
      FOR UPDATE;

      current_snapshot := public.durable_payload_catalog_manifest_snapshot();

      IF NOT (prior_snapshot -> 'functions' ? function_key) OR
         NOT (current_snapshot -> 'functions' ? function_key) THEN
        RAISE EXCEPTION 'Durable payload manifest does not track the Effect guard'
          USING ERRCODE = 'check_violation';
      END IF;

      reviewed_snapshot := pg_catalog.jsonb_set(
        prior_snapshot,
        ARRAY['functions', function_key],
        current_snapshot -> 'functions' -> function_key,
        false
      );

      IF reviewed_snapshot IS DISTINCT FROM current_snapshot THEN
        RAISE EXCEPTION 'Effect guard repair found unrelated durable payload catalog drift'
          USING ERRCODE = 'check_violation';
      END IF;

      PERFORM set_config(
        'maraithon.durable_payload_manifest_refresh',
        'MIGRATOR_DARK_REFRESH_V1',
        true
      );

      UPDATE public.durable_payload_protocol_manifests
      SET catalog_manifest = current_snapshot,
          manifest_digest = public.digest(
            pg_catalog.convert_to(current_snapshot::text, 'UTF8'), 'sha256'
          ),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'durable_payload_140005'
        AND migration_version = 20260810140005;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Durable payload manifest authority is missing'
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $durable_payload_manifest_refresh$;
    """)

    execute("""
    DO $effect_retry_guard_verify$
    BEGIN
      IF NOT public.privacy_protocol_catalog_ready() THEN
        RAISE EXCEPTION 'Privacy protocol catalog is not ready after Effect guard repair'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT public.durable_payload_catalog_ready() THEN
        RAISE EXCEPTION 'Durable payload catalog is not ready after Effect guard repair'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_proc AS function_row
        JOIN public.effect_execution_protocol_manifests AS manifest
          ON manifest.name = 'effects'
         AND manifest.function_fingerprints ->> function_row.proname =
               pg_catalog.md5(function_row.prosrc)
        WHERE function_row.oid =
                'public.enforce_effect_execution_protocol()'::regprocedure
      ) THEN
        RAISE EXCEPTION 'Effect protocol manifest is not ready after guard repair'
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $effect_retry_guard_verify$;
    """)
  end

  def down do
    raise "proven Effect retry authority cannot be safely narrowed after use"
  end

  defp quote_literal(value), do: "$guard$#{value}$guard$"
end
