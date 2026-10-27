defmodule Maraithon.Repo.Migrations.AddSupersededDeadIncarnationProof do
  use Ecto.Migration

  # Adds a database-verified Agent termination proof kind,
  # `superseded_dead_incarnation`, so the runtime can self-heal a partition
  # frozen by a stranded Agent lease whose owning node incarnation is provably
  # gone (lease long-expired AND a different incarnation is serving). This never
  # weakens the offline-key control: the `external_node_destroyed` signature
  # path is unchanged; the new kind carries no signature and is accepted only
  # when the death is provable from coordination state.
  #
  # Follows the in-repo pattern (migration 20260904190000) for changing a
  # fingerprinted coordination object: modify it, then re-fingerprint the
  # runtime coordination manifest (function, the changed table constraint, and
  # that table's catalog fingerprint) and recompute the protocol manifest
  # digest. A final verify block aborts the transaction (leaving production
  # unchanged) unless both boot-readiness conditions hold: catalog ready-count
  # = 120 and a matching protocol manifest digest.

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    ALTER TABLE public.agent_termination_proofs
      DROP CONSTRAINT IF EXISTS agent_termination_proofs_shape,
      ADD CONSTRAINT agent_termination_proofs_shape CHECK (
        proof_kind IN ('local_down', 'external_node_destroyed', 'superseded_dead_incarnation') AND
        octet_length(proved_by) BETWEEN 1 AND 320 AND
        ((activation_epoch IS NULL AND node_incarnation_id IS NULL AND
          partition_id IS NULL AND partition_epoch IS NULL) OR
         (activation_epoch IS NOT NULL AND node_incarnation_id IS NOT NULL AND
          partition_id BETWEEN 0 AND 63 AND partition_epoch > 0)) AND
        ((proof_kind = 'local_down' AND
          octet_length(local_pid) BETWEEN 1 AND 255 AND monitor_started_at IS NOT NULL AND
          octet_length(down_reason) BETWEEN 1 AND 255 AND
          evidence_id IS NULL AND evidence_digest IS NULL AND
          attestation_signature IS NULL) OR
         (proof_kind = 'external_node_destroyed' AND
          activation_epoch IS NOT NULL AND node_incarnation_id IS NOT NULL AND
          local_pid IS NULL AND monitor_started_at IS NULL AND down_reason IS NULL AND
          octet_length(evidence_id) BETWEEN 1 AND 256 AND
          octet_length(evidence_digest) = 32 AND
          octet_length(attestation_signature) = 64) OR
         (proof_kind = 'superseded_dead_incarnation' AND
          activation_epoch IS NOT NULL AND node_incarnation_id IS NOT NULL AND
          local_pid IS NULL AND monitor_started_at IS NULL AND down_reason IS NULL AND
          octet_length(evidence_id) BETWEEN 1 AND 256 AND
          octet_length(evidence_digest) = 32 AND
          attestation_signature IS NULL))
      )
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_agent_termination_proof()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      incident record;
      capability_digest bytea;
      local_capability bytea;
    BEGIN
      IF NOT (
        (NEW.proof_kind = 'local_down' AND current_user = 'maraithon_runtime') OR
        (NEW.proof_kind = 'external_node_destroyed' AND
          current_user = 'maraithon_incident_operator') OR
        (NEW.proof_kind = 'superseded_dead_incarnation' AND
          current_user = 'maraithon_runtime') OR
        (current_user = 'maraithon_migrator' AND EXISTS (
          SELECT 1 FROM public.runtime_coordination_protocols
          WHERE name = 'runtime' AND mode = 'dark'
        ))
      ) THEN
        RAISE EXCEPTION 'Agent termination proof kind is not authorized for current role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Agent termination proof is append-only'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT * INTO STRICT incident
      FROM public.agent_termination_incidents
      WHERE id = NEW.incident_id
      FOR UPDATE;

      IF incident.status <> 'requested' OR
         NEW.activation_epoch IS DISTINCT FROM incident.activation_epoch OR
         NEW.node_incarnation_id IS DISTINCT FROM incident.node_incarnation_id OR
         NEW.partition_id IS DISTINCT FROM incident.partition_id OR
         NEW.partition_epoch IS DISTINCT FROM incident.partition_epoch OR
         NEW.agent_id IS DISTINCT FROM incident.agent_id OR
         NEW.lease_token IS DISTINCT FROM incident.lease_token THEN
        RAISE EXCEPTION 'Agent termination proof identity does not match its incident'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.proof_kind = 'local_down' THEN
        SELECT lease.termination_capability_digest INTO capability_digest
        FROM public.agent_runtime_leases AS lease
        WHERE lease.agent_id = incident.agent_id
          AND lease.owner_token = incident.lease_token
          AND lease.owner_node = incident.owner_node
          AND lease.coordination_activation_epoch IS NOT DISTINCT FROM
                incident.activation_epoch
          AND lease.coordination_node_incarnation_id IS NOT DISTINCT FROM
                incident.node_incarnation_id
          AND lease.coordination_partition_id IS NOT DISTINCT FROM
                incident.partition_id
          AND lease.coordination_partition_epoch IS NOT DISTINCT FROM
                incident.partition_epoch
        FOR SHARE;

        BEGIN
          local_capability := decode(
            COALESCE(
              current_setting('maraithon.agent_termination_capability', true),
              ''
            ),
            'base64'
          );
        EXCEPTION WHEN OTHERS THEN
          RAISE EXCEPTION 'local Agent termination capability is invalid'
            USING ERRCODE = 'check_violation';
        END;

        IF octet_length(local_capability) IS DISTINCT FROM 32 OR
           public.digest(local_capability, 'sha256') IS DISTINCT FROM capability_digest THEN
          RAISE EXCEPTION 'local Agent termination proof requires exact capability authority'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF NEW.proof_kind = 'external_node_destroyed' AND
            current_setting('maraithon.agent_external_termination_attestation', true)
              IS DISTINCT FROM encode(NEW.evidence_digest, 'hex') THEN
        RAISE EXCEPTION 'external Agent termination proof requires signed operator attestation'
          USING ERRCODE = 'check_violation';
      ELSIF NEW.proof_kind = 'superseded_dead_incarnation' THEN
        -- Database-verified death: the owning node incarnation has not renewed
        -- its lease for far longer than any live cpu-unthrottled instance could,
        -- and a different incarnation is currently serving. No signature is
        -- required because the death is provable from coordination state.
        IF NOT EXISTS (
          SELECT 1 FROM public.runtime_node_incarnations AS dead
          WHERE dead.id = incident.node_incarnation_id
            AND dead.lease_expires_at <
                  timezone('UTC', clock_timestamp()) - INTERVAL '10 minutes'
        ) THEN
          RAISE EXCEPTION 'superseded incarnation proof requires a long-expired owner lease'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM public.runtime_node_incarnations AS live
          WHERE live.id <> incident.node_incarnation_id
            AND live.state = 'ready'
            AND live.lease_expires_at > timezone('UTC', clock_timestamp())
        ) THEN
          RAISE EXCEPTION 'superseded incarnation proof requires a live successor incarnation'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Agent termination incident is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
""")

    execute("""
    ALTER TABLE public.runtime_coordination_manifests
      DISABLE TRIGGER reject_runtime_coordination_manifests_mutation_trigger
    """)

    execute("""
    UPDATE public.runtime_coordination_manifests AS manifest
    SET function_fingerprints = pg_catalog.jsonb_set(
          manifest.function_fingerprints,
          '{enforce_agent_termination_proof}',
          pg_catalog.to_jsonb(pg_catalog.encode(public.digest(pg_catalog.convert_to(
            pg_catalog.jsonb_build_object(
              'definition', pg_catalog.pg_get_functiondef(fn.oid),
              'owner', fn_owner.rolname,
              'acl', fn.proacl
            )::text, 'UTF8'), 'sha256'), 'hex')),
          false
        ),
        constraint_fingerprints = pg_catalog.jsonb_set(
          manifest.constraint_fingerprints,
          '{agent_termination_proofs_shape}',
          pg_catalog.to_jsonb(pg_catalog.encode(public.digest(pg_catalog.convert_to(
            pg_catalog.regexp_replace(
              pg_catalog.pg_get_constraintdef(con.oid, true), ' NOT VALID$', ''),
            'UTF8'), 'sha256'), 'hex')),
          false
        ),
        catalog_fingerprints = pg_catalog.jsonb_set(
          manifest.catalog_fingerprints,
          '{agent_termination_proofs}',
          pg_catalog.to_jsonb(
            public.runtime_catalog_table_fingerprint(
              'public.agent_termination_proofs'::regclass)),
          false
        ),
        updated_at = timezone('UTC', clock_timestamp())
    FROM pg_catalog.pg_proc AS fn
    JOIN pg_catalog.pg_roles AS fn_owner ON fn_owner.oid = fn.proowner
    CROSS JOIN pg_catalog.pg_constraint AS con
    WHERE manifest.name = 'runtime'
      AND fn.oid = 'public.enforce_agent_termination_proof()'::regprocedure
      AND con.conrelid = 'public.agent_termination_proofs'::regclass
      AND con.conname = 'agent_termination_proofs_shape'
      AND manifest.function_fingerprints ? 'enforce_agent_termination_proof'
      AND manifest.constraint_fingerprints ? 'agent_termination_proofs_shape'
      AND manifest.catalog_fingerprints ? 'agent_termination_proofs'
    """)

    execute("""
    ALTER TABLE public.runtime_coordination_manifests
      ENABLE TRIGGER reject_runtime_coordination_manifests_mutation_trigger
    """)

    execute("""
    ALTER TABLE public.runtime_coordination_protocols
      DISABLE TRIGGER enforce_runtime_coordination_protocol_trigger
    """)

    execute("""
    UPDATE public.runtime_coordination_protocols AS protocol
    SET manifest_digest = public.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
          'constraints', manifest.constraint_fingerprints,
          'functions', manifest.function_fingerprints,
          'triggers', manifest.trigger_fingerprints,
          'indexes', manifest.index_fingerprints,
          'catalogs', manifest.catalog_fingerprints
        )::text, 'UTF8'), 'sha256'),
        updated_at = timezone('UTC', clock_timestamp())
    FROM public.runtime_coordination_manifests AS manifest
    WHERE protocol.name = 'runtime' AND manifest.name = protocol.name
    """)

    execute("""
    ALTER TABLE public.runtime_coordination_protocols
      ENABLE TRIGGER enforce_runtime_coordination_protocol_trigger
    """)

    execute("""
    DO $verify$
    BEGIN
      IF public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'coordination catalog not ready after migration (count=%)',
          public.runtime_coordination_catalog_ready_count();
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.runtime_coordination_protocols AS protocol
        JOIN public.runtime_coordination_manifests AS manifest ON manifest.name = protocol.name
        WHERE protocol.name = 'runtime'
          AND protocol.manifest_digest = public.digest(convert_to(jsonb_build_object(
            'constraints', manifest.constraint_fingerprints,
            'functions', manifest.function_fingerprints,
            'triggers', manifest.trigger_fingerprints,
            'indexes', manifest.index_fingerprints,
            'catalogs', manifest.catalog_fingerprints
          )::text, 'UTF8'), 'sha256')
      ) THEN
        RAISE EXCEPTION 'coordination manifest digest mismatch after migration';
      END IF;
    END
    $verify$;
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    ALTER TABLE public.agent_termination_proofs
      DROP CONSTRAINT IF EXISTS agent_termination_proofs_shape,
      ADD CONSTRAINT agent_termination_proofs_shape CHECK (
        proof_kind IN ('local_down', 'external_node_destroyed') AND
        octet_length(proved_by) BETWEEN 1 AND 320 AND
        ((activation_epoch IS NULL AND node_incarnation_id IS NULL AND
          partition_id IS NULL AND partition_epoch IS NULL) OR
         (activation_epoch IS NOT NULL AND node_incarnation_id IS NOT NULL AND
          partition_id BETWEEN 0 AND 63 AND partition_epoch > 0)) AND
        ((proof_kind = 'local_down' AND
          octet_length(local_pid) BETWEEN 1 AND 255 AND monitor_started_at IS NOT NULL AND
          octet_length(down_reason) BETWEEN 1 AND 255 AND
          evidence_id IS NULL AND evidence_digest IS NULL AND
          attestation_signature IS NULL) OR
         (proof_kind = 'external_node_destroyed' AND
          activation_epoch IS NOT NULL AND node_incarnation_id IS NOT NULL AND
          local_pid IS NULL AND monitor_started_at IS NULL AND down_reason IS NULL AND
          octet_length(evidence_id) BETWEEN 1 AND 256 AND
          octet_length(evidence_digest) = 32 AND
          octet_length(attestation_signature) = 64))
      )
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_agent_termination_proof()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      incident record;
      capability_digest bytea;
      local_capability bytea;
    BEGIN
      IF NOT (
        (NEW.proof_kind = 'local_down' AND current_user = 'maraithon_runtime') OR
        (NEW.proof_kind = 'external_node_destroyed' AND
          current_user = 'maraithon_incident_operator') OR
        (current_user = 'maraithon_migrator' AND EXISTS (
          SELECT 1 FROM public.runtime_coordination_protocols
          WHERE name = 'runtime' AND mode = 'dark'
        ))
      ) THEN
        RAISE EXCEPTION 'Agent termination proof kind is not authorized for current role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Agent termination proof is append-only'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT * INTO STRICT incident
      FROM public.agent_termination_incidents
      WHERE id = NEW.incident_id
      FOR UPDATE;

      IF incident.status <> 'requested' OR
         NEW.activation_epoch IS DISTINCT FROM incident.activation_epoch OR
         NEW.node_incarnation_id IS DISTINCT FROM incident.node_incarnation_id OR
         NEW.partition_id IS DISTINCT FROM incident.partition_id OR
         NEW.partition_epoch IS DISTINCT FROM incident.partition_epoch OR
         NEW.agent_id IS DISTINCT FROM incident.agent_id OR
         NEW.lease_token IS DISTINCT FROM incident.lease_token THEN
        RAISE EXCEPTION 'Agent termination proof identity does not match its incident'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.proof_kind = 'local_down' THEN
        SELECT lease.termination_capability_digest INTO capability_digest
        FROM public.agent_runtime_leases AS lease
        WHERE lease.agent_id = incident.agent_id
          AND lease.owner_token = incident.lease_token
          AND lease.owner_node = incident.owner_node
          AND lease.coordination_activation_epoch IS NOT DISTINCT FROM
                incident.activation_epoch
          AND lease.coordination_node_incarnation_id IS NOT DISTINCT FROM
                incident.node_incarnation_id
          AND lease.coordination_partition_id IS NOT DISTINCT FROM
                incident.partition_id
          AND lease.coordination_partition_epoch IS NOT DISTINCT FROM
                incident.partition_epoch
        FOR SHARE;

        BEGIN
          local_capability := decode(
            COALESCE(
              current_setting('maraithon.agent_termination_capability', true),
              ''
            ),
            'base64'
          );
        EXCEPTION WHEN OTHERS THEN
          RAISE EXCEPTION 'local Agent termination capability is invalid'
            USING ERRCODE = 'check_violation';
        END;

        IF octet_length(local_capability) IS DISTINCT FROM 32 OR
           public.digest(local_capability, 'sha256') IS DISTINCT FROM capability_digest THEN
          RAISE EXCEPTION 'local Agent termination proof requires exact capability authority'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF NEW.proof_kind = 'external_node_destroyed' AND
            current_setting('maraithon.agent_external_termination_attestation', true)
              IS DISTINCT FROM encode(NEW.evidence_digest, 'hex') THEN
        RAISE EXCEPTION 'external Agent termination proof requires signed operator attestation'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Agent termination incident is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
""")

    execute("""
    ALTER TABLE public.runtime_coordination_manifests
      DISABLE TRIGGER reject_runtime_coordination_manifests_mutation_trigger
    """)

    execute("""
    UPDATE public.runtime_coordination_manifests AS manifest
    SET function_fingerprints = pg_catalog.jsonb_set(
          manifest.function_fingerprints,
          '{enforce_agent_termination_proof}',
          pg_catalog.to_jsonb(pg_catalog.encode(public.digest(pg_catalog.convert_to(
            pg_catalog.jsonb_build_object(
              'definition', pg_catalog.pg_get_functiondef(fn.oid),
              'owner', fn_owner.rolname,
              'acl', fn.proacl
            )::text, 'UTF8'), 'sha256'), 'hex')),
          false
        ),
        constraint_fingerprints = pg_catalog.jsonb_set(
          manifest.constraint_fingerprints,
          '{agent_termination_proofs_shape}',
          pg_catalog.to_jsonb(pg_catalog.encode(public.digest(pg_catalog.convert_to(
            pg_catalog.regexp_replace(
              pg_catalog.pg_get_constraintdef(con.oid, true), ' NOT VALID$', ''),
            'UTF8'), 'sha256'), 'hex')),
          false
        ),
        catalog_fingerprints = pg_catalog.jsonb_set(
          manifest.catalog_fingerprints,
          '{agent_termination_proofs}',
          pg_catalog.to_jsonb(
            public.runtime_catalog_table_fingerprint(
              'public.agent_termination_proofs'::regclass)),
          false
        ),
        updated_at = timezone('UTC', clock_timestamp())
    FROM pg_catalog.pg_proc AS fn
    JOIN pg_catalog.pg_roles AS fn_owner ON fn_owner.oid = fn.proowner
    CROSS JOIN pg_catalog.pg_constraint AS con
    WHERE manifest.name = 'runtime'
      AND fn.oid = 'public.enforce_agent_termination_proof()'::regprocedure
      AND con.conrelid = 'public.agent_termination_proofs'::regclass
      AND con.conname = 'agent_termination_proofs_shape'
      AND manifest.function_fingerprints ? 'enforce_agent_termination_proof'
      AND manifest.constraint_fingerprints ? 'agent_termination_proofs_shape'
      AND manifest.catalog_fingerprints ? 'agent_termination_proofs'
    """)

    execute("""
    ALTER TABLE public.runtime_coordination_manifests
      ENABLE TRIGGER reject_runtime_coordination_manifests_mutation_trigger
    """)

    execute("""
    ALTER TABLE public.runtime_coordination_protocols
      DISABLE TRIGGER enforce_runtime_coordination_protocol_trigger
    """)

    execute("""
    UPDATE public.runtime_coordination_protocols AS protocol
    SET manifest_digest = public.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
          'constraints', manifest.constraint_fingerprints,
          'functions', manifest.function_fingerprints,
          'triggers', manifest.trigger_fingerprints,
          'indexes', manifest.index_fingerprints,
          'catalogs', manifest.catalog_fingerprints
        )::text, 'UTF8'), 'sha256'),
        updated_at = timezone('UTC', clock_timestamp())
    FROM public.runtime_coordination_manifests AS manifest
    WHERE protocol.name = 'runtime' AND manifest.name = protocol.name
    """)

    execute("""
    ALTER TABLE public.runtime_coordination_protocols
      ENABLE TRIGGER enforce_runtime_coordination_protocol_trigger
    """)

    execute("""
    DO $verify$
    BEGIN
      IF public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'coordination catalog not ready after migration (count=%)',
          public.runtime_coordination_catalog_ready_count();
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.runtime_coordination_protocols AS protocol
        JOIN public.runtime_coordination_manifests AS manifest ON manifest.name = protocol.name
        WHERE protocol.name = 'runtime'
          AND protocol.manifest_digest = public.digest(convert_to(jsonb_build_object(
            'constraints', manifest.constraint_fingerprints,
            'functions', manifest.function_fingerprints,
            'triggers', manifest.trigger_fingerprints,
            'indexes', manifest.index_fingerprints,
            'catalogs', manifest.catalog_fingerprints
          )::text, 'UTF8'), 'sha256')
      ) THEN
        RAISE EXCEPTION 'coordination manifest digest mismatch after migration';
      END IF;
    END
    $verify$;
    """)
  end
end
