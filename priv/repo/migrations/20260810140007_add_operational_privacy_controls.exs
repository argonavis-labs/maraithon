defmodule Maraithon.Repo.Migrations.AddOperationalPrivacyControls do
  use Ecto.Migration

  @moduledoc false

  # Existing durable tables can be large. Every heap change is a nullable,
  # metadata-only expansion and every index over an existing table is built
  # online. The operator code performs all cleanup in bounded locked batches.
  @disable_ddl_transaction true

  def up do
    execute_compatible(
      "ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_erasure_requested_at timestamp(6) without time zone"
    )

    execute_compatible(
      "ALTER TABLE agent_directives ADD COLUMN IF NOT EXISTS terminal_acknowledged_at timestamp(6) without time zone"
    )

    create_privacy_retention_statuses()
    create_privacy_erasure_requests()
    create_privacy_erasure_agent_targets()
    create_privacy_erasure_provider_revocations()
    create_privacy_erasure_receipts()
    create_privacy_erasure_job_deferral_receipts()
    reconcile_erasure_schema()
    add_erasure_constraints()
    add_legacy_cascade_constraints()
    install_privacy_erasure_job_deferral_receipts()
    install_privacy_erasure_write_fence()
    install_effect_retention_guard()
    install_directive_retention_guard()
    install_operational_retention_guard()
    attest_operational_privacy_protocol()
    create_online_indexes()
  end

  defp execute_compatible(statement) do
    statement
    |> Maraithon.DatabaseRoleCompatibility.rewrite_migration_sql()
    |> Ecto.Migration.execute()
  end

  defp execute_compatible(up, down) do
    Ecto.Migration.execute(
      Maraithon.DatabaseRoleCompatibility.rewrite_migration_sql(up),
      Maraithon.DatabaseRoleCompatibility.rewrite_migration_sql(down)
    )
  end

  def down do
    raise "operational privacy controls are irreversible after erasure or payload retention"
  end

  # 140007 is nontransactional so every retry must converge from either the
  # original schema or an interrupted earlier 140007 attempt.
  defp reconcile_erasure_schema do
    execute_compatible(
      "ALTER TABLE public.privacy_erasure_agent_targets " <>
        "DROP CONSTRAINT IF EXISTS privacy_erasure_agent_targets_agent_id_fkey"
    )

    execute_compatible("""
    ALTER TABLE public.privacy_erasure_provider_revocations
      DROP CONSTRAINT IF EXISTS privacy_erasure_provider_revocations_shape_check,
      ADD CONSTRAINT privacy_erasure_provider_revocations_shape_check CHECK (
        credential_table IN ('oauth_tokens', 'connected_accounts')
        AND credential_row_id >= 0
        AND octet_length(provider_code) BETWEEN 1 AND 80
        AND state IN ('pending', 'confirmed', 'unavailable', 'failed')
        AND attempt_count >= 0
        AND (error_code IS NULL OR error_code ~ '^[a-z0-9_]{1,128}$')
      )
    """)
  end

  defp install_privacy_erasure_job_deferral_receipts do
    execute_compatible("""
    CREATE OR REPLACE FUNCTION public.capture_privacy_erasure_job_deferral_receipt()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $privacy$
    DECLARE
      runtime_mode text;
      effect_mode text;
      evidence_id text;
      evidence_digest bytea;
      evidence_operator text;
      exact_revision text;
      verified_request_id uuid;
      request_id_text text;
    BEGIN
      -- Ordinary job lifecycle updates never enter the receipt authority. Only
      -- the exact plaintext-to-empty contraction projection is eligible.
      IF OLD.status IS DISTINCT FROM 'pending' OR
         OLD.queue IS DISTINCT FROM 'privacy' OR
         OLD.job_type IS DISTINCT FROM 'privacy_erasure' OR
         OLD.payload_purged_at IS NOT NULL OR
         OLD.claim_token IS NOT NULL OR
         OLD.claimed_by IS NOT NULL OR
         OLD.claimed_at IS NOT NULL OR
         OLD.partition_id IS NOT NULL OR
         OLD.coordination_activation_epoch IS NOT NULL OR
         OLD.coordination_partition_epoch IS NOT NULL OR
         OLD.coordination_node_incarnation_id IS NOT NULL OR
         OLD.coordination_task_assignment_id IS NOT NULL OR
         OLD.coordination_task_supervisor_id IS NOT NULL OR
         OLD.coordination_local_task_id IS NOT NULL OR
         OLD.payload IS NULL OR
         OLD.payload = '{}'::jsonb OR
         NEW.payload IS DISTINCT FROM '{}'::jsonb THEN
        RETURN NEW;
      END IF;

      IF (session_user IS DISTINCT FROM 'maraithon_activation_operator' AND
          current_setting('role', true) IS DISTINCT FROM
            'maraithon_activation_operator') OR
         current_setting('maraithon.payload_contraction', true) IS DISTINCT FROM
           'STOPPED_FLEET_EVIDENCE_V1' THEN
        RAISE EXCEPTION 'Privacy erasure job deferral receipt requires contraction authority'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      SELECT protocol.mode INTO STRICT runtime_mode
      FROM public.runtime_coordination_protocols AS protocol
      WHERE protocol.name = 'runtime'
      FOR SHARE;

      SELECT protocol.mode, protocol.activation_evidence_id,
             protocol.activation_evidence_digest, protocol.activated_by,
             protocol.exact_revision
      INTO STRICT effect_mode, evidence_id, evidence_digest,
                  evidence_operator, exact_revision
      FROM public.effect_execution_protocols AS protocol
      WHERE protocol.name = 'effects'
      FOR SHARE;

      IF runtime_mode <> 'dark' OR effect_mode <> 'legacy' OR
         evidence_id IS NULL OR pg_catalog.octet_length(evidence_id) NOT BETWEEN 1 AND 256 OR
         evidence_digest IS NULL OR pg_catalog.octet_length(evidence_digest) <> 32 OR
         evidence_operator IS NULL OR
           pg_catalog.octet_length(evidence_operator) NOT BETWEEN 1 AND 320 OR
         exact_revision IS NULL OR
           exact_revision !~ '^[0-9a-f]{40}([0-9a-f]{24})?$' THEN
        RAISE EXCEPTION 'Privacy erasure job deferral receipt requires dark legacy evidence'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_locks AS held_lock
        WHERE held_lock.locktype = 'relation'
          AND held_lock.pid = pg_catalog.pg_backend_pid()
          AND held_lock.relation = 'public.background_jobs'::regclass
          AND held_lock.mode = 'ShareRowExclusiveLock'
          AND held_lock.granted
      ) THEN
        RAISE EXCEPTION 'Privacy erasure job deferral receipt requires the contraction source lock'
          USING ERRCODE = 'object_not_in_prerequisite_state';
      END IF;

      IF public.durable_payload_catalog_ready() IS NOT TRUE OR
         public.privacy_protocol_catalog_ready() IS NOT TRUE THEN
        RAISE EXCEPTION 'Privacy erasure job deferral receipt requires attested catalogs'
          USING ERRCODE = 'object_not_in_prerequisite_state';
      END IF;

      request_id_text := OLD.payload ->> 'request_id';

      IF request_id_text IS NULL OR
         OLD.payload IS DISTINCT FROM pg_catalog.jsonb_build_object(
           'request_id', request_id_text
         ) OR
         OLD.dedupe_key IS DISTINCT FROM 'privacy-erasure:' || request_id_text OR
         OLD.result IS DISTINCT FROM '{}'::jsonb THEN
        RAISE EXCEPTION 'Privacy erasure job deferral plaintext shape is invalid'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT request.id INTO STRICT verified_request_id
      FROM public.privacy_erasure_requests AS request
      WHERE request.id::text = request_id_text
        AND request.state <> 'completed'
      FOR SHARE;

      IF NEW.id IS DISTINCT FROM OLD.id OR
         NEW.status IS DISTINCT FROM OLD.status OR
         NEW.queue IS DISTINCT FROM OLD.queue OR
         NEW.job_type IS DISTINCT FROM OLD.job_type OR
         NEW.dedupe_key IS DISTINCT FROM OLD.dedupe_key OR
         NEW.payload_purged_at IS NOT NULL OR
         NEW.claim_token IS NOT NULL OR
         NEW.claimed_by IS NOT NULL OR
         NEW.claimed_at IS NOT NULL OR
         NEW.partition_id IS NOT NULL OR
         NEW.coordination_activation_epoch IS NOT NULL OR
         NEW.coordination_partition_epoch IS NOT NULL OR
         NEW.coordination_node_incarnation_id IS NOT NULL OR
         NEW.coordination_task_assignment_id IS NOT NULL OR
         NEW.coordination_task_supervisor_id IS NOT NULL OR
         NEW.coordination_local_task_id IS NOT NULL OR
         NEW.payload_encryption_version IS DISTINCT FROM 1 OR
         NEW.payload_ciphertext IS NULL OR
         NEW.result_ciphertext IS NULL OR
         NEW.result IS DISTINCT FROM '{}'::jsonb OR
         NEW.payload_binding_version IS DISTINCT FROM 1 OR
         NEW.payload_binding_key_tag IS NULL OR
         NEW.payload_binding_key_tag !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' OR
         pg_catalog.octet_length(NEW.payload_binding_mac) IS DISTINCT FROM 32 OR
         (pg_catalog.to_jsonb(NEW) - ARRAY[
           'payload', 'payload_ciphertext', 'result', 'result_ciphertext',
           'payload_encryption_version', 'payload_binding_version',
           'payload_binding_key_tag', 'payload_binding_mac', 'updated_at'
         ]::text[]) IS DISTINCT FROM
         (pg_catalog.to_jsonb(OLD) - ARRAY[
           'payload', 'payload_ciphertext', 'result', 'result_ciphertext',
           'payload_encryption_version', 'payload_binding_version',
           'payload_binding_key_tag', 'payload_binding_mac', 'updated_at'
         ]::text[]) THEN
        RAISE EXCEPTION 'Privacy erasure job deferral contraction shape is invalid'
          USING ERRCODE = 'check_violation';
      END IF;

      INSERT INTO public.privacy_erasure_job_deferral_receipts (
        job_id, request_id, classification, queue, job_type, dedupe_key,
        established_at
      ) VALUES (
        OLD.id, verified_request_id, 'privacy_erasure_job_deferral_v1', OLD.queue,
        OLD.job_type, OLD.dedupe_key,
        pg_catalog.timezone('UTC', pg_catalog.clock_timestamp())
      )
      ON CONFLICT (job_id) DO NOTHING;

      IF NOT EXISTS (
        SELECT 1
        FROM public.privacy_erasure_job_deferral_receipts AS receipt
        WHERE receipt.job_id = OLD.id
          AND receipt.request_id = verified_request_id
          AND receipt.classification = 'privacy_erasure_job_deferral_v1'
          AND receipt.queue = OLD.queue
          AND receipt.job_type = OLD.job_type
          AND receipt.dedupe_key = OLD.dedupe_key
      ) THEN
        RAISE EXCEPTION 'Privacy erasure job deferral receipt identity conflict'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Privacy erasure job deferral authority is missing'
        USING ERRCODE = 'check_violation';
    END;
    $privacy$;
    """)

    execute_compatible("""
    CREATE OR REPLACE FUNCTION public.reject_privacy_erasure_job_deferral_receipt_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $privacy$
    BEGIN
      RAISE EXCEPTION 'Privacy erasure job deferral receipts are append-only'
        USING ERRCODE = 'insufficient_privilege';
    END;
    $privacy$;
    """)

    execute_compatible("""
    CREATE OR REPLACE TRIGGER capture_privacy_erasure_job_deferral_receipt_trigger
    BEFORE UPDATE OF payload ON public.background_jobs
    FOR EACH ROW
    EXECUTE FUNCTION public.capture_privacy_erasure_job_deferral_receipt()
    """)

    execute_compatible("""
    CREATE OR REPLACE TRIGGER reject_privacy_erasure_job_deferral_receipt_mutation_trigger
    BEFORE UPDATE OR DELETE ON public.privacy_erasure_job_deferral_receipts
    FOR EACH ROW
    EXECUTE FUNCTION public.reject_privacy_erasure_job_deferral_receipt_mutation()
    """)

    execute_compatible("""
    CREATE OR REPLACE TRIGGER reject_privacy_erasure_job_deferral_receipt_truncate_trigger
    BEFORE TRUNCATE ON public.privacy_erasure_job_deferral_receipts
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.reject_privacy_erasure_job_deferral_receipt_mutation()
    """)

    execute_compatible("""
    ALTER TABLE public.background_jobs
      ENABLE ALWAYS TRIGGER capture_privacy_erasure_job_deferral_receipt_trigger
    """)

    execute_compatible("""
    ALTER TABLE public.privacy_erasure_job_deferral_receipts
      ENABLE ALWAYS TRIGGER reject_privacy_erasure_job_deferral_receipt_mutation_trigger
    """)

    execute_compatible("""
    ALTER TABLE public.privacy_erasure_job_deferral_receipts
      ENABLE ALWAYS TRIGGER reject_privacy_erasure_job_deferral_receipt_truncate_trigger
    """)
  end

  defp install_privacy_erasure_write_fence do
    execute_compatible("""
    CREATE OR REPLACE FUNCTION public.enforce_privacy_erasure_write_fence()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $privacy$
    DECLARE
      invoker_role text := CASE
        WHEN current_setting('role', true) IS NULL
          OR current_setting('role', true) = 'none'
        THEN session_user
        ELSE current_setting('role', true)
      END;
      old_user_id text;
      new_user_id text;
      expected_user_count integer;
      locked_user_count integer;
      erasure_requested boolean;
      erasure_coordinator_authorized boolean := false;
    BEGIN
      IF TG_TABLE_NAME = 'users' THEN
        IF OLD.privacy_erasure_requested_at IS NOT NULL THEN
          IF NEW.privacy_erasure_requested_at IS DISTINCT FROM
               OLD.privacy_erasure_requested_at OR NEW.id IS DISTINCT FROM OLD.id THEN
            RAISE EXCEPTION 'Privacy erasure request authority cannot be cleared, changed, or moved'
              USING ERRCODE = 'check_violation';
          END IF;

          RAISE EXCEPTION 'Writes are fenced after privacy erasure is requested'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.privacy_erasure_requested_at IS NOT NULL AND NEW.id IS DISTINCT FROM OLD.id THEN
          RAISE EXCEPTION 'Privacy erasure request authority cannot be moved'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END IF;

      IF TG_OP = 'INSERT' THEN
        new_user_id := NEW.user_id;
      ELSIF TG_OP = 'UPDATE' THEN
        old_user_id := OLD.user_id;
        new_user_id := NEW.user_id;
      ELSE
        RETURN NEW;
      END IF;

      IF old_user_id IS NULL AND new_user_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT count(*)::integer,
             COALESCE(bool_or(locked.privacy_erasure_requested_at IS NOT NULL), false)
      INTO locked_user_count, erasure_requested
      FROM (
        SELECT user_row.privacy_erasure_requested_at
        FROM public.users AS user_row
        WHERE user_row.id = old_user_id OR user_row.id = new_user_id
        ORDER BY user_row.id
        FOR UPDATE
      ) AS locked;

      expected_user_count :=
        CASE
          WHEN old_user_id IS NULL OR new_user_id IS NULL OR old_user_id = new_user_id THEN 1
          ELSE 2
        END;

      IF locked_user_count <> expected_user_count THEN
        RAISE EXCEPTION 'Privacy erasure user authority row is missing'
          USING ERRCODE = 'check_violation';
      END IF;

      IF erasure_requested AND TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'agents' THEN
        SELECT
          invoker_role = 'maraithon_runtime'
          AND NEW.id IS NOT DISTINCT FROM OLD.id
          AND NEW.user_id IS NOT DISTINCT FROM OLD.user_id
          AND NEW.status = 'stopped'
          AND NEW.stopped_at IS NOT NULL
          AND (OLD.active_run_id IS NOT DISTINCT FROM NEW.active_run_id OR
               NEW.active_run_id IS NULL)
          AND (to_jsonb(NEW) - ARRAY[
            'status', 'stopped_at', 'active_run_id', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
              (to_jsonb(OLD) - ARRAY[
                'status', 'stopped_at', 'active_run_id', 'updated_at'
              ]::text[])
          AND EXISTS (
            SELECT 1
            FROM public.privacy_erasure_requests AS request
            JOIN public.privacy_erasure_agent_targets AS target
              ON target.request_id = request.id
             AND target.agent_id = OLD.id
            WHERE request.scope = 'user'
              AND request.subject_user_id = OLD.user_id
              AND request.state <> 'completed'
              AND (
                request.id::text IS NOT DISTINCT FROM
                  current_setting('maraithon.privacy_erasure_request_id', true)
                OR EXISTS (
                  SELECT 1
                  FROM public.agent_lifecycle_operations AS operation
                  WHERE operation.agent_id = OLD.id
                    AND operation.kind = 'delete'
                    AND operation.state = 'draining'
                    AND operation.payload #>> '{mutation,action}' = 'delete'
                    AND operation.payload ->> 'operation_token' =
                          operation.operation_token::text
                )
              )
          )
        INTO erasure_coordinator_authorized;
      ELSIF erasure_requested AND TG_OP = 'UPDATE' AND
            TG_TABLE_NAME = 'background_jobs' THEN
        erasure_coordinator_authorized :=
          NEW.user_id IS NOT DISTINCT FROM OLD.user_id
          AND (
            (
              invoker_role = 'maraithon_runtime'
              AND EXISTS (
                SELECT 1
                FROM public.privacy_erasure_requests AS request
                WHERE request.id::text IS NOT DISTINCT FROM
                        current_setting('maraithon.privacy_erasure_request_id', true)
                  AND request.scope = 'user'
                  AND request.subject_user_id = OLD.user_id
                  AND request.state <> 'completed'
              )
              AND (to_jsonb(NEW) - ARRAY[
                'status', 'claimed_by', 'claimed_at', 'claim_token',
                'cancelled_at', 'updated_at'
              ]::text[]) IS NOT DISTINCT FROM
                  (to_jsonb(OLD) - ARRAY[
                    'status', 'claimed_by', 'claimed_at', 'claim_token',
                    'cancelled_at', 'updated_at'
                  ]::text[])
              AND OLD.status = 'pending'
              AND OLD.coordination_task_assignment_id IS NULL
              AND OLD.claim_token IS NULL
              AND NEW.status = 'cancelled'
              AND NEW.claimed_by IS NULL
              AND NEW.claimed_at IS NULL
              AND NEW.claim_token IS NULL
            )
            OR
            (
              invoker_role = 'maraithon_runtime'
              AND (
                current_setting('maraithon.runtime_task_reconciliation', true)
                  IS NOT DISTINCT FROM OLD.coordination_task_assignment_id::text
                OR current_setting('maraithon.runtime_task_action', true)
                  IS NOT DISTINCT FROM OLD.coordination_task_assignment_id::text
              )
              AND EXISTS (
                SELECT 1
                FROM public.runtime_task_assignments AS assignment
                WHERE assignment.id = OLD.coordination_task_assignment_id
                  AND assignment.work_kind = 'background_job'
                  AND assignment.work_id = OLD.id
                  AND assignment.state IN ('settled', 'outcome_ambiguous')
              )
              AND (to_jsonb(NEW) - ARRAY[
                'status', 'scheduled_at', 'claimed_by', 'claimed_at', 'claim_token',
                'coordination_activation_epoch', 'coordination_partition_epoch',
                'coordination_node_incarnation_id', 'coordination_task_assignment_id',
                'coordination_task_supervisor_id', 'coordination_local_task_id',
                'failed_at', 'last_error', 'completed_at', 'updated_at'
              ]::text[]) IS NOT DISTINCT FROM
                  (to_jsonb(OLD) - ARRAY[
                    'status', 'scheduled_at', 'claimed_by', 'claimed_at', 'claim_token',
                    'coordination_activation_epoch', 'coordination_partition_epoch',
                    'coordination_node_incarnation_id', 'coordination_task_assignment_id',
                    'coordination_task_supervisor_id', 'coordination_local_task_id',
                    'failed_at', 'last_error', 'completed_at', 'updated_at'
                  ]::text[])
            )
          );
      END IF;

      IF erasure_requested AND NOT erasure_coordinator_authorized THEN
        RAISE EXCEPTION 'Writes are fenced after privacy erasure is requested'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $privacy$;
    """)

    execute_compatible("""
    CREATE OR REPLACE TRIGGER enforce_users_privacy_erasure_write_fence
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.enforce_privacy_erasure_write_fence()
    """)

    for table <- ~w(
          agents oauth_tokens connected_accounts user_sessions user_magic_links
          companion_devices companion_device_keys mobile_node_pairings
          mobile_node_devices mobile_push_devices background_jobs
        ) do
      execute_compatible("""
      CREATE OR REPLACE TRIGGER enforce_#{table}_privacy_erasure_write_fence
      BEFORE INSERT OR UPDATE ON public.#{table}
      FOR EACH ROW EXECUTE FUNCTION public.enforce_privacy_erasure_write_fence()
      """)
    end
  end

  defp install_effect_retention_guard do
    execute_compatible("""
    CREATE OR REPLACE FUNCTION public.enforce_effect_execution_protocol()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      protocol_mode text;
      writer_protocol text;
      sensitive_change boolean;
      lifecycle_erasure boolean;
      payload_expiry boolean;
    BEGIN
      SELECT mode INTO STRICT protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF TG_OP = 'DELETE' THEN
        IF protocol_mode = 'legacy' THEN
          RETURN OLD;
        END IF;

        IF protocol_mode <> 'generation_fenced_v1' THEN
          RAISE EXCEPTION 'Unknown Effect execution protocol mode'
            USING ERRCODE = 'check_violation';
        END IF;

        writer_protocol := current_setting('maraithon.effect_writer_protocol', true);

        IF writer_protocol IS DISTINCT FROM 'generation_fenced_v1' THEN
          RAISE EXCEPTION 'Durable Effect deletion requires generation-fenced writer marker'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT EXISTS (
          SELECT 1
          FROM public.agent_lifecycle_operations AS operation
          WHERE operation.agent_id = OLD.agent_id
            AND operation.kind = 'delete'
            AND operation.state = 'draining'
            AND operation.operation_token::text =
                  current_setting('maraithon.lifecycle_operation_token', true)
            AND operation.payload #>> '{mutation,action}' = 'delete'
            AND operation.payload ->> 'operation_token' = operation.operation_token::text
        ) INTO lifecycle_erasure;

        -- Legacy lineage remains immutable after activation. Either lineage
        -- may be deleted after normal durable consumption, or as an explicit
        -- erasure under a persisted lifecycle-delete marker. The latter is not
        -- represented as a false result acknowledgement.
        IF NOT ((
          (OLD.status = 'cancelled' AND OLD.result_envelope IS NULL) OR
          (OLD.status IN ('completed', 'failed', 'cancelled') AND
           OLD.result_envelope IS NOT NULL AND
           OLD.result_acknowledged_at IS NOT NULL) OR
          (lifecycle_erasure AND (
            (OLD.status = 'cancelled' AND OLD.result_envelope IS NULL) OR
            (OLD.status IN ('completed', 'failed', 'cancelled') AND
             pg_catalog.jsonb_typeof(OLD.result_envelope) = 'object' AND
             OLD.result_envelope ->> 'version' = '1' AND
             OLD.result_envelope ->> 'status' IN ('ok', 'error'))
          ))
        ) IS TRUE) THEN
          RAISE EXCEPTION 'Durable Effect deletion requires consumption or lifecycle erasure'
            USING ERRCODE = 'check_violation';
        END IF;

        PERFORM set_config(
          'maraithon.effect_attestation_cascade', OLD.id::text, true
        );

        RETURN OLD;
      END IF;

      IF TG_OP = 'UPDATE' AND
         NEW.runtime_owner_generation IS DISTINCT FROM OLD.runtime_owner_generation THEN
        RAISE EXCEPTION 'Effect runtime owner generation is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.cancellation_target_claim_token IS NOT NULL AND
         NEW.cancellation_target_claim_token IS DISTINCT FROM
           OLD.cancellation_target_claim_token AND NOT (
           OLD.status = 'cancelling' AND NEW.status IN ('pending', 'cancelled') AND
           OLD.cancellation_target_claim_token = OLD.claim_token AND
           NEW.cancellation_target_claim_token IS NULL AND NEW.claim_token IS NULL
         ) THEN
        RAISE EXCEPTION 'Effect cancellation target is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.runtime_owner_generation IS NOT NULL AND
         OLD.status IN ('completed', 'failed', 'cancelled') AND
         NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION 'Terminal exact Effect status is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      payload_expiry := COALESCE((TG_OP = 'UPDATE' AND
        OLD.status IN ('completed', 'failed', 'cancelled') AND
        OLD.result_acknowledged_at IS NOT NULL AND
        OLD.payload_purged_at IS NULL AND NEW.payload_purged_at IS NOT NULL AND
        current_setting('maraithon.privacy_retention_table', true) = 'effects' AND
        current_setting('maraithon.effect_payload_retention', true) =
          'PURGE_ACKNOWLEDGED_PAYLOAD' AND
        (OLD.status <> 'cancelled' OR
         OLD.runtime_owner_generation IS NULL OR
         OLD.cancellation_state = 'settled') AND
        NEW.params = '{"redacted": true}'::jsonb AND
        NEW.params_ciphertext IS NULL AND NEW.result IS NULL AND
        NEW.result_ciphertext IS NULL AND
        NEW.payload_binding_version IS NULL AND
        NEW.payload_binding_key_tag IS NULL AND
        NEW.payload_binding_mac IS NULL AND
        (to_jsonb(NEW) - ARRAY[
          'params', 'params_ciphertext', 'result', 'result_ciphertext',
          'payload_binding_version', 'payload_binding_key_tag',
          'payload_binding_mac', 'payload_purged_at', 'updated_at'
        ]::text[]) IS NOT DISTINCT FROM
        (to_jsonb(OLD) - ARRAY[
          'params', 'params_ciphertext', 'result', 'result_ciphertext',
          'payload_binding_version', 'payload_binding_key_tag',
          'payload_binding_mac', 'payload_purged_at', 'updated_at'
        ]::text[])), false);

      IF payload_expiry THEN
        NEW.payload_purged_at := timezone('UTC', clock_timestamp());
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.runtime_owner_generation IS NOT NULL AND
         OLD.status IN ('completed', 'failed', 'cancelled') AND NOT payload_expiry AND
         (to_jsonb(NEW) - ARRAY[
           'result_dispatched_at', 'result_dispatch_after',
           'result_dispatch_attempts', 'result_acknowledged_at', 'updated_at'
         ]::text[]) IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY[
           'result_dispatched_at', 'result_dispatch_after',
           'result_dispatch_attempts', 'result_acknowledged_at', 'updated_at'
         ]::text[]) THEN
        RAISE EXCEPTION 'Terminal exact Effect outcome is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.runtime_owner_generation IS NOT NULL AND
         OLD.status IN ('completed', 'failed', 'cancelled') AND (
           NEW.result_dispatch_attempts < OLD.result_dispatch_attempts OR
           (OLD.result_dispatched_at IS NOT NULL AND
            (NEW.result_dispatched_at IS NULL OR
             NEW.result_dispatched_at < OLD.result_dispatched_at)) OR
           (OLD.result_dispatch_after IS NOT NULL AND
            (NEW.result_dispatch_after IS NULL OR
             NEW.result_dispatch_after < OLD.result_dispatch_after)) OR
           (OLD.result_acknowledged_at IS NOT NULL AND
            NEW.result_acknowledged_at IS DISTINCT FROM OLD.result_acknowledged_at)
         ) THEN
        RAISE EXCEPTION 'Terminal exact Effect delivery state is monotonic'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.claim_token IS NOT NULL AND
         NEW.claim_token IS NOT NULL AND NEW.claim_token <> OLD.claim_token THEN
        RAISE EXCEPTION 'Effect claim token cannot change generations in place'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.claim_token IS NOT NULL AND
         NEW.claim_token IS NOT NULL AND (
           NEW.claim_owner_node IS DISTINCT FROM OLD.claim_owner_node OR
           NEW.claim_supervisor_id IS DISTINCT FROM OLD.claim_supervisor_id OR
           NEW.claim_task_id IS DISTINCT FROM OLD.claim_task_id
         ) THEN
        RAISE EXCEPTION 'Effect physical task identity is immutable within a claim generation'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.claim_token IS NULL AND
         NEW.claim_token IS NOT NULL AND NOT (
           OLD.runtime_owner_generation IS NOT NULL AND
           OLD.status = 'pending' AND NEW.status = 'claimed'
         ) THEN
        RAISE EXCEPTION 'Effect claim token can only be allocated by an exact pending claim'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.claim_token IS NOT NULL AND
         NEW.claim_token IS NULL AND NOT (
           OLD.runtime_owner_generation IS NOT NULL AND (
             (OLD.status = 'claimed' AND NEW.status = 'pending' AND
              OLD.cancellation_target_claim_token IS NULL) OR
             (OLD.status = 'cancelling' AND NEW.status IN ('pending', 'cancelled') AND
              OLD.cancellation_target_claim_token = OLD.claim_token AND
              NEW.cancellation_target_claim_token IS NULL)
           )
         ) THEN
        RAISE EXCEPTION 'Effect claim token can only be cleared by a known-safe retry or cancellation'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.cancellation_target_claim_token IS NULL AND
         NEW.cancellation_target_claim_token IS NOT NULL AND NOT (
           OLD.status IN ('claimed', 'executing') AND NEW.status = 'cancelling' AND
           NEW.cancellation_target_claim_token = NEW.claim_token
         ) THEN
        RAISE EXCEPTION 'Effect cancellation target can only fence the active exact claim'
          USING ERRCODE = 'check_violation';
      END IF;

      IF protocol_mode = 'legacy' THEN
        IF TG_OP = 'UPDATE' AND OLD.payload_purged_at IS NULL AND
           NEW.payload_purged_at IS NOT NULL THEN
          RAISE EXCEPTION 'Effect payload retention requires exact protocol mode'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.runtime_owner_generation IS NOT NULL OR NEW.claim_token IS NOT NULL OR
           NEW.claim_owner_node IS NOT NULL OR NEW.claim_heartbeat_at IS NOT NULL OR
           NEW.claim_expires_at IS NOT NULL OR NEW.claim_supervisor_id IS NOT NULL OR
           NEW.claim_task_id IS NOT NULL OR NEW.cancellation_state IS NOT NULL OR
           NEW.cancellation_reason IS NOT NULL OR
           NEW.cancellation_requested_at IS NOT NULL OR
           NEW.cancellation_target_claim_token IS NOT NULL OR
           NEW.cancellation_last_attempt_at IS NOT NULL OR
           NEW.cancellation_last_error IS NOT NULL OR
           NEW.cancellation_settled_at IS NOT NULL THEN
          RAISE EXCEPTION 'Exact Effect writes are disabled in legacy protocol mode'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END IF;

      IF protocol_mode <> 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Unknown Effect execution protocol mode'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.runtime_owner_generation IS NULL THEN
        IF payload_expiry AND
           current_setting('maraithon.effect_writer_protocol', true) =
             'generation_fenced_v1' THEN
          RETURN NEW;
        END IF;

        IF TG_OP = 'INSERT' OR NEW IS DISTINCT FROM OLD THEN
          RAISE EXCEPTION 'Legacy Effect rows are read-only after exact activation'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END IF;

      IF TG_OP = 'INSERT' AND NEW.status IS DISTINCT FROM 'pending' THEN
        RAISE EXCEPTION 'Exact Effect insertion must begin in pending admission state'
          USING ERRCODE = 'check_violation';
      END IF;

      sensitive_change := TG_OP = 'INSERT' OR NEW IS DISTINCT FROM OLD;

      writer_protocol := current_setting('maraithon.effect_writer_protocol', true);

      IF sensitive_change AND
         writer_protocol IS DISTINCT FROM 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Exact Effect mutation requires generation-fenced writer marker'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    EXCEPTION
      WHEN no_data_found THEN
        RAISE EXCEPTION 'Effect execution protocol row is missing'
          USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute_compatible("""
    CREATE OR REPLACE FUNCTION public.enforce_effect_termination_attestation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      attestation_valid boolean;
      deletion_authorized boolean;
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Effect termination attestations are immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'DELETE' THEN
        deletion_authorized :=
          (
            current_setting('maraithon.effect_attestation_cascade', true)
              IS NOT DISTINCT FROM OLD.effect_id::text
            OR current_setting('maraithon.effect_attestation_cleanup', true)
              IS NOT DISTINCT FROM 'ORPHAN_CLEANUP_V1'
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.effects AS effect
            WHERE effect.id = OLD.effect_id
          );

        IF NOT deletion_authorized THEN
          RAISE EXCEPTION 'Effect termination attestations are immutable'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN OLD;
      END IF;

      IF current_setting('maraithon.effect_termination_attestation', true)
           IS DISTINCT FROM 'PHYSICAL_TASK_TERMINATED' THEN
        RAISE EXCEPTION 'Effect termination attestation requires operator confirmation'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT EXISTS (
        SELECT 1
        FROM public.effects AS effect
        JOIN public.effect_execution_protocols AS protocol
          ON protocol.name = 'effects'
         AND protocol.mode = 'generation_fenced_v1'
        WHERE effect.id = NEW.effect_id
          AND effect.status = 'cancelling'
          AND effect.cancellation_state = 'requested'
          AND effect.runtime_owner_generation IS NOT NULL
          AND effect.claim_token = NEW.claim_token
          AND effect.cancellation_target_claim_token = NEW.claim_token
          AND effect.claim_owner_node = NEW.owner_node
          AND effect.claim_supervisor_id = NEW.supervisor_id
          AND effect.claim_task_id = NEW.task_id
        FOR SHARE OF effect
      ) INTO attestation_valid;

      IF NOT attestation_valid THEN
        RAISE EXCEPTION 'Effect termination attestation identity is not currently cancellable'
          USING ERRCODE = 'check_violation';
      END IF;

      NEW.attested_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    END;
    $function$;
    """)
  end

  defp install_directive_retention_guard do
    execute_compatible("""
    CREATE OR REPLACE FUNCTION public.enforce_agent_directive_protocol()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $privacy$
    DECLARE
      protocol_mode text;
      writer_protocol text;
      payload_expiry boolean := false;
    BEGIN
      SELECT mode INTO STRICT protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF protocol_mode = 'legacy' THEN
        IF TG_OP = 'UPDATE' AND OLD.payload_purged_at IS NULL AND
           NEW.payload_purged_at IS NOT NULL THEN
          RAISE EXCEPTION 'Directive payload retention requires exact protocol mode'
            USING ERRCODE = 'check_violation';
        END IF;

        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END IF;

      IF protocol_mode <> 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Unknown Agent Directive protocol mode'
          USING ERRCODE = 'check_violation';
      END IF;

      writer_protocol := current_setting('maraithon.effect_writer_protocol', true);

      IF writer_protocol IS DISTINCT FROM 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Exact Agent Directive mutation requires generation-fenced writer marker'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        payload_expiry := COALESCE((
          OLD.status IN ('completed', 'dead_letter')
          AND OLD.terminal_acknowledged_at IS NOT NULL
          AND OLD.payload_purged_at IS NULL
          AND NEW.payload_purged_at IS NOT NULL
          AND OLD.ambiguity_code IS NULL
          AND OLD.active_run_id IS NULL
          AND current_setting('maraithon.privacy_retention_table', true) =
                'agent_directives'
          AND current_setting('maraithon.directive_payload_retention', true) =
                'PURGE_ACKNOWLEDGED_PAYLOAD'
          AND NEW.payload = '{"redacted": true}'::jsonb
          AND NEW.payload_ciphertext IS NULL
          AND NEW.payload_binding_version IS NULL
          AND NEW.payload_binding_key_tag IS NULL
          AND NEW.payload_binding_mac IS NULL
          AND (to_jsonb(NEW) - ARRAY[
                 'payload', 'payload_ciphertext', 'payload_binding_version',
                 'payload_binding_key_tag', 'payload_binding_mac',
                 'payload_purged_at', 'updated_at'
              ]::text[]) IS NOT DISTINCT FROM
              (to_jsonb(OLD) - ARRAY[
                 'payload', 'payload_ciphertext', 'payload_binding_version',
                 'payload_binding_key_tag', 'payload_binding_mac',
                 'payload_purged_at', 'updated_at'
              ]::text[])
        ), false);
      END IF;

      IF payload_expiry THEN
        NEW.payload_purged_at := timezone('UTC', clock_timestamp());
        RETURN NEW;
      END IF;

      IF NOT ((
        NEW.payload_encryption_version = 1 AND
        NEW.payload_ciphertext IS NOT NULL AND
        NEW.payload = '{"redacted": true}'::jsonb AND
        NEW.payload_binding_version = 1 AND
        NEW.payload_binding_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' AND
        octet_length(NEW.payload_binding_mac) = 32
      ) IS TRUE) THEN
        RAISE EXCEPTION 'Exact Agent Directive payload must remain encrypted, bound, and redacted'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    EXCEPTION
      WHEN no_data_found THEN
        RAISE EXCEPTION 'Effect execution protocol row is missing'
          USING ERRCODE = 'check_violation';
    END;
    $privacy$;
    """)
  end

  defp install_operational_retention_guard do
    execute_compatible("""
    CREATE OR REPLACE FUNCTION public.enforce_operational_privacy_retention()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $privacy$
    DECLARE
      protocol_mode text;
      expected_table text;
      cutoff timestamp(6) without time zone;
      marker_column text;
      marker_transition boolean := false;
      eligible boolean := false;
      narrow_change boolean := false;
    BEGIN
      marker_column := CASE TG_TABLE_NAME
        WHEN 'telegram_conversation_turns' THEN 'content_scrubbed_at'
        WHEN 'telegram_conversations' THEN 'content_scrubbed_at'
        WHEN 'agent_runs' THEN 'private_payload_purged_at'
        WHEN 'agent_work_results' THEN 'result_purged_at'
        ELSE 'payload_purged_at'
      END;

      marker_transition :=
        (to_jsonb(OLD) ->> marker_column) IS NULL
        AND (to_jsonb(NEW) ->> marker_column) IS NOT NULL;

      IF NOT marker_transition THEN
        RETURN NEW;
      END IF;

      SELECT mode INTO STRICT protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF protocol_mode <> 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Payload retention requires exact protocol mode'
          USING ERRCODE = 'check_violation';
      END IF;

      IF current_setting('maraithon.effect_writer_protocol', true)
           IS DISTINCT FROM 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Payload retention requires exact writer authority'
          USING ERRCODE = 'check_violation';
      END IF;

      expected_table := current_setting('maraithon.privacy_retention_table', true);

      IF expected_table IS DISTINCT FROM TG_TABLE_NAME AND NOT (
        expected_table = 'telegram_conversations'
        AND TG_TABLE_NAME IN ('telegram_conversation_turns', 'telegram_conversations')
      ) THEN
        RAISE EXCEPTION 'Payload retention table marker mismatch'
          USING ERRCODE = 'check_violation';
      END IF;

      cutoff := current_setting('maraithon.privacy_retention_cutoff', true)::timestamp;

      IF cutoff IS NULL OR cutoff > timezone('UTC', clock_timestamp()) THEN
        RAISE EXCEPTION 'Payload retention cutoff is absent or future-dated'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT ((NEW.payload_binding_version IS NULL
               AND NEW.payload_binding_key_tag IS NULL
               AND NEW.payload_binding_mac IS NULL) IS TRUE) THEN
        RAISE EXCEPTION 'Retained payload bindings must be empty'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_TABLE_NAME = 'effects' THEN
        eligible :=
          OLD.status IN ('completed', 'failed', 'cancelled')
          AND OLD.result_acknowledged_at IS NOT NULL
          AND OLD.result_acknowledged_at <= cutoff
          AND pg_catalog.jsonb_typeof(OLD.result_envelope) = 'object'
          AND OLD.result_envelope ->> 'version' = '1'
          AND OLD.result_envelope ->> 'status' IN ('ok', 'error')
          AND (OLD.status <> 'cancelled' OR OLD.runtime_owner_generation IS NULL
               OR OLD.cancellation_state = 'settled');
      ELSIF TG_TABLE_NAME = 'agent_directives' THEN
        eligible :=
          OLD.status IN ('completed', 'dead_letter')
          AND OLD.terminal_acknowledged_at IS NOT NULL
          AND OLD.terminal_acknowledged_at <= cutoff
          AND OLD.ambiguity_code IS NULL AND OLD.active_run_id IS NULL;
      ELSIF TG_TABLE_NAME = 'events' THEN
        eligible :=
          OLD.inserted_at <= cutoff
          AND OLD.spend_total_cost IS NOT NULL
          AND OLD.spend_input_tokens IS NOT NULL
          AND OLD.spend_output_tokens IS NOT NULL
          AND OLD.spend_llm_calls IS NOT NULL;
      ELSIF TG_TABLE_NAME = 'agent_run_steps' THEN
        eligible :=
          OLD.status IN ('completed', 'failed')
          AND OLD.completed_at IS NOT NULL AND OLD.completed_at <= cutoff
          AND EXISTS (
            SELECT 1 FROM public.agent_runs AS run
            JOIN public.agents AS agent ON agent.id = run.agent_id
            WHERE run.id = OLD.agent_run_id AND run.agent_id = OLD.agent_id
              AND run.status IN ('completed', 'failed', 'cancelled')
              AND run.completed_at IS NOT NULL AND run.completed_at <= cutoff
              AND agent.active_run_id IS DISTINCT FROM run.id
          );
      ELSIF TG_TABLE_NAME = 'agent_runs' THEN
        eligible :=
          OLD.status IN ('completed', 'failed', 'cancelled')
          AND OLD.completed_at IS NOT NULL AND OLD.completed_at <= cutoff
          AND EXISTS (
            SELECT 1 FROM public.agents AS agent
            WHERE agent.id = OLD.agent_id AND agent.active_run_id IS DISTINCT FROM OLD.id
          );
      ELSIF TG_TABLE_NAME = 'telegram_assistant_runs' THEN
        eligible :=
          OLD.status IN ('completed', 'failed', 'cancelled', 'degraded')
          AND OLD.finished_at IS NOT NULL AND OLD.finished_at <= cutoff
          AND NOT EXISTS (
            SELECT 1 FROM public.telegram_assistant_steps AS step
            WHERE step.run_id = OLD.id
              AND (step.finished_at IS NULL OR step.status = 'running')
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.telegram_prepared_actions AS action
            WHERE action.run_id = OLD.id
              AND action.status NOT IN ('executed', 'rejected', 'expired', 'failed')
          );
      ELSIF TG_TABLE_NAME = 'telegram_assistant_steps' THEN
        eligible :=
          OLD.status IN ('completed', 'failed', 'skipped')
          AND OLD.finished_at IS NOT NULL AND OLD.finished_at <= cutoff
          AND EXISTS (
            SELECT 1 FROM public.telegram_assistant_runs AS run
            WHERE run.id = OLD.run_id
              AND run.status IN ('completed', 'failed', 'cancelled', 'degraded')
              AND run.finished_at IS NOT NULL AND run.finished_at <= cutoff
          );
      ELSIF TG_TABLE_NAME = 'telegram_prepared_actions' THEN
        eligible :=
          OLD.status IN ('executed', 'rejected', 'expired', 'failed')
          AND OLD.updated_at <= cutoff;
      ELSIF TG_TABLE_NAME = 'operator_events' THEN
        eligible :=
    OLD.occurred_at <= cutoff;
      ELSIF TG_TABLE_NAME = 'background_jobs' THEN
        eligible :=
          OLD.status IN ('completed', 'failed', 'cancelled')
          AND OLD.claim_token IS NULL AND OLD.claimed_at IS NULL
          AND COALESCE(OLD.completed_at, OLD.failed_at, OLD.cancelled_at) IS NOT NULL
          AND COALESCE(OLD.completed_at, OLD.failed_at, OLD.cancelled_at) <= cutoff;
      ELSIF TG_TABLE_NAME = 'scheduled_jobs' THEN
        eligible :=
          ((OLD.status = 'delivered' AND OLD.delivered_at IS NOT NULL)
           OR (OLD.status = 'cancelled' AND OLD.dispatched_at IS NULL))
          AND OLD.claimed_by IS NULL AND OLD.claimed_at IS NULL
          AND COALESCE(OLD.delivered_at, OLD.inserted_at) <= cutoff;
      ELSIF TG_TABLE_NAME = 'runtime_ingress_receipts' THEN
        eligible :=
          OLD.received_at IS NOT NULL AND OLD.received_at <= cutoff;
      ELSIF TG_TABLE_NAME = 'agent_work_results' THEN
        eligible :=
          OLD.status = 'committed' AND OLD.committed_at IS NOT NULL
          AND OLD.committed_at <= cutoff
          AND OLD.result_digest_version = 1
          AND OLD.result_digest IS NOT NULL AND octet_length(OLD.result_digest) = 32
          AND OLD.result_digest_key_tag IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM public.agent_directives AS directive
            WHERE directive.id = OLD.agent_directive_id
              AND directive.status IN ('completed', 'dead_letter')
              AND directive.terminal_acknowledged_at IS NOT NULL
              AND directive.terminal_acknowledged_at <= cutoff
              AND directive.ambiguity_code IS NULL
              AND directive.active_run_id IS NULL
          );
      ELSIF TG_TABLE_NAME = 'telegram_conversation_turns' THEN
        eligible :=
          OLD.inserted_at <= cutoff
          AND EXISTS (
            SELECT 1 FROM public.telegram_conversations AS conversation
            WHERE conversation.id = OLD.conversation_id
              AND conversation.status = 'closed'
              AND COALESCE(conversation.last_turn_at, conversation.updated_at) <= cutoff
              AND NOT EXISTS (
                SELECT 1 FROM public.telegram_assistant_runs AS run
                WHERE run.conversation_id = conversation.id
                  AND (run.finished_at IS NULL OR run.status IN (
                    'queued', 'running', 'waiting_confirmation'
                  ))
              )
              AND NOT EXISTS (
                SELECT 1 FROM public.telegram_prepared_actions AS action
                WHERE action.conversation_id = conversation.id
                  AND action.status NOT IN ('executed', 'rejected', 'expired', 'failed')
              )
          );
      ELSIF TG_TABLE_NAME = 'telegram_conversations' THEN
        eligible :=
          OLD.status = 'closed'
          AND COALESCE(OLD.last_turn_at, OLD.updated_at) <= cutoff
          AND NOT EXISTS (
            SELECT 1 FROM public.telegram_assistant_runs AS run
            WHERE run.conversation_id = OLD.id
              AND (run.finished_at IS NULL OR run.status IN (
                'queued', 'running', 'waiting_confirmation'
              ))
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.telegram_prepared_actions AS action
            WHERE action.conversation_id = OLD.id
              AND action.status NOT IN ('executed', 'rejected', 'expired', 'failed')
          );
      ELSE
        eligible := false;
      END IF;

      IF NOT COALESCE(eligible, false) THEN
        RAISE EXCEPTION 'Payload retention requires settled terminal authority'
          USING ERRCODE = 'check_violation';
      END IF;

      narrow_change := CASE TG_TABLE_NAME
        WHEN 'effects' THEN
          (to_jsonb(NEW) - ARRAY[
            'params', 'params_ciphertext', 'result', 'result_ciphertext',
            'payload_binding_version', 'payload_binding_key_tag',
            'payload_binding_mac', 'payload_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'params', 'params_ciphertext', 'result', 'result_ciphertext',
            'payload_binding_version', 'payload_binding_key_tag',
            'payload_binding_mac', 'payload_purged_at', 'updated_at'
          ]::text[])
        WHEN 'agent_directives' THEN
          (to_jsonb(NEW) - ARRAY[
            'payload', 'payload_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'payload_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'payload', 'payload_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'payload_purged_at', 'updated_at'
          ]::text[])
        WHEN 'events' THEN
          (to_jsonb(NEW) - ARRAY[
            'payload', 'payload_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac', 'payload_purged_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'payload', 'payload_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac', 'payload_purged_at'
          ]::text[])
        WHEN 'agent_run_steps' THEN
          (to_jsonb(NEW) - ARRAY[
            'request_payload', 'request_payload_ciphertext', 'response_payload',
            'response_payload_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'payload_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'request_payload', 'request_payload_ciphertext', 'response_payload',
            'response_payload_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'payload_purged_at', 'updated_at'
          ]::text[])
        WHEN 'telegram_conversation_turns' THEN
          (to_jsonb(NEW) - ARRAY[
            'text', 'text_ciphertext', 'structured_data',
            'structured_data_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'content_scrubbed_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'text', 'text_ciphertext', 'structured_data',
            'structured_data_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'content_scrubbed_at', 'updated_at'
          ]::text[])
        WHEN 'telegram_conversations' THEN
          (to_jsonb(NEW) - ARRAY[
            'summary', 'summary_ciphertext', 'historical_summary_ciphertext',
            'metadata', 'payload_binding_version', 'payload_binding_key_tag',
            'payload_binding_mac', 'content_scrubbed_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'summary', 'summary_ciphertext', 'historical_summary_ciphertext',
            'metadata', 'payload_binding_version', 'payload_binding_key_tag',
            'payload_binding_mac', 'content_scrubbed_at', 'updated_at'
          ]::text[])
        WHEN 'telegram_assistant_runs' THEN
          (to_jsonb(NEW) - ARRAY[
            'prompt_snapshot', 'prompt_snapshot_ciphertext', 'result_summary',
            'result_summary_ciphertext', 'error', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'payload_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'prompt_snapshot', 'prompt_snapshot_ciphertext', 'result_summary',
            'result_summary_ciphertext', 'error', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'payload_purged_at', 'updated_at'
          ]::text[])
        WHEN 'telegram_assistant_steps' THEN
          (to_jsonb(NEW) - ARRAY[
            'request_payload', 'request_payload_ciphertext', 'response_payload',
            'response_payload_ciphertext', 'error', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'payload_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'request_payload', 'request_payload_ciphertext', 'response_payload',
            'response_payload_ciphertext', 'error', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'payload_purged_at', 'updated_at'
          ]::text[])
        WHEN 'telegram_prepared_actions' THEN
          (to_jsonb(NEW) - ARRAY[
            'payload', 'payload_ciphertext', 'preview_text',
            'preview_text_ciphertext', 'payload_todo_id',
            'payload_surviving_person_id', 'payload_merged_person_id', 'error',
            'payload_binding_version', 'payload_binding_key_tag',
            'payload_binding_mac', 'payload_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'payload', 'payload_ciphertext', 'preview_text',
            'preview_text_ciphertext', 'payload_todo_id',
            'payload_surviving_person_id', 'payload_merged_person_id', 'error',
            'payload_binding_version', 'payload_binding_key_tag',
            'payload_binding_mac', 'payload_purged_at', 'updated_at'
          ]::text[])
        WHEN 'agent_runs' THEN
          (to_jsonb(NEW) - ARRAY[
            'trigger', 'trigger_ciphertext', 'metadata', 'metadata_ciphertext',
            'budget_snapshot', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'private_payload_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'trigger', 'trigger_ciphertext', 'metadata', 'metadata_ciphertext',
            'budget_snapshot', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
            'private_payload_purged_at', 'updated_at'
          ]::text[])
        WHEN 'operator_events' THEN
          (to_jsonb(NEW) - ARRAY[
            'payload', 'payload_ciphertext', 'metadata', 'metadata_ciphertext',
            'payload_binding_version', 'payload_binding_key_tag',
            'payload_binding_mac', 'payload_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'payload', 'payload_ciphertext', 'metadata', 'metadata_ciphertext',
            'payload_binding_version', 'payload_binding_key_tag',
            'payload_binding_mac', 'payload_purged_at', 'updated_at'
          ]::text[])
        WHEN 'background_jobs' THEN
          (to_jsonb(NEW) - ARRAY[
            'payload', 'payload_ciphertext', 'result', 'result_ciphertext',
            'last_error', 'payload_binding_version', 'payload_binding_key_tag',
            'payload_binding_mac', 'payload_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'payload', 'payload_ciphertext', 'result', 'result_ciphertext',
            'last_error', 'payload_binding_version', 'payload_binding_key_tag',
            'payload_binding_mac', 'payload_purged_at', 'updated_at'
          ]::text[])
        WHEN 'scheduled_jobs' THEN
          (to_jsonb(NEW) - ARRAY[
            'payload', 'payload_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac', 'payload_purged_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'payload', 'payload_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac', 'payload_purged_at'
          ]::text[])
        WHEN 'runtime_ingress_receipts' THEN
          (to_jsonb(NEW) - ARRAY[
            'payload', 'payload_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac', 'payload_purged_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'payload', 'payload_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac', 'payload_purged_at'
          ]::text[])
        WHEN 'agent_work_results' THEN
          (to_jsonb(NEW) - ARRAY[
            'result', 'result_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac', 'result_digest',
            'result_digest_version', 'result_digest_key_tag',
            'result_content_digest', 'result_content_digest_version',
            'result_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'result', 'result_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac', 'result_digest',
            'result_digest_version', 'result_digest_key_tag',
            'result_content_digest', 'result_content_digest_version',
            'result_purged_at', 'updated_at'
          ]::text[])
        ELSE false
      END;

      IF NOT COALESCE(narrow_change, false) THEN
        RAISE EXCEPTION 'Payload retention attempted a non-content mutation'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_TABLE_NAME = 'telegram_conversation_turns' THEN
        NEW.content_scrubbed_at := timezone('UTC', clock_timestamp());
      ELSIF TG_TABLE_NAME = 'telegram_conversations' THEN
        NEW.content_scrubbed_at := timezone('UTC', clock_timestamp());
      ELSIF TG_TABLE_NAME = 'agent_runs' THEN
        NEW.private_payload_purged_at := timezone('UTC', clock_timestamp());
      ELSIF TG_TABLE_NAME = 'agent_work_results' THEN
        NEW.result_purged_at := timezone('UTC', clock_timestamp());
      ELSE
        NEW.payload_purged_at := timezone('UTC', clock_timestamp());
      END IF;

      RETURN NEW;
    EXCEPTION
      WHEN no_data_found THEN
        RAISE EXCEPTION 'Effect execution protocol row is missing'
          USING ERRCODE = 'check_violation';
    END;
    $privacy$;
    """)

    for table <- ~w(
          effects agent_directives events agent_run_steps
          telegram_conversation_turns telegram_conversations
          telegram_assistant_runs telegram_assistant_steps
          telegram_prepared_actions agent_runs operator_events background_jobs
          scheduled_jobs runtime_ingress_receipts agent_work_results
        ) do
      trigger = "enforce_#{table}_operational_retention"

      execute_compatible("""
      CREATE OR REPLACE TRIGGER #{trigger}
      BEFORE UPDATE ON public.#{table}
      FOR EACH ROW EXECUTE FUNCTION public.enforce_operational_privacy_retention()
      """)
    end

    execute_compatible("""
    ALTER TABLE public.agent_work_results
      ADD COLUMN IF NOT EXISTS result_content_digest bytea,
      ADD COLUMN IF NOT EXISTS result_content_digest_version smallint
    """)

    execute_compatible("""
    COMMENT ON COLUMN public.agent_work_results.result_content_digest IS
      'Opaque frozen result HMAC token retained after ciphertext erasure; never an unkeyed plaintext digest'
    """)

    execute_compatible("""
    COMMENT ON COLUMN public.agent_work_results.result_content_digest_version IS
      '0 denotes an opaque HMAC snapshot with all key-binding metadata removed'
    """)

    execute_compatible("""
    CREATE OR REPLACE FUNCTION public.guard_agent_work_result_transition()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $privacy$
    DECLARE
      operator_authorized boolean := false;
      retention_authorized boolean := false;
    BEGIN
      IF OLD.status = 'provisional' AND NEW.status = 'committed' THEN
        IF (to_jsonb(NEW) - ARRAY['status', 'committed_at', 'updated_at']::text[])
             IS DISTINCT FROM
           (to_jsonb(OLD) - ARRAY['status', 'committed_at', 'updated_at']::text[]) THEN
          RAISE EXCEPTION 'agent work result proof is immutable'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END IF;

      IF OLD.status = NEW.status AND OLD.status IN ('provisional', 'committed') THEN
        operator_authorized := false;

        IF current_user IN (
          'maraithon_incident_operator', 'maraithon_activation_operator'
        ) THEN
          IF public.durable_payload_operator_row_mutation_authorized(
                TG_RELID::regclass, TG_OP, pg_catalog.to_jsonb(OLD), pg_catalog.to_jsonb(NEW)
              ) IS TRUE THEN
            operator_authorized :=
              (
                OLD.result_purged_at IS NULL
                AND NEW.result_purged_at IS NULL
                AND (to_jsonb(NEW) - ARRAY[
                  'payload_binding_version', 'payload_binding_key_tag',
                  'payload_binding_mac', 'updated_at'
                ]::text[]) IS NOT DISTINCT FROM
                    (to_jsonb(OLD) - ARRAY[
                      'payload_binding_version', 'payload_binding_key_tag',
                      'payload_binding_mac', 'updated_at'
                    ]::text[])
                AND NEW.payload_binding_version = 1
                AND NEW.payload_binding_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
                AND octet_length(NEW.payload_binding_mac) = 32
              )
              OR
              (
                OLD.result_purged_at IS NULL
                AND NEW.result_purged_at IS NULL
                AND (to_jsonb(NEW) - ARRAY[
                  'result_digest', 'result_digest_version',
                  'result_digest_key_tag', 'updated_at'
                ]::text[]) IS NOT DISTINCT FROM
                    (to_jsonb(OLD) - ARRAY[
                      'result_digest', 'result_digest_version',
                      'result_digest_key_tag', 'updated_at'
                    ]::text[])
                AND NEW.result_digest_version = 1
                AND NEW.result_digest_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
                AND octet_length(NEW.result_digest) = 32
              )
              OR
              (
                current_user = 'maraithon_incident_operator'
                AND current_setting('maraithon.vault_reencryption', true)
                      IS NOT DISTINCT FROM 'VAULT_REENCRYPT_V1'
                AND OLD.result_purged_at IS NULL
                AND NEW.result_purged_at IS NULL
                AND (to_jsonb(NEW) - ARRAY['result_ciphertext', 'updated_at']::text[])
                      IS NOT DISTINCT FROM
                    (to_jsonb(OLD) - ARRAY['result_ciphertext', 'updated_at']::text[])
                AND NEW.result_ciphertext IS NOT NULL
              );
          END IF;
        ELSIF current_user = 'maraithon_migrator' OR EXISTS (
          SELECT 1 FROM pg_catalog.pg_roles AS role_row
          WHERE role_row.rolname = current_user AND role_row.rolsuper
        ) THEN
          operator_authorized :=
            OLD.status = 'committed'
            AND (current_user = 'maraithon_migrator' OR EXISTS (
              SELECT 1 FROM pg_catalog.pg_roles AS role_row
              WHERE role_row.rolname = current_user AND role_row.rolsuper
            ))
            AND current_setting('maraithon.agent_work_result_purge_repair', true)
                  IS NOT DISTINCT FROM 'CLEAR_PURGED_AUTHORITY_V1'
            AND EXISTS (
              SELECT 1
              FROM public.runtime_coordination_protocols AS runtime_protocol
              CROSS JOIN public.effect_execution_protocols AS effect_protocol
              WHERE runtime_protocol.name = 'runtime'
                AND runtime_protocol.mode = 'dark'
                AND effect_protocol.name = 'effects'
                AND effect_protocol.mode = 'legacy'
            )
            AND OLD.result_purged_at IS NOT NULL
            AND NEW.result_purged_at IS NOT DISTINCT FROM OLD.result_purged_at
            AND (to_jsonb(NEW) - ARRAY[
              'result_digest', 'result_digest_version',
              'result_digest_key_tag', 'result_content_digest',
              'result_content_digest_version', 'updated_at'
            ]::text[]) IS NOT DISTINCT FROM
                (to_jsonb(OLD) - ARRAY[
                  'result_digest', 'result_digest_version',
                  'result_digest_key_tag', 'result_content_digest',
                  'result_content_digest_version', 'updated_at'
                ]::text[])
            AND NEW.result_digest IS NULL
            AND NEW.result_digest_version IS NULL
            AND NEW.result_digest_key_tag IS NULL
            AND NEW.result_content_digest =
                  COALESCE(OLD.result_digest, OLD.result_content_digest)
            AND NEW.result_content_digest_version = 0;
        END IF;

        retention_authorized :=
          OLD.status = 'committed'
          AND current_user = 'maraithon_runtime'
          AND current_setting('maraithon.effect_writer_protocol', true)
                IS NOT DISTINCT FROM 'generation_fenced_v1'
          AND current_setting('maraithon.privacy_retention_table', true)
                IS NOT DISTINCT FROM 'agent_work_results'
          AND OLD.result_purged_at IS NULL
          AND OLD.result_digest_version = 1
          AND OLD.result_digest_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
          AND octet_length(OLD.result_digest) = 32
          AND NEW.result_purged_at IS NOT NULL
          AND (to_jsonb(NEW) - ARRAY[
            'result', 'result_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac', 'result_digest',
            'result_digest_version', 'result_digest_key_tag',
            'result_content_digest', 'result_content_digest_version',
            'result_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
              (to_jsonb(OLD) - ARRAY[
                'result', 'result_ciphertext', 'payload_binding_version',
                'payload_binding_key_tag', 'payload_binding_mac', 'result_digest',
                'result_digest_version', 'result_digest_key_tag',
                'result_content_digest', 'result_content_digest_version',
                'result_purged_at', 'updated_at'
              ]::text[])
          AND NEW.result = '{}'::jsonb
          AND NEW.result_ciphertext IS NULL
          AND NEW.payload_binding_version IS NULL
          AND NEW.payload_binding_key_tag IS NULL
          AND NEW.payload_binding_mac IS NULL
          AND NEW.result_digest IS NULL
          AND NEW.result_digest_version IS NULL
          AND NEW.result_digest_key_tag IS NULL
          AND NEW.result_content_digest = OLD.result_digest
          AND NEW.result_content_digest_version = 0;

        IF operator_authorized OR retention_authorized THEN
          RETURN NEW;
        END IF;
      END IF;

      RAISE EXCEPTION 'agent work result permits only commit or narrow payload lifecycle mutation'
        USING ERRCODE = '23514';
    END;
    $privacy$;
    """)

    execute_compatible("""
    ALTER TABLE public.agent_work_results
      ALTER COLUMN result_digest DROP NOT NULL
    """)

    flush()
    repair_purged_agent_work_result_authority()

    execute_compatible("""
    ALTER TABLE public.agent_work_results
      DROP CONSTRAINT IF EXISTS agent_work_results_digest_check
    """)

    execute_compatible("""
    ALTER TABLE public.agent_work_results
      ADD CONSTRAINT agent_work_results_digest_check CHECK (
        octet_length(result_key) = 32
        AND (
          (result_purged_at IS NULL
           AND octet_length(result_digest) = 32
           AND (
             (result_digest_version IS NULL AND result_digest_key_tag IS NULL)
             OR
             (result_digest_version = 1
              AND result_digest_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$')
           ))
          OR
          (result_purged_at IS NOT NULL
           AND result_digest IS NULL
           AND result_digest_version IS NULL
           AND result_digest_key_tag IS NULL)
        )
        AND (
          (result_purged_at IS NULL
           AND result_content_digest IS NULL
           AND result_content_digest_version IS NULL)
          OR
          (result_purged_at IS NOT NULL
           AND octet_length(result_content_digest) = 32
           AND result_content_digest_version = 0)
        )
      ) NOT VALID
    """)

    execute_compatible("""
    ALTER TABLE public.agent_work_results
      VALIDATE CONSTRAINT agent_work_results_digest_check
    """)
  end

  defp attest_operational_privacy_protocol do
    execute_compatible("""
    CREATE TABLE IF NOT EXISTS public.privacy_protocol_manifests (
      name varchar(80) PRIMARY KEY,
      migration_version bigint NOT NULL,
      function_fingerprints jsonb NOT NULL,
      trigger_fingerprints jsonb NOT NULL,
      catalog_fingerprints jsonb NOT NULL,
      manifest_digest bytea NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_protocol_manifests_singleton_check CHECK (
        name = 'operational_privacy_140007'
        AND migration_version = 20260810140007
        AND jsonb_typeof(function_fingerprints) = 'object'
        AND jsonb_typeof(trigger_fingerprints) = 'object'
        AND jsonb_typeof(catalog_fingerprints) = 'object'
        AND octet_length(manifest_digest) = 32
      )
    )
    """)

    execute_compatible("""
    ALTER TABLE public.privacy_protocol_manifests
      ADD COLUMN IF NOT EXISTS catalog_fingerprints jsonb NOT NULL DEFAULT '{}'::jsonb
    """)

    execute_compatible("""
    ALTER TABLE public.privacy_protocol_manifests
      ADD COLUMN IF NOT EXISTS manifest_digest bytea NOT NULL
      DEFAULT decode(repeat('00', 32), 'hex')
    """)

    add_constraint_unless_present(
      "privacy_protocol_manifests",
      "privacy_protocol_manifests_catalog_shape_v2",
      "CHECK (jsonb_typeof(catalog_fingerprints) = 'object' " <>
        "AND octet_length(manifest_digest) = 32)"
    )

    execute_compatible("""
    CREATE OR REPLACE FUNCTION public.privacy_protocol_catalog_ready()
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $privacy$
    DECLARE
      stored_functions jsonb;
      stored_triggers jsonb;
      stored_catalogs jsonb;
      stored_digest bytea;
      live_functions jsonb;
      live_triggers jsonb;
      live_catalogs jsonb;
    BEGIN
      SELECT function_fingerprints, trigger_fingerprints, catalog_fingerprints,
             manifest_digest
      INTO STRICT stored_functions, stored_triggers, stored_catalogs, stored_digest
      FROM public.privacy_protocol_manifests
      WHERE name = 'operational_privacy_140007'
        AND migration_version = 20260810140007;

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

      RETURN (SELECT count(*) FROM pg_catalog.jsonb_object_keys(stored_functions)) = 11
        AND (SELECT count(*) FROM pg_catalog.jsonb_object_keys(stored_triggers)) = 48
        AND (SELECT count(*) FROM pg_catalog.jsonb_object_keys(stored_catalogs)) = 47
        AND live_functions = stored_functions
        AND live_triggers = stored_triggers
        AND live_catalogs = stored_catalogs
        AND stored_digest = public.digest(pg_catalog.convert_to(
          pg_catalog.jsonb_build_object(
            'functions', stored_functions,
            'triggers', stored_triggers,
            'catalogs', stored_catalogs
          )::text, 'UTF8'), 'sha256')
        AND (
          SELECT count(DISTINCT version) = 10
          FROM public.schema_migrations
          WHERE version IN (20260810132102, 20260810132103, 20260810140000, 20260810140001, 20260810140002, 20260810140003, 20260810140004, 20260810140005, 20260810140006, 20260810140007)
        );
    EXCEPTION WHEN no_data_found OR undefined_table OR undefined_function THEN
      RETURN false;
    END;
    $privacy$;
    """)

    execute_compatible("""
    CREATE OR REPLACE FUNCTION public.enforce_operational_privacy_activation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $privacy$
    DECLARE
      migrations_ready boolean;
      functions_ready bigint;
      retention_triggers_ready bigint;
      source_triggers_ready bigint;
      erasure_triggers_ready bigint;
      runtime_mode text;
    BEGIN
      IF OLD.mode = 'legacy' AND NEW.mode = 'generation_fenced_v1' THEN
        SELECT mode INTO STRICT runtime_mode
        FROM public.runtime_coordination_protocols
        WHERE name = 'runtime';

        IF runtime_mode <> 'dark' THEN
          RAISE EXCEPTION 'Exact Effect activation requires a dark runtime protocol'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT COUNT(*) = 10 INTO migrations_ready
        FROM public.schema_migrations
        WHERE version IN (20260810132102, 20260810132103, 20260810140000, 20260810140001, 20260810140002, 20260810140003, 20260810140004, 20260810140005, 20260810140006, 20260810140007);

        IF NOT migrations_ready THEN
          RAISE EXCEPTION 'Exact activation requires recorded privacy migrations through 140007'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NOT public.runtime_coordination_roles_ready() OR
           NOT public.runtime_coordination_acl_ready() OR
           public.runtime_coordination_catalog_ready_count() <> 120 OR
           NOT public.durable_payload_roles_ready() OR
           NOT public.durable_payload_catalog_ready() OR
           NOT public.privacy_protocol_catalog_ready() OR
           NOT EXISTS (
             SELECT 1
             FROM public.runtime_coordination_protocols AS protocol
             JOIN public.runtime_coordination_manifests AS manifest
               ON manifest.name = protocol.name
             WHERE protocol.name = 'runtime'
               AND protocol.manifest_digest = public.digest(pg_catalog.convert_to(
                 pg_catalog.jsonb_build_object(
                   'constraints', manifest.constraint_fingerprints,
                   'functions', manifest.function_fingerprints,
                   'triggers', manifest.trigger_fingerprints,
                   'indexes', manifest.index_fingerprints,
                   'catalogs', manifest.catalog_fingerprints
                 )::text, 'UTF8'), 'sha256')
           ) THEN
          RAISE EXCEPTION 'Exact activation requires unified runtime, payload, and privacy catalog authority'
            USING ERRCODE = 'check_violation';
        END IF;

        WITH required(function_id, expected_security_definer) AS (
          VALUES
            ('public.enforce_effect_execution_protocol()'::regprocedure, false),
            ('public.enforce_agent_directive_protocol()'::regprocedure, false),
            ('public.enforce_conversation_privacy_protocol()'::regprocedure, false),
            ('public.enforce_operational_privacy_retention()'::regprocedure, false),
            ('public.guard_agent_work_result_transition()'::regprocedure, false),
            ('public.enforce_privacy_erasure_write_fence()'::regprocedure, true),
            ('public.enforce_operational_privacy_activation()'::regprocedure, false)
        )
        SELECT COUNT(*) INTO functions_ready
        FROM required
        JOIN pg_catalog.pg_proc AS function_row
          ON function_row.oid = required.function_id
         AND function_row.provolatile = 'v'
         AND function_row.prosecdef = required.expected_security_definer
         AND function_row.proconfig = ARRAY['search_path=pg_catalog, public']::text[]
        JOIN pg_catalog.pg_language AS language_row
          ON language_row.oid = function_row.prolang
         AND language_row.lanname = 'plpgsql'
        JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner
        JOIN public.privacy_protocol_manifests AS manifest
          ON manifest.name = 'operational_privacy_140007'
         AND manifest.migration_version = 20260810140007
         AND manifest.function_fingerprints ->> function_row.oid::regprocedure::text =
               pg_catalog.encode(public.digest(pg_catalog.convert_to(
                 pg_catalog.jsonb_build_object(
                   'definition', pg_catalog.pg_get_functiondef(function_row.oid),
                   'owner', owner_row.rolname,
                   'acl', function_row.proacl
                 )::text, 'UTF8'), 'sha256'), 'hex');

        IF functions_ready <> 7 THEN
          RAISE EXCEPTION 'Exact activation requires attested privacy functions'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT COUNT(*) INTO retention_triggers_ready
        FROM pg_catalog.pg_trigger AS trigger_row
        JOIN pg_catalog.pg_proc AS function_row
          ON function_row.oid = trigger_row.tgfoid
        JOIN public.privacy_protocol_manifests AS manifest
          ON manifest.name = 'operational_privacy_140007'
         AND manifest.trigger_fingerprints ->>
               ('public.' || trigger_row.tgrelid::regclass::text || '.' || trigger_row.tgname) =
               pg_catalog.encode(public.digest(pg_catalog.convert_to(
                 pg_catalog.jsonb_build_object(
                   'definition', pg_catalog.pg_get_triggerdef(trigger_row.oid, true),
                   'enabled', trigger_row.tgenabled,
                   'type', trigger_row.tgtype,
                   'function', trigger_row.tgfoid::regprocedure::text
                 )::text, 'UTF8'), 'sha256'), 'hex')
        WHERE function_row.oid =
                'public.enforce_operational_privacy_retention()'::regprocedure
          AND NOT trigger_row.tgisinternal
          AND trigger_row.tgenabled IN ('O', 'A');

        IF retention_triggers_ready <> 15 THEN
          RAISE EXCEPTION 'Exact activation requires every operational retention trigger'
            USING ERRCODE = 'check_violation';
        END IF;

        WITH required(trigger_name, relation_id, function_id) AS (
          VALUES
            ('enforce_effect_execution_protocol_trigger', 'public.effects'::regclass,
             'public.enforce_effect_execution_protocol()'::regprocedure),
            ('enforce_agent_directive_protocol_trigger', 'public.agent_directives'::regclass,
             'public.enforce_agent_directive_protocol()'::regprocedure),
            ('enforce_telegram_conversation_turns_privacy_protocol',
             'public.telegram_conversation_turns'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_telegram_conversations_privacy_protocol',
             'public.telegram_conversations'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_telegram_assistant_runs_privacy_protocol',
             'public.telegram_assistant_runs'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_telegram_assistant_steps_privacy_protocol',
             'public.telegram_assistant_steps'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_telegram_prepared_actions_privacy_protocol',
             'public.telegram_prepared_actions'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_runtime_ingress_receipts_privacy_protocol',
             'public.runtime_ingress_receipts'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_agent_work_results_privacy_protocol',
             'public.agent_work_results'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_agent_runs_privacy_protocol', 'public.agent_runs'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_operator_events_privacy_protocol', 'public.operator_events'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_user_memory_profiles_privacy_protocol',
             'public.user_memory_profiles'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_operator_memory_summaries_privacy_protocol',
             'public.operator_memory_summaries'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_background_jobs_privacy_protocol', 'public.background_jobs'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('enforce_scheduled_jobs_privacy_protocol', 'public.scheduled_jobs'::regclass,
             'public.enforce_conversation_privacy_protocol()'::regprocedure)
        )
        SELECT COUNT(*) INTO source_triggers_ready
        FROM required
        JOIN pg_catalog.pg_trigger AS trigger_row
          ON trigger_row.tgname = required.trigger_name
         AND trigger_row.tgrelid = required.relation_id
         AND trigger_row.tgfoid = required.function_id
         AND NOT trigger_row.tgisinternal
         AND trigger_row.tgenabled IN ('O', 'A')
        JOIN public.privacy_protocol_manifests AS manifest
          ON manifest.name = 'operational_privacy_140007'
         AND manifest.trigger_fingerprints ->>
               ('public.' || trigger_row.tgrelid::regclass::text || '.' || trigger_row.tgname) =
               pg_catalog.encode(public.digest(pg_catalog.convert_to(
                 pg_catalog.jsonb_build_object(
                   'definition', pg_catalog.pg_get_triggerdef(trigger_row.oid, true),
                   'enabled', trigger_row.tgenabled,
                   'type', trigger_row.tgtype,
                   'function', trigger_row.tgfoid::regprocedure::text
                 )::text, 'UTF8'), 'sha256'), 'hex');

        IF source_triggers_ready <> 15 THEN
          RAISE EXCEPTION 'Exact activation requires every encrypted-source guard'
            USING ERRCODE = 'check_violation';
        END IF;

        WITH required(trigger_name, relation_id) AS (
          VALUES
            ('enforce_users_privacy_erasure_write_fence', 'public.users'::regclass),
            ('enforce_agents_privacy_erasure_write_fence', 'public.agents'::regclass),
            ('enforce_oauth_tokens_privacy_erasure_write_fence',
             'public.oauth_tokens'::regclass),
            ('enforce_connected_accounts_privacy_erasure_write_fence',
             'public.connected_accounts'::regclass),
            ('enforce_user_sessions_privacy_erasure_write_fence',
             'public.user_sessions'::regclass),
            ('enforce_user_magic_links_privacy_erasure_write_fence',
             'public.user_magic_links'::regclass),
            ('enforce_companion_devices_privacy_erasure_write_fence',
             'public.companion_devices'::regclass),
            ('enforce_companion_device_keys_privacy_erasure_write_fence',
             'public.companion_device_keys'::regclass),
            ('enforce_mobile_node_pairings_privacy_erasure_write_fence',
             'public.mobile_node_pairings'::regclass),
            ('enforce_mobile_node_devices_privacy_erasure_write_fence',
             'public.mobile_node_devices'::regclass),
            ('enforce_mobile_push_devices_privacy_erasure_write_fence',
             'public.mobile_push_devices'::regclass),
            ('enforce_background_jobs_privacy_erasure_write_fence',
             'public.background_jobs'::regclass)
        )
        SELECT COUNT(*) INTO erasure_triggers_ready
        FROM required
        JOIN pg_catalog.pg_trigger AS trigger_row
          ON trigger_row.tgname = required.trigger_name
         AND trigger_row.tgrelid = required.relation_id
         AND trigger_row.tgfoid =
               'public.enforce_privacy_erasure_write_fence()'::regprocedure
         AND NOT trigger_row.tgisinternal
         AND trigger_row.tgenabled IN ('O', 'A')
        JOIN public.privacy_protocol_manifests AS manifest
          ON manifest.name = 'operational_privacy_140007'
         AND manifest.trigger_fingerprints ->>
               ('public.' || trigger_row.tgrelid::regclass::text || '.' || trigger_row.tgname) =
               pg_catalog.encode(public.digest(pg_catalog.convert_to(
                 pg_catalog.jsonb_build_object(
                   'definition', pg_catalog.pg_get_triggerdef(trigger_row.oid, true),
                   'enabled', trigger_row.tgenabled,
                   'type', trigger_row.tgtype,
                   'function', trigger_row.tgfoid::regprocedure::text
                 )::text, 'UTF8'), 'sha256'), 'hex');

        IF erasure_triggers_ready <> 12 THEN
          RAISE EXCEPTION 'Exact activation requires every privacy erasure write fence'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $privacy$;
    """)

    execute_compatible("""
    CREATE OR REPLACE TRIGGER enforce_operational_privacy_activation_trigger
    BEFORE UPDATE ON public.effect_execution_protocols
    FOR EACH ROW EXECUTE FUNCTION public.enforce_operational_privacy_activation()
    """)

    execute_compatible("""
    CREATE OR REPLACE FUNCTION public.reject_privacy_protocol_manifest_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $privacy$
    BEGIN
      RAISE EXCEPTION 'Privacy protocol manifest is immutable'
        USING ERRCODE = 'check_violation';
    END;
    $privacy$;
    """)

    execute_compatible("""
    CREATE OR REPLACE TRIGGER reject_privacy_protocol_manifest_mutation_trigger
    BEFORE UPDATE OR DELETE ON public.privacy_protocol_manifests
    FOR EACH ROW EXECUTE FUNCTION public.reject_privacy_protocol_manifest_mutation()
    """)
  end

  defp attest_privacy_authority do
    execute_compatible("""
    DO $privacy_authority$
    BEGIN
      ALTER TABLE public.privacy_protocol_manifests OWNER TO maraithon_object_owner;
      ALTER TABLE public.privacy_retention_statuses OWNER TO maraithon_object_owner;
      ALTER TABLE public.privacy_erasure_requests OWNER TO maraithon_object_owner;
      ALTER TABLE public.privacy_erasure_agent_targets OWNER TO maraithon_object_owner;
      ALTER TABLE public.privacy_erasure_provider_revocations OWNER TO maraithon_object_owner;
      ALTER TABLE public.privacy_erasure_receipts OWNER TO maraithon_object_owner;
      ALTER TABLE public.privacy_erasure_job_deferral_receipts
        OWNER TO maraithon_object_owner;
      ALTER SEQUENCE public.privacy_erasure_agent_targets_id_seq
        OWNER TO maraithon_object_owner;
      ALTER SEQUENCE public.privacy_erasure_provider_revocations_id_seq
        OWNER TO maraithon_object_owner;

      REVOKE ALL ON TABLE
        public.privacy_protocol_manifests,
        public.privacy_retention_statuses,
        public.privacy_erasure_requests,
        public.privacy_erasure_agent_targets,
        public.privacy_erasure_provider_revocations,
        public.privacy_erasure_receipts,
        public.privacy_erasure_job_deferral_receipts
        FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier,
          maraithon_incident_operator, maraithon_activation_operator;

      REVOKE ALL ON SEQUENCE
        public.privacy_erasure_agent_targets_id_seq,
        public.privacy_erasure_provider_revocations_id_seq
        FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier,
          maraithon_incident_operator, maraithon_activation_operator;

      GRANT SELECT ON TABLE public.privacy_protocol_manifests
        TO maraithon_runtime, maraithon_activation_operator;
      GRANT SELECT ON TABLE public.privacy_erasure_requests
        TO maraithon_activation_operator;
      GRANT SELECT ON TABLE public.privacy_erasure_job_deferral_receipts
        TO maraithon_runtime, maraithon_activation_operator;
      GRANT USAGE, SELECT ON SEQUENCE
        public.privacy_erasure_agent_targets_id_seq,
        public.privacy_erasure_provider_revocations_id_seq
        TO maraithon_runtime;
      GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
        public.privacy_retention_statuses,
        public.privacy_erasure_requests,
        public.privacy_erasure_agent_targets,
        public.privacy_erasure_provider_revocations,
        public.privacy_erasure_receipts
        TO maraithon_runtime;

      REVOKE ALL PRIVILEGES ON TABLE public.users,
        public.agent_lifecycle_operations
        FROM maraithon_object_owner;
      REVOKE ALL PRIVILEGES
        (id, email, is_admin, confirmed_at, inserted_at, updated_at,
         privacy_erasure_requested_at)
        ON public.users FROM maraithon_object_owner;
      REVOKE ALL PRIVILEGES
        (agent_id, operation_token, kind, state, request_digest, payload_digest,
         payload, expected_owner_token, requires_external_drain,
         external_drain_confirmed_at, external_drain_evidence_digest,
         initiated_at, last_attempted_at, inserted_at, updated_at)
        ON public.agent_lifecycle_operations FROM maraithon_object_owner;
      GRANT SELECT (id, privacy_erasure_requested_at), UPDATE (id)
        ON public.users TO maraithon_object_owner;
      GRANT SELECT (agent_id, operation_token, kind, state, payload)
        ON public.agent_lifecycle_operations TO maraithon_object_owner;

      ALTER FUNCTION public.capture_privacy_erasure_job_deferral_receipt()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.reject_privacy_erasure_job_deferral_receipt_mutation()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.enforce_privacy_erasure_write_fence()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.enforce_effect_execution_protocol()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.enforce_agent_directive_protocol()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.enforce_conversation_privacy_protocol()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.enforce_operational_privacy_retention()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.guard_agent_work_result_transition()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.privacy_protocol_catalog_ready()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.enforce_operational_privacy_activation()
        OWNER TO maraithon_object_owner;
      ALTER FUNCTION public.reject_privacy_protocol_manifest_mutation()
        OWNER TO maraithon_object_owner;

      REVOKE ALL ON FUNCTION
        public.capture_privacy_erasure_job_deferral_receipt(),
        public.reject_privacy_erasure_job_deferral_receipt_mutation(),
        public.enforce_privacy_erasure_write_fence(),
        public.enforce_effect_execution_protocol(),
        public.enforce_agent_directive_protocol(),
        public.enforce_conversation_privacy_protocol(),
        public.enforce_operational_privacy_retention(),
        public.guard_agent_work_result_transition(),
        public.privacy_protocol_catalog_ready(),
        public.enforce_operational_privacy_activation(),
        public.reject_privacy_protocol_manifest_mutation()
        FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier,
          maraithon_incident_operator, maraithon_activation_operator;

      GRANT EXECUTE ON FUNCTION public.privacy_protocol_catalog_ready()
        TO maraithon_runtime, maraithon_incident_operator,
          maraithon_activation_operator;
    END;
    $privacy_authority$
    """)
  end

  defp refresh_privacy_manifest do
    execute_compatible("""
    DO $privacy_manifest_refresh$
    DECLARE
      mutation_trigger_present boolean;
      functions jsonb;
      triggers jsonb;
      prior_triggers jsonb;
      catalogs jsonb;
      digest_value bytea;
    BEGIN
      SELECT trigger_fingerprints
      INTO prior_triggers
      FROM public.privacy_protocol_manifests
      WHERE name = 'operational_privacy_140007'
        AND migration_version = 20260810140007;

      SELECT pg_catalog.jsonb_object_agg(
        function_row.oid::regprocedure::text,
        pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.jsonb_build_object(
            'definition', pg_catalog.pg_get_functiondef(function_row.oid),
            'owner', owner_row.rolname,
            'acl', function_row.proacl
          )::text, 'UTF8'), 'sha256'), 'hex')
        ORDER BY function_row.oid::regprocedure::text
      ) INTO STRICT functions
      FROM pg_catalog.pg_proc AS function_row
      JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner
      WHERE function_row.oid IN (
        'public.enforce_effect_execution_protocol()'::regprocedure,
        'public.enforce_agent_directive_protocol()'::regprocedure,
        'public.enforce_conversation_privacy_protocol()'::regprocedure,
        'public.enforce_operational_privacy_retention()'::regprocedure,
        'public.guard_agent_work_result_transition()'::regprocedure,
        'public.enforce_privacy_erasure_write_fence()'::regprocedure,
        'public.capture_privacy_erasure_job_deferral_receipt()'::regprocedure,
        'public.reject_privacy_erasure_job_deferral_receipt_mutation()'::regprocedure,
        'public.enforce_operational_privacy_activation()'::regprocedure,
        'public.privacy_protocol_catalog_ready()'::regprocedure,
        'public.reject_privacy_protocol_manifest_mutation()'::regprocedure
      );

      SELECT pg_catalog.jsonb_object_agg(
        'public.' || trigger_row.tgrelid::regclass::text || '.' || trigger_row.tgname,
        pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.jsonb_build_object(
            'definition', pg_catalog.pg_get_triggerdef(trigger_row.oid, true),
            'enabled', trigger_row.tgenabled,
            'type', trigger_row.tgtype,
            'function', trigger_row.tgfoid::regprocedure::text
          )::text, 'UTF8'), 'sha256'), 'hex')
        ORDER BY trigger_row.tgrelid::regclass::text, trigger_row.tgname
      ) INTO STRICT triggers
      FROM pg_catalog.pg_trigger AS trigger_row
      WHERE NOT trigger_row.tgisinternal
        AND trigger_row.tgfoid IN (
          'public.enforce_effect_execution_protocol()'::regprocedure,
          'public.enforce_agent_directive_protocol()'::regprocedure,
          'public.enforce_conversation_privacy_protocol()'::regprocedure,
          'public.enforce_operational_privacy_retention()'::regprocedure,
          'public.guard_agent_work_result_transition()'::regprocedure,
          'public.enforce_privacy_erasure_write_fence()'::regprocedure,
          'public.capture_privacy_erasure_job_deferral_receipt()'::regprocedure,
          'public.reject_privacy_erasure_job_deferral_receipt_mutation()'::regprocedure,
          'public.enforce_operational_privacy_activation()'::regprocedure,
          'public.reject_privacy_protocol_manifest_mutation()'::regprocedure
        );

      IF (SELECT count(*) FROM pg_catalog.jsonb_object_keys(triggers)) <> 48 OR
         NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_trigger AS trigger_row
           WHERE trigger_row.tgrelid = 'public.agent_work_results'::regclass
             AND trigger_row.tgname = 'agent_work_results_transition_guard'
             AND trigger_row.tgfoid =
                   'public.guard_agent_work_result_transition()'::regprocedure
             AND NOT trigger_row.tgisinternal
         ) OR NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_trigger AS trigger_row
           WHERE trigger_row.tgrelid = 'public.effect_execution_protocols'::regclass
             AND trigger_row.tgname = 'enforce_operational_privacy_activation_trigger'
             AND trigger_row.tgfoid =
                   'public.enforce_operational_privacy_activation()'::regprocedure
             AND NOT trigger_row.tgisinternal
         ) OR NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_trigger AS trigger_row
           WHERE trigger_row.tgrelid = 'public.privacy_protocol_manifests'::regclass
             AND trigger_row.tgname = 'reject_privacy_protocol_manifest_mutation_trigger'
             AND trigger_row.tgfoid =
                   'public.reject_privacy_protocol_manifest_mutation()'::regprocedure
             AND NOT trigger_row.tgisinternal
         ) OR NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_trigger AS trigger_row
           WHERE trigger_row.tgrelid = 'public.background_jobs'::regclass
             AND trigger_row.tgname =
                   'capture_privacy_erasure_job_deferral_receipt_trigger'
             AND trigger_row.tgfoid =
                   'public.capture_privacy_erasure_job_deferral_receipt()'::regprocedure
             AND trigger_row.tgenabled = 'A'
             AND NOT trigger_row.tgisinternal
         ) OR NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_trigger AS trigger_row
           WHERE trigger_row.tgrelid =
                   'public.privacy_erasure_job_deferral_receipts'::regclass
             AND trigger_row.tgname =
                   'reject_privacy_erasure_job_deferral_receipt_mutation_trigger'
             AND trigger_row.tgfoid =
                   'public.reject_privacy_erasure_job_deferral_receipt_mutation()'::regprocedure
             AND trigger_row.tgenabled = 'A'
             AND NOT trigger_row.tgisinternal
         ) OR NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_trigger AS trigger_row
           WHERE trigger_row.tgrelid =
                   'public.privacy_erasure_job_deferral_receipts'::regclass
             AND trigger_row.tgname =
                   'reject_privacy_erasure_job_deferral_receipt_truncate_trigger'
             AND trigger_row.tgfoid =
                   'public.reject_privacy_erasure_job_deferral_receipt_mutation()'::regprocedure
             AND trigger_row.tgenabled = 'A'
             AND NOT trigger_row.tgisinternal
         ) THEN
        RAISE EXCEPTION 'Privacy manifest contains an unexpected authority trigger set'
          USING ERRCODE = 'check_violation';
      END IF;

      IF prior_triggers IS NOT NULL AND EXISTS (
           SELECT 1
           FROM pg_catalog.jsonb_object_keys(prior_triggers) AS prior_key(key_name)
           WHERE prior_key.key_name LIKE 'public.%'
         ) AND EXISTS (
           SELECT 1
           FROM pg_catalog.jsonb_object_keys(triggers) AS current_key(key_name)
           WHERE NOT prior_triggers ? current_key.key_name
             AND current_key.key_name NOT IN (
               'public.background_jobs.' ||
                 'capture_privacy_erasure_job_deferral_receipt_trigger',
               'public.privacy_erasure_job_deferral_receipts.' ||
                 'reject_privacy_erasure_job_deferral_receipt_mutation_trigger',
               'public.privacy_erasure_job_deferral_receipts.' ||
                 'reject_privacy_erasure_job_deferral_receipt_truncate_trigger'
             )
         ) THEN
        RAISE EXCEPTION 'Privacy manifest contains an unexpected authority trigger'
          USING ERRCODE = 'check_violation';
      END IF;

      WITH required(relation_name) AS (
        VALUES
            ('privacy_protocol_manifests'),
            ('privacy_retention_statuses'),
            ('privacy_erasure_requests'),
            ('privacy_erasure_agent_targets'),
            ('privacy_erasure_provider_revocations'),
            ('privacy_erasure_receipts'),
            ('privacy_erasure_job_deferral_receipts'),
            ('privacy_erasure_agent_targets_id_seq'),
            ('privacy_erasure_provider_revocations_id_seq'),
            ('effect_execution_protocols'),
            ('schema_migrations'),
            ('users'),
            ('agents'),
            ('oauth_tokens'),
            ('connected_accounts'),
            ('user_sessions'),
            ('user_magic_links'),
            ('companion_devices'),
            ('companion_device_keys'),
            ('mobile_node_pairings'),
            ('mobile_node_devices'),
            ('mobile_push_devices'),
            ('effects'),
            ('agent_directives'),
            ('events'),
            ('agent_run_steps'),
            ('telegram_conversation_turns'),
            ('telegram_conversations'),
            ('telegram_assistant_runs'),
            ('telegram_assistant_steps'),
            ('telegram_prepared_actions'),
            ('agent_runs'),
            ('operator_events'),
            ('user_memory_profiles'),
            ('operator_memory_summaries'),
            ('background_jobs'),
            ('scheduled_jobs'),
            ('runtime_ingress_receipts'),
            ('snapshots'),
            ('agent_work_results'),
            ('agent_work_result_acquisitions'),
            ('chief_acquisition_envelopes'),
            ('chief_projection_receipts'),
            ('project_repo_grants'),
            ('todos')
      ), relations AS (
        SELECT pg_catalog.jsonb_object_agg(
          required.relation_name,
          public.runtime_catalog_table_fingerprint(
            pg_catalog.to_regclass('public.' || required.relation_name)
          ) ORDER BY required.relation_name
        ) AS value
        FROM required
      ), schema_authority AS (
        SELECT pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.jsonb_build_object(
            'owner', owner_row.rolname,
            'acl', namespace.nspacl
          )::text, 'UTF8'), 'sha256'), 'hex') AS value
        FROM pg_catalog.pg_namespace AS namespace
        JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = namespace.nspowner
        WHERE namespace.nspname = 'public'
      )
      SELECT relations.value || pg_catalog.jsonb_build_object(
        'role_topology', public.runtime_role_topology_fingerprint(),
        'schema_authority', schema_authority.value
      ) INTO STRICT catalogs
      FROM relations, schema_authority;

      IF EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_object_keys(catalogs) AS catalog_key(key_name)
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
        RAISE EXCEPTION 'Privacy manifest contains an unknown column ACL grantee'
          USING ERRCODE = 'check_violation';
      END IF;

      digest_value := public.digest(pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'functions', functions,
          'triggers', triggers,
          'catalogs', catalogs
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

      INSERT INTO public.privacy_protocol_manifests (
        name, migration_version, function_fingerprints, trigger_fingerprints,
        catalog_fingerprints, manifest_digest, inserted_at, updated_at
      ) VALUES (
        'operational_privacy_140007', 20260810140007, functions, triggers,
        catalogs, digest_value,
        timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
      )
      ON CONFLICT (name) DO UPDATE SET
        migration_version = EXCLUDED.migration_version,
        function_fingerprints = EXCLUDED.function_fingerprints,
        trigger_fingerprints = EXCLUDED.trigger_fingerprints,
        catalog_fingerprints = EXCLUDED.catalog_fingerprints,
        manifest_digest = EXCLUDED.manifest_digest,
        updated_at = EXCLUDED.updated_at;

      IF mutation_trigger_present THEN
        ALTER TABLE public.privacy_protocol_manifests
          ENABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF mutation_trigger_present THEN
        ALTER TABLE public.privacy_protocol_manifests
          ENABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger;
      END IF;
      RAISE;
    END;
    $privacy_manifest_refresh$
    """)
  end

  defp refresh_effect_manifest do
    execute_compatible("""
    DO $effect_manifest_refresh$
    DECLARE
      mutation_trigger_present boolean;
      functions jsonb;
      constraints jsonb;
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM public.effect_execution_protocol_manifests AS manifest
        CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.function_fingerprints)
          AS keys(key_name)
        WHERE manifest.name = 'effects'
          AND (SELECT count(*)
               FROM pg_catalog.pg_proc AS function_row
               JOIN pg_catalog.pg_namespace AS namespace
                 ON namespace.oid = function_row.pronamespace
                AND namespace.nspname = 'public'
               WHERE function_row.proname = keys.key_name) <> 1
      ) OR EXISTS (
        SELECT 1
        FROM public.effect_execution_protocol_manifests AS manifest
        CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.constraint_fingerprints)
          AS keys(key_name)
        WHERE manifest.name = 'effects'
          AND (SELECT count(*)
               FROM pg_catalog.pg_constraint AS constraint_row
               JOIN pg_catalog.pg_class AS relation ON relation.oid = constraint_row.conrelid
               JOIN pg_catalog.pg_namespace AS namespace
                 ON namespace.oid = relation.relnamespace
                AND namespace.nspname = 'public'
               WHERE constraint_row.conname = keys.key_name) <> 1
      ) THEN
        RAISE EXCEPTION 'Effect manifest contains ambiguous catalog object names'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT pg_catalog.jsonb_object_agg(
        key_name, pg_catalog.md5(function_row.prosrc) ORDER BY key_name
      ) INTO STRICT functions
      FROM public.effect_execution_protocol_manifests AS manifest
      CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.function_fingerprints)
        AS keys(key_name)
      JOIN pg_catalog.pg_proc AS function_row ON function_row.proname = key_name
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = function_row.pronamespace AND namespace.nspname = 'public'
      WHERE manifest.name = 'effects';

      SELECT pg_catalog.jsonb_object_agg(
        key_name,
        pg_catalog.md5(pg_catalog.pg_get_constraintdef(constraint_row.oid, true))
        ORDER BY key_name
      ) INTO STRICT constraints
      FROM public.effect_execution_protocol_manifests AS manifest
      CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.constraint_fingerprints)
        AS keys(key_name)
      JOIN pg_catalog.pg_constraint AS constraint_row ON constraint_row.conname = key_name
      JOIN pg_catalog.pg_class AS relation ON relation.oid = constraint_row.conrelid
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = relation.relnamespace AND namespace.nspname = 'public'
      WHERE manifest.name = 'effects';

      SELECT EXISTS (
        SELECT 1 FROM pg_catalog.pg_trigger
        WHERE tgrelid = 'public.effect_execution_protocol_manifests'::regclass
          AND tgname = 'reject_effect_protocol_manifest_mutation_trigger'
          AND NOT tgisinternal
      ) INTO mutation_trigger_present;

      IF mutation_trigger_present THEN
        ALTER TABLE public.effect_execution_protocol_manifests
          DISABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger;
      END IF;

      UPDATE public.effect_execution_protocol_manifests
      SET function_fingerprints = functions,
          constraint_fingerprints = constraints,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'effects';

      IF mutation_trigger_present THEN
        ALTER TABLE public.effect_execution_protocol_manifests
          ENABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF mutation_trigger_present THEN
        ALTER TABLE public.effect_execution_protocol_manifests
          ENABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger;
      END IF;
      RAISE;
    END;
    $effect_manifest_refresh$
    """)
  end

  defp refresh_runtime_manifest do
    execute_compatible("""
    DO $runtime_manifest_refresh$
    DECLARE
      runtime_mode text;
      effect_mode text;
      functions jsonb;
      constraints jsonb;
      triggers jsonb;
      indexes jsonb;
      catalogs jsonb;
      digest_value bytea;
    BEGIN
      SELECT mode INTO STRICT runtime_mode
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime'
      FOR SHARE;

      SELECT mode INTO STRICT effect_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF runtime_mode <> 'dark' OR effect_mode <> 'legacy' THEN
        RAISE EXCEPTION 'Runtime manifest refresh requires the feature-dark legacy pair'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM public.runtime_coordination_manifests AS manifest
        CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.function_fingerprints)
          AS keys(key_name)
        WHERE manifest.name = 'runtime'
          AND (SELECT count(*)
               FROM pg_catalog.pg_proc AS object_row
               JOIN pg_catalog.pg_namespace AS namespace
                 ON namespace.oid = object_row.pronamespace
                AND namespace.nspname = 'public'
               WHERE object_row.proname = keys.key_name) <> 1
      ) OR EXISTS (
        SELECT 1
        FROM public.runtime_coordination_manifests AS manifest
        CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.constraint_fingerprints)
          AS keys(key_name)
        WHERE manifest.name = 'runtime'
          AND (SELECT count(*)
               FROM pg_catalog.pg_constraint AS object_row
               JOIN pg_catalog.pg_class AS relation ON relation.oid = object_row.conrelid
               JOIN pg_catalog.pg_namespace AS namespace
                 ON namespace.oid = relation.relnamespace
                AND namespace.nspname = 'public'
               WHERE object_row.conname = keys.key_name) <> 1
      ) OR EXISTS (
        SELECT 1
        FROM public.runtime_coordination_manifests AS manifest
        CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.trigger_fingerprints)
          AS keys(key_name)
        WHERE manifest.name = 'runtime'
          AND (SELECT count(*)
               FROM pg_catalog.pg_trigger AS object_row
               JOIN pg_catalog.pg_class AS relation ON relation.oid = object_row.tgrelid
               JOIN pg_catalog.pg_namespace AS namespace
                 ON namespace.oid = relation.relnamespace
                AND namespace.nspname = 'public'
               WHERE object_row.tgname = keys.key_name
                 AND NOT object_row.tgisinternal) <> 1
      ) OR EXISTS (
        SELECT 1
        FROM public.runtime_coordination_manifests AS manifest
        CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.index_fingerprints)
          AS keys(key_name)
        WHERE manifest.name = 'runtime'
          AND (SELECT count(*)
               FROM pg_catalog.pg_class AS object_row
               JOIN pg_catalog.pg_namespace AS namespace
                 ON namespace.oid = object_row.relnamespace
                AND namespace.nspname = 'public'
               WHERE object_row.relname = keys.key_name
                 AND object_row.relkind = 'i') <> 1
      ) THEN
        RAISE EXCEPTION 'Runtime manifest contains ambiguous catalog object names'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT pg_catalog.jsonb_object_agg(
        key_name,
        pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.jsonb_build_object(
            'definition', pg_catalog.pg_get_functiondef(function_row.oid),
            'owner', owner_row.rolname,
            'acl', function_row.proacl
          )::text, 'UTF8'), 'sha256'), 'hex')
        ORDER BY key_name
      ) INTO STRICT functions
      FROM public.runtime_coordination_manifests AS manifest
      CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.function_fingerprints)
        AS keys(key_name)
      JOIN pg_catalog.pg_proc AS function_row ON function_row.proname = key_name
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = function_row.pronamespace AND namespace.nspname = 'public'
      JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner
      WHERE manifest.name = 'runtime';

      SELECT pg_catalog.jsonb_object_agg(
        required.key_name,
        pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.regexp_replace(
            pg_catalog.pg_get_constraintdef(constraint_row.oid, true),
            ' NOT VALID$', ''
          ), 'UTF8'), 'sha256'), 'hex')
        ORDER BY required.key_name
      ) INTO STRICT constraints
      FROM (
        SELECT keys.key_name
        FROM public.runtime_coordination_manifests AS manifest
        CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.constraint_fingerprints)
          AS keys(key_name)
        WHERE manifest.name = 'runtime'
        UNION
        SELECT 'agent_runtime_leases_termination_capability_digest_shape'
      ) AS required(key_name)
      JOIN pg_catalog.pg_constraint AS constraint_row
        ON constraint_row.conname = required.key_name
       AND (required.key_name <>
              'agent_runtime_leases_termination_capability_digest_shape' OR
            constraint_row.conrelid = 'public.agent_runtime_leases'::regclass)
      JOIN pg_catalog.pg_class AS relation ON relation.oid = constraint_row.conrelid
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = relation.relnamespace AND namespace.nspname = 'public';

      SELECT pg_catalog.jsonb_object_agg(
        key_name,
        pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.pg_get_triggerdef(trigger_row.oid, true),
          'UTF8'), 'sha256'), 'hex')
        ORDER BY key_name
      ) INTO STRICT triggers
      FROM public.runtime_coordination_manifests AS manifest
      CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.trigger_fingerprints)
        AS keys(key_name)
      JOIN pg_catalog.pg_trigger AS trigger_row
        ON trigger_row.tgname = key_name AND NOT trigger_row.tgisinternal
      JOIN pg_catalog.pg_class AS relation ON relation.oid = trigger_row.tgrelid
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = relation.relnamespace AND namespace.nspname = 'public'
      WHERE manifest.name = 'runtime';

      SELECT pg_catalog.jsonb_object_agg(
        key_name,
        pg_catalog.encode(public.digest(pg_catalog.convert_to(
          pg_catalog.jsonb_build_object(
            'definition', pg_catalog.pg_get_indexdef(index_relation.oid),
            'owner', owner_row.rolname,
            'acl', index_relation.relacl
          )::text, 'UTF8'), 'sha256'), 'hex')
        ORDER BY key_name
      ) INTO STRICT indexes
      FROM public.runtime_coordination_manifests AS manifest
      CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.index_fingerprints)
        AS keys(key_name)
      JOIN pg_catalog.pg_class AS index_relation ON index_relation.relname = key_name
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = index_relation.relnamespace AND namespace.nspname = 'public'
      JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = index_relation.relowner
      WHERE manifest.name = 'runtime';

      SELECT pg_catalog.jsonb_object_agg(
        key_name,
        CASE key_name
          WHEN 'role_topology' THEN public.runtime_role_topology_fingerprint()
          ELSE public.runtime_catalog_table_fingerprint(
            pg_catalog.to_regclass('public.' || key_name)
          )
        END
        ORDER BY key_name
      ) INTO STRICT catalogs
      FROM public.runtime_coordination_manifests AS manifest
      CROSS JOIN LATERAL pg_catalog.jsonb_object_keys(manifest.catalog_fingerprints)
        AS keys(key_name)
      WHERE manifest.name = 'runtime';

      IF functions IS NULL OR constraints IS NULL OR triggers IS NULL OR
         indexes IS NULL OR catalogs IS NULL THEN
        RAISE EXCEPTION 'Runtime manifest refresh could not resolve every required object'
          USING ERRCODE = 'check_violation';
      END IF;

      ALTER TABLE public.runtime_coordination_manifests
        DISABLE TRIGGER reject_runtime_coordination_manifests_mutation_trigger;
      ALTER TABLE public.runtime_coordination_protocols
        DISABLE TRIGGER enforce_runtime_coordination_protocol_trigger;

      UPDATE public.runtime_coordination_manifests
      SET function_fingerprints = functions,
          constraint_fingerprints = constraints,
          trigger_fingerprints = triggers,
          index_fingerprints = indexes,
          catalog_fingerprints = catalogs,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'runtime';

      SELECT public.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
        'constraints', constraints,
        'functions', functions,
        'triggers', triggers,
        'indexes', indexes,
        'catalogs', catalogs
      )::text, 'UTF8'), 'sha256') INTO digest_value;

      UPDATE public.runtime_coordination_protocols
      SET manifest_digest = digest_value,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'runtime' AND mode = 'dark';

      ALTER TABLE public.runtime_coordination_protocols
        ENABLE TRIGGER enforce_runtime_coordination_protocol_trigger;
      ALTER TABLE public.runtime_coordination_manifests
        ENABLE TRIGGER reject_runtime_coordination_manifests_mutation_trigger;
    EXCEPTION WHEN OTHERS THEN
      ALTER TABLE public.runtime_coordination_protocols
        ENABLE TRIGGER enforce_runtime_coordination_protocol_trigger;
      ALTER TABLE public.runtime_coordination_manifests
        ENABLE TRIGGER reject_runtime_coordination_manifests_mutation_trigger;
      RAISE;
    END;
    $runtime_manifest_refresh$
    """)
  end

  defp create_privacy_retention_statuses do
    execute_compatible("""
    CREATE TABLE IF NOT EXISTS privacy_retention_statuses (
      handler varchar(80) PRIMARY KEY,
      tenant_cursor varchar(320),
      backlog_count bigint NOT NULL DEFAULT 0,
      oldest_age_seconds bigint NOT NULL DEFAULT 0,
      consecutive_failures integer NOT NULL DEFAULT 0,
      alert_state varchar(16) NOT NULL DEFAULT 'ok',
      last_error_code varchar(128),
      last_started_at timestamp(6) without time zone,
      last_finished_at timestamp(6) without time zone,
      last_succeeded_at timestamp(6) without time zone,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_retention_statuses_shape_check CHECK (
        octet_length(handler) BETWEEN 1 AND 80
        AND backlog_count >= 0
        AND oldest_age_seconds >= 0
        AND consecutive_failures >= 0
        AND alert_state IN ('ok', 'warning', 'critical')
        AND (last_error_code IS NULL OR last_error_code ~ '^[a-z0-9_]{1,128}$')
      )
    )
    """)
  end

  defp create_privacy_erasure_requests do
    execute_compatible("""
    CREATE TABLE IF NOT EXISTS privacy_erasure_requests (
      id uuid PRIMARY KEY,
      scope varchar(16) NOT NULL,
      subject_user_id varchar(320),
      subject_agent_id uuid,
      idempotency_digest bytea,
      state varchar(32) NOT NULL DEFAULT 'requested',
      blocker_code varchar(128),
      target_agent_count integer NOT NULL DEFAULT 0,
      credentials_locally_revoked boolean NOT NULL DEFAULT false,
      provider_revocation_override boolean NOT NULL DEFAULT false,
      claim_token uuid,
      claimed_at timestamp(6) without time zone,
      claim_expires_at timestamp(6) without time zone,
      requested_at timestamp(6) without time zone NOT NULL,
      last_attempted_at timestamp(6) without time zone,
      completed_at timestamp(6) without time zone,
      expires_at timestamp(6) without time zone,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_erasure_requests_shape_check CHECK (
        scope IN ('user', 'agent')
        AND state IN ('requested', 'draining', 'revoking_credentials', 'erasing', 'completed')
        AND target_agent_count >= 0
        AND (idempotency_digest IS NULL OR octet_length(idempotency_digest) = 32)
        AND (blocker_code IS NULL OR blocker_code ~ '^[a-z0-9_]{1,128}$')
        AND ((claim_token IS NULL AND claimed_at IS NULL AND claim_expires_at IS NULL)
             OR (claim_token IS NOT NULL AND claimed_at IS NOT NULL
                 AND claim_expires_at IS NOT NULL AND claim_expires_at > claimed_at))
        AND ((state = 'completed' AND completed_at IS NOT NULL AND expires_at IS NOT NULL
              AND subject_user_id IS NULL AND subject_agent_id IS NULL
              AND idempotency_digest IS NULL)
             OR state <> 'completed')
      )
    )
    """)
  end

  defp create_privacy_erasure_agent_targets do
    execute_compatible("""
    CREATE TABLE IF NOT EXISTS privacy_erasure_agent_targets (
      id bigserial PRIMARY KEY,
      request_id uuid NOT NULL,
      agent_id uuid NOT NULL,
      state varchar(24) NOT NULL DEFAULT 'pending',
      blocker_code varchar(128),
      last_attempted_at timestamp(6) without time zone,
      drained_at timestamp(6) without time zone,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_erasure_agent_targets_shape_check CHECK (
        state IN ('pending', 'draining', 'drained', 'erasing')
        AND (blocker_code IS NULL OR blocker_code ~ '^[a-z0-9_]{1,128}$')
      ),
      CONSTRAINT privacy_erasure_agent_targets_request_id_fkey
        FOREIGN KEY (request_id) REFERENCES privacy_erasure_requests(id) ON DELETE CASCADE
    )
    """)
  end

  defp create_privacy_erasure_provider_revocations do
    execute_compatible("""
    CREATE TABLE IF NOT EXISTS privacy_erasure_provider_revocations (
      id bigserial PRIMARY KEY,
      request_id uuid NOT NULL,
      credential_table varchar(32) NOT NULL,
      credential_row_id bigint NOT NULL,
      provider_code varchar(80) NOT NULL,
      state varchar(24) NOT NULL DEFAULT 'pending',
      attempt_count integer NOT NULL DEFAULT 0,
      error_code varchar(128),
      last_attempted_at timestamp(6) without time zone,
      completed_at timestamp(6) without time zone,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_erasure_provider_revocations_request_id_fkey
        FOREIGN KEY (request_id) REFERENCES privacy_erasure_requests(id) ON DELETE CASCADE
    )
    """)
  end

  defp create_privacy_erasure_receipts do
    execute_compatible("""
    CREATE TABLE IF NOT EXISTS privacy_erasure_receipts (
      id uuid PRIMARY KEY,
      request_id uuid NOT NULL,
      classification varchar(64) NOT NULL,
      scope varchar(16) NOT NULL,
      outcome varchar(24) NOT NULL,
      local_data_deleted boolean NOT NULL,
      credentials_locally_revoked boolean NOT NULL,
      provider_revocation_outcome varchar(32) NOT NULL,
      erased_agent_count integer NOT NULL DEFAULT 0,
      issued_at timestamp(6) without time zone NOT NULL,
      expires_at timestamp(6) without time zone NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_erasure_receipts_shape_check CHECK (
        classification = 'content_free_erasure_authority_v1'
        AND scope IN ('user', 'agent')
        AND outcome = 'completed'
        AND provider_revocation_outcome IN ('confirmed', 'partial_unverified', 'not_applicable')
        AND erased_agent_count >= 0
        AND expires_at > issued_at
      ),
      CONSTRAINT privacy_erasure_receipts_request_id_fkey
        FOREIGN KEY (request_id) REFERENCES privacy_erasure_requests(id) ON DELETE CASCADE
    )
    """)
  end

  defp create_privacy_erasure_job_deferral_receipts do
    # These receipts deliberately have no foreign keys. Background jobs are
    # deleted by erasure completion, while this content-free contraction
    # authority must remain immutable and independently durable.
    execute_compatible("""
    CREATE TABLE IF NOT EXISTS public.privacy_erasure_job_deferral_receipts (
      job_id uuid PRIMARY KEY,
      request_id uuid NOT NULL,
      classification varchar(64) NOT NULL,
      queue varchar(80) NOT NULL,
      job_type varchar(160) NOT NULL,
      dedupe_key varchar(320) NOT NULL,
      established_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_erasure_job_deferral_receipts_shape_check CHECK (
        classification = 'privacy_erasure_job_deferral_v1'
        AND queue = 'privacy'
        AND job_type = 'privacy_erasure'
        AND dedupe_key = 'privacy-erasure:' || request_id::text
      )
    )
    """)

    execute_compatible("""
    DO $privacy_job_deferral_shape$
    DECLARE
      actual_columns jsonb;
      expected_columns constant jsonb := '[
        {"name":"job_id","type":"uuid","not_null":true},
        {"name":"request_id","type":"uuid","not_null":true},
        {"name":"classification","type":"character varying(64)","not_null":true},
        {"name":"queue","type":"character varying(80)","not_null":true},
        {"name":"job_type","type":"character varying(160)","not_null":true},
        {"name":"dedupe_key","type":"character varying(320)","not_null":true},
        {"name":"established_at","type":"timestamp(6) without time zone","not_null":true}
      ]'::jsonb;
    BEGIN
      SELECT pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'name', attribute.attname,
          'type', pg_catalog.format_type(attribute.atttypid, attribute.atttypmod),
          'not_null', attribute.attnotnull
        ) ORDER BY attribute.attnum
      )
      INTO STRICT actual_columns
      FROM pg_catalog.pg_attribute AS attribute
      WHERE attribute.attrelid =
              'public.privacy_erasure_job_deferral_receipts'::regclass
        AND attribute.attnum > 0
        AND NOT attribute.attisdropped;

      IF actual_columns IS DISTINCT FROM expected_columns OR EXISTS (
        SELECT 1
        FROM pg_catalog.pg_attrdef AS default_value
        WHERE default_value.adrelid =
                'public.privacy_erasure_job_deferral_receipts'::regclass
      ) OR (
        SELECT count(*)
        FROM pg_catalog.pg_constraint AS constraint_row
        WHERE constraint_row.conrelid =
                'public.privacy_erasure_job_deferral_receipts'::regclass
          AND constraint_row.contype = 'p'
      ) <> 1 OR NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint AS constraint_row
        WHERE constraint_row.conrelid =
                'public.privacy_erasure_job_deferral_receipts'::regclass
          AND constraint_row.contype = 'p'
          AND NOT constraint_row.condeferrable
          AND NOT constraint_row.condeferred
          AND constraint_row.conkey = ARRAY[
            (
              SELECT attribute.attnum
              FROM pg_catalog.pg_attribute AS attribute
              WHERE attribute.attrelid = constraint_row.conrelid
                AND attribute.attname = 'job_id'
                AND NOT attribute.attisdropped
            )
          ]::smallint[]
      ) THEN
        RAISE EXCEPTION 'Privacy erasure job deferral receipt schema is invalid'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $privacy_job_deferral_shape$;
    """)

    execute_compatible("""
    ALTER TABLE public.privacy_erasure_job_deferral_receipts
      DROP CONSTRAINT IF EXISTS privacy_erasure_job_deferral_receipts_shape_check,
      ADD CONSTRAINT privacy_erasure_job_deferral_receipts_shape_check CHECK (
        classification = 'privacy_erasure_job_deferral_v1'
        AND queue = 'privacy'
        AND job_type = 'privacy_erasure'
        AND dedupe_key = 'privacy-erasure:' || request_id::text
      ) NOT VALID
    """)

    execute_compatible("""
    ALTER TABLE public.privacy_erasure_job_deferral_receipts
      VALIDATE CONSTRAINT privacy_erasure_job_deferral_receipts_shape_check
    """)
  end

  defp add_erasure_constraints do
    add_constraint_unless_present(
      "privacy_erasure_requests",
      "privacy_erasure_requests_subject_user_id_fkey",
      "FOREIGN KEY (subject_user_id) REFERENCES users(id) ON DELETE SET NULL"
    )

    add_constraint_unless_present(
      "privacy_erasure_requests",
      "privacy_erasure_requests_subject_agent_id_fkey",
      "FOREIGN KEY (subject_agent_id) REFERENCES agents(id) ON DELETE SET NULL"
    )
  end

  defp add_legacy_cascade_constraints do
    # Fresh 140003 installs already have this FK. An already-expanded database
    # may have applied the earlier no-FK shape; NOT VALID avoids a table scan,
    # enforces all future writes/deletes, and is validated only after orphan
    # cleanup in the storage-only privacy operator.
    add_constraint_unless_present(
      "snapshot_quarantines",
      "snapshot_quarantines_agent_id_fkey",
      "FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE NOT VALID"
    )

    # Termination attestations contain operator/evidence identifiers and are not
    # legal receipts. They must follow the exact Effect row during erasure.
    add_constraint_unless_present(
      "effect_termination_attestations",
      "effect_termination_attestations_effect_id_fkey",
      "FOREIGN KEY (effect_id) REFERENCES effects(id) ON DELETE CASCADE NOT VALID"
    )
  end

  defp repair_purged_agent_work_result_authority do
    case repair_purged_agent_work_result_batch() do
      {:ok, {0, []}} ->
        :ok

      {:ok, {_selected_count, []}} ->
        repair_purged_agent_work_result_authority()

      {:ok, {_selected_count, failures}} ->
        details =
          Enum.map_join(failures, ",", fn {row_id, sqlstate} ->
            "#{row_id}:#{sqlstate}"
          end)

        raise "purged agent work result authority repair rejected row(s): #{details}"
    end
  end

  defp repair_purged_agent_work_result_batch do
    repo().transaction(
      fn ->
        repo().query!(
          "SELECT set_config('maraithon.agent_work_result_purge_repair', " <>
            "'CLEAR_PURGED_AUTHORITY_V1', true)",
          [],
          timeout: :infinity,
          log: false
        )

        # Make every deferred row proof fire inside its row savepoint rather than
        # at COMMIT, where Postgrex would disconnect and mask the failing identity.
        repo().query!(
          "SET CONSTRAINTS ALL IMMEDIATE",
          [],
          timeout: :infinity,
          log: false
        )

        selected =
          repo().query!(
            """
            SELECT result.id, result.id::text
            FROM public.agent_work_results AS result
            WHERE result.result_purged_at IS NOT NULL
              AND (result.result_digest IS NOT NULL OR
                   result.result_digest_version IS NOT NULL OR
                   result.result_digest_key_tag IS NOT NULL OR
                   result.result_content_digest IS NULL OR
                   result.result_content_digest_version IS NULL)
            ORDER BY result.id
            LIMIT 500
            FOR UPDATE OF result SKIP LOCKED
            """,
            [],
            timeout: :infinity,
            log: false
          )

        failures =
          Enum.reduce(selected.rows, [], fn [row_id, row_id_text], failures ->
            case repair_purged_agent_work_result_row(row_id) do
              :ok -> failures
              {:error, sqlstate} -> [{row_id_text, sqlstate} | failures]
            end
          end)

        {selected.num_rows, Enum.reverse(failures)}
      end,
      timeout: :infinity
    )
  end

  defp repair_purged_agent_work_result_row(row_id) do
    savepoint = "agent_work_result_purge_repair_row"

    repo().query!("SAVEPOINT #{savepoint}", [], timeout: :infinity, log: false)

    result =
      repo().query(
        """
        UPDATE public.agent_work_results
        SET result_content_digest = COALESCE(result_digest, result_content_digest),
            result_content_digest_version = 0,
            result_digest = NULL,
            result_digest_version = NULL,
            result_digest_key_tag = NULL,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1
        """,
        [row_id],
        timeout: :infinity,
        log: false
      )

    case result do
      {:ok, %{num_rows: 1}} ->
        repo().query!("RELEASE SAVEPOINT #{savepoint}", [],
          timeout: :infinity,
          log: false
        )

        :ok

      {:ok, %{num_rows: row_count}} ->
        repo().query!("ROLLBACK TO SAVEPOINT #{savepoint}", [],
          timeout: :infinity,
          log: false
        )

        repo().query!("RELEASE SAVEPOINT #{savepoint}", [],
          timeout: :infinity,
          log: false
        )

        {:error, "unexpected_row_count_#{row_count}"}

      {:error, %Postgrex.Error{} = error} ->
        repo().query!("ROLLBACK TO SAVEPOINT #{savepoint}", [],
          timeout: :infinity,
          log: false
        )

        repo().query!("RELEASE SAVEPOINT #{savepoint}", [],
          timeout: :infinity,
          log: false
        )

        {:error, Map.get(error.postgres, :pg_code, "unknown")}

      {:error, error} ->
        raise error
    end
  end

  defp create_online_indexes do
    # These tables are new in this migration; ordinary CREATE INDEX is atomic,
    # so an interrupted statement cannot leave a same-name invalid shell.
    execute_compatible("""
    CREATE UNIQUE INDEX IF NOT EXISTS privacy_erasure_requests_active_user_index
    ON privacy_erasure_requests (subject_user_id)
    WHERE scope = 'user' AND state <> 'completed' AND subject_user_id IS NOT NULL
    """)

    execute_compatible("""
    CREATE UNIQUE INDEX IF NOT EXISTS privacy_erasure_requests_active_agent_index
    ON privacy_erasure_requests (subject_agent_id)
    WHERE scope = 'agent' AND state <> 'completed' AND subject_agent_id IS NOT NULL
    """)

    execute_compatible("""
    CREATE INDEX IF NOT EXISTS privacy_erasure_requests_work_index
    ON privacy_erasure_requests (last_attempted_at NULLS FIRST, requested_at, id)
    WHERE state <> 'completed'
    """)

    execute_compatible("""
    CREATE UNIQUE INDEX IF NOT EXISTS privacy_erasure_agent_targets_identity_index
    ON privacy_erasure_agent_targets (request_id, agent_id)
    """)

    execute_compatible("""
    CREATE INDEX IF NOT EXISTS privacy_erasure_agent_targets_work_index
    ON privacy_erasure_agent_targets (request_id, state, last_attempted_at, id)
    """)

    execute_compatible("""
    CREATE UNIQUE INDEX IF NOT EXISTS privacy_erasure_provider_revocations_identity_index
    ON privacy_erasure_provider_revocations (request_id, credential_table, credential_row_id)
    """)

    execute_compatible("""
    CREATE UNIQUE INDEX IF NOT EXISTS privacy_erasure_receipts_request_index
    ON privacy_erasure_receipts (request_id)
    """)

    execute_compatible("""
    CREATE INDEX IF NOT EXISTS privacy_erasure_receipts_expiry_index
    ON privacy_erasure_receipts (expires_at, id)
    """)

    # Concurrent builds can leave an invalid same-name shell when the client or
    # database crashes. Remove it before every retry so IF NOT EXISTS can never
    # mistake an unusable index for completed erasure/retention proof coverage.
    create_retry_safe_concurrent_index(
      "privacy_erasure_agent_runs_user_id_index",
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS privacy_erasure_agent_runs_user_id_index " <>
        "ON agent_runs (user_id)"
    )

    create_retry_safe_concurrent_index(
      "privacy_erasure_agent_work_result_acquisitions_user_id_index",
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS " <>
        "privacy_erasure_agent_work_result_acquisitions_user_id_index " <>
        "ON agent_work_result_acquisitions (user_id)"
    )

    create_retry_safe_concurrent_index(
      "privacy_erasure_agent_work_results_user_id_index",
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS " <>
        "privacy_erasure_agent_work_results_user_id_index ON agent_work_results (user_id)"
    )

    create_retry_safe_concurrent_index(
      "privacy_erasure_chief_acquisition_envelopes_user_id_index",
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS " <>
        "privacy_erasure_chief_acquisition_envelopes_user_id_index " <>
        "ON chief_acquisition_envelopes (user_id)"
    )

    create_retry_safe_concurrent_index(
      "privacy_erasure_chief_projection_receipts_user_id_index",
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS " <>
        "privacy_erasure_chief_projection_receipts_user_id_index " <>
        "ON chief_projection_receipts (user_id)"
    )

    create_retry_safe_concurrent_index(
      "privacy_erasure_effects_owner_user_id_index",
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS privacy_erasure_effects_owner_user_id_index " <>
        "ON effects (owner_user_id)"
    )

    create_retry_safe_concurrent_index(
      "privacy_erasure_project_repo_grants_granted_by_user_id_index",
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS " <>
        "privacy_erasure_project_repo_grants_granted_by_user_id_index " <>
        "ON project_repo_grants (granted_by_user_id)"
    )

    create_retry_safe_concurrent_index(
      "privacy_erasure_todos_owner_user_id_index",
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS privacy_erasure_todos_owner_user_id_index " <>
        "ON todos (owner_user_id)"
    )

    create_retry_safe_concurrent_index(
      "agent_directives_unpurged_ack_retention_index",
      """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS agent_directives_unpurged_ack_retention_index
      ON agent_directives (terminal_acknowledged_at, id)
      WHERE payload_purged_at IS NULL
        AND terminal_acknowledged_at IS NOT NULL
        AND status IN ('completed', 'dead_letter')
      """
    )

    # Final, feature-dark catalog authority is captured only after every
    # 140007 function, trigger, constraint, ACL, owner, and concurrent index.
    attest_privacy_authority()
    refresh_privacy_manifest()
    refresh_effect_manifest()
    refresh_runtime_manifest()
    prepare_durable_payload_manifest_refresh()
    execute_compatible("SELECT public.refresh_durable_payload_protocol_manifest()")
  end

  defp prepare_durable_payload_manifest_refresh do
    execute_compatible("""
    DO $privacy_durable_manifest_expansion$
    DECLARE
      runtime_mode text;
      effect_mode text;
      prior_triggers jsonb;
      snapshot jsonb;
      expected_triggers text[] := ARRAY[
        'agent_directives.enforce_agent_directives_operational_retention',
        'agent_run_steps.enforce_agent_run_steps_operational_retention',
        'agent_runs.enforce_agent_runs_operational_retention',
        'agent_work_results.enforce_agent_work_results_operational_retention',
        'background_jobs.enforce_background_jobs_operational_retention',
        'background_jobs.enforce_background_jobs_privacy_erasure_write_fence',
        'background_jobs.capture_privacy_erasure_job_deferral_receipt_trigger',
        'connected_accounts.enforce_connected_accounts_privacy_erasure_write_fence',
        'effect_execution_protocols.enforce_operational_privacy_activation_trigger',
        'effects.enforce_effects_operational_retention',
        'events.enforce_events_operational_retention',
        'oauth_tokens.enforce_oauth_tokens_privacy_erasure_write_fence',
        'operator_events.enforce_operator_events_operational_retention',
        'runtime_ingress_receipts.enforce_runtime_ingress_receipts_operational_retention',
        'scheduled_jobs.enforce_scheduled_jobs_operational_retention',
        'telegram_assistant_runs.enforce_telegram_assistant_runs_operational_retention',
        'telegram_assistant_steps.enforce_telegram_assistant_steps_operational_retention',
        'telegram_conversation_turns.enforce_telegram_conversation_turns_operational_retention',
        'telegram_conversations.enforce_telegram_conversations_operational_retention',
        'telegram_prepared_actions.enforce_telegram_prepared_actions_operational_retention'
      ]::text[];
    BEGIN
      SELECT mode INTO STRICT runtime_mode
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime'
      FOR SHARE;

      SELECT mode INTO STRICT effect_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF runtime_mode <> 'dark' OR effect_mode <> 'legacy' THEN
        RAISE EXCEPTION 'Privacy durable manifest expansion requires the feature-dark legacy pair'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT catalog_manifest -> 'triggers'
      INTO STRICT prior_triggers
      FROM public.durable_payload_protocol_manifests
      WHERE name = 'durable_payload_140005'
        AND migration_version = 20260810140005
      FOR UPDATE;

      snapshot := public.durable_payload_catalog_manifest_snapshot();

      IF snapshot -> 'ambiguous_functions' <> '[]'::jsonb OR
         snapshot -> 'unexpected_column_acl_grantees' <> '[]'::jsonb OR
         (snapshot ->> 'source_acl_ready')::boolean IS NOT TRUE OR
         EXISTS (
           SELECT 1
           FROM pg_catalog.jsonb_object_keys(prior_triggers) AS prior(key)
           WHERE NOT (snapshot -> 'triggers') ? prior.key
              OR prior_triggers -> prior.key IS DISTINCT FROM
                   snapshot -> 'triggers' -> prior.key
         ) OR EXISTS (
           SELECT 1
           FROM pg_catalog.jsonb_object_keys(snapshot -> 'triggers') AS current(key)
           WHERE NOT prior_triggers ? current.key
             AND current.key <> ALL(expected_triggers)
         ) OR EXISTS (
           SELECT 1
           FROM pg_catalog.unnest(expected_triggers) AS expected(key)
           WHERE NOT (snapshot -> 'triggers') ? expected.key
         ) THEN
        RAISE EXCEPTION 'Privacy durable manifest expansion contains unreviewed catalog drift'
          USING ERRCODE = 'check_violation';
      END IF;

      PERFORM set_config(
        'maraithon.durable_payload_manifest_refresh',
        'MIGRATOR_DARK_REFRESH_V1',
        true
      );

      UPDATE public.durable_payload_protocol_manifests
      SET catalog_manifest = snapshot,
          manifest_digest = public.digest(
            pg_catalog.convert_to(snapshot::text, 'UTF8'), 'sha256'
          ),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'durable_payload_140005'
        AND migration_version = 20260810140005;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Privacy durable manifest authority is missing'
          USING ERRCODE = 'check_violation';
      END IF;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Privacy durable manifest protocol authority is missing'
        USING ERRCODE = 'check_violation';
    END
    $privacy_durable_manifest_expansion$;
    """)
  end

  defp create_retry_safe_concurrent_index(name, statement) do
    execute_compatible("DROP INDEX CONCURRENTLY IF EXISTS public.#{name}")
    execute_compatible(statement)
  end

  defp add_constraint_unless_present(table, name, definition) do
    execute_compatible("""
    DO $privacy$
    BEGIN
      IF to_regclass('public.#{table}') IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.#{table}'::regclass AND conname = '#{name}'
      ) THEN
        ALTER TABLE public.#{table} ADD CONSTRAINT #{name} #{definition};
      END IF;
    END
    $privacy$
    """)
  end
end
