defmodule Maraithon.Repo.Migrations.AddGenerationFencedEffectExecution do
  use Ecto.Migration

  def up do
    create_if_not_exists table(:effect_execution_protocols, primary_key: false) do
      add :name, :string, primary_key: true
      add :mode, :string, null: false, default: "legacy"
      add :activated_at, :utc_datetime_usec
      add :activation_epoch, :uuid
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists table(:effect_execution_protocol_manifests, primary_key: false) do
      add :name, :string, primary_key: true
      add :constraint_fingerprints, :map, null: false
      add :function_fingerprints, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists table(:effect_termination_attestations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :effect_id, :uuid, null: false
      add :claim_token, :uuid, null: false
      add :owner_node, :string, null: false
      add :supervisor_id, :uuid, null: false
      add :task_id, :uuid, null: false
      add :evidence_id, :string, null: false
      add :evidence_digest, :binary, null: false
      add :attested_by, :string, null: false
      add :attested_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(
                           :effect_termination_attestations,
                           [:effect_id, :claim_token, :supervisor_id, :task_id],
                           name: :effect_termination_attestations_claim_identity_index
                         )

    execute("""
    INSERT INTO public.effect_execution_protocols
      (name, mode, inserted_at, updated_at)
    VALUES
      ('effects', 'legacy', timezone('UTC', clock_timestamp()),
       timezone('UTC', clock_timestamp()))
    ON CONFLICT (name) DO NOTHING
    """)

    alter table(:effects) do
      add_if_not_exists :effect_protocol_version, :smallint
      add_if_not_exists :payload_encryption_version, :smallint
      add_if_not_exists :execution_lane, :string
      add_if_not_exists :params_ciphertext, :binary
      add_if_not_exists :result_ciphertext, :binary
      add_if_not_exists :payload_purged_at, :utc_datetime_usec
      add_if_not_exists :runtime_owner_generation, :uuid
      add_if_not_exists :claim_token, :uuid
      add_if_not_exists :claim_owner_node, :string
      add_if_not_exists :claim_heartbeat_at, :utc_datetime_usec
      add_if_not_exists :claim_expires_at, :utc_datetime_usec
      add_if_not_exists :claim_supervisor_id, :uuid
      add_if_not_exists :claim_task_id, :uuid
      add_if_not_exists :cancellation_state, :string
      add_if_not_exists :cancellation_reason, :string
      add_if_not_exists :cancellation_requested_at, :utc_datetime_usec
      add_if_not_exists :cancellation_target_claim_token, :uuid
      add_if_not_exists :cancellation_last_attempt_at, :utc_datetime_usec
      add_if_not_exists :cancellation_last_error, :string
      add_if_not_exists :cancellation_settled_at, :utc_datetime_usec
    end

    execute("""
    ALTER TABLE public.effect_execution_protocols
      DROP CONSTRAINT IF EXISTS effect_execution_protocol_singleton_check,
      DROP CONSTRAINT IF EXISTS effect_execution_protocol_mode_check,
      DROP CONSTRAINT IF EXISTS effect_execution_protocol_activation_shape_check
    """)

    execute("""
    ALTER TABLE public.effect_execution_protocols
      ADD CONSTRAINT effect_execution_protocol_singleton_check
        CHECK (name = 'effects') NOT VALID,
      ADD CONSTRAINT effect_execution_protocol_mode_check
        CHECK (mode IN ('legacy', 'generation_fenced_v1')) NOT VALID,
      ADD CONSTRAINT effect_execution_protocol_activation_shape_check
        CHECK (
          (mode = 'legacy' AND activated_at IS NULL AND activation_epoch IS NULL) OR
          (mode = 'generation_fenced_v1' AND activated_at IS NOT NULL AND
           activation_epoch IS NOT NULL)
        ) NOT VALID
    """)

    execute("""
    ALTER TABLE public.effect_execution_protocols
      VALIDATE CONSTRAINT effect_execution_protocol_singleton_check
    """)

    execute("""
    ALTER TABLE public.effect_execution_protocols
      VALIDATE CONSTRAINT effect_execution_protocol_mode_check
    """)

    execute("""
    ALTER TABLE public.effect_execution_protocols
      VALIDATE CONSTRAINT effect_execution_protocol_activation_shape_check
    """)

    execute("""
    ALTER TABLE public.effect_execution_protocol_manifests
      DROP CONSTRAINT IF EXISTS effect_execution_protocol_manifest_singleton_check
    """)

    execute("""
    ALTER TABLE public.effect_execution_protocol_manifests
      ADD CONSTRAINT effect_execution_protocol_manifest_singleton_check
        CHECK (name = 'effects') NOT VALID
    """)

    execute("""
    ALTER TABLE public.effect_execution_protocol_manifests
      VALIDATE CONSTRAINT effect_execution_protocol_manifest_singleton_check
    """)

    execute("""
    ALTER TABLE public.effect_termination_attestations
      DROP CONSTRAINT IF EXISTS effect_termination_attestations_shape_check
    """)

    execute("""
    ALTER TABLE public.effect_termination_attestations
      ADD CONSTRAINT effect_termination_attestations_shape_check CHECK (
        octet_length(owner_node) BETWEEN 1 AND 255 AND
        octet_length(evidence_id) BETWEEN 1 AND 256 AND
        octet_length(evidence_digest) = 32 AND
        octet_length(attested_by) BETWEEN 1 AND 320
      ) NOT VALID
    """)

    execute("""
    ALTER TABLE public.effect_termination_attestations
      VALIDATE CONSTRAINT effect_termination_attestations_shape_check
    """)

    execute("""
    ALTER TABLE public.effects
      DROP CONSTRAINT IF EXISTS effects_execution_status_check
    """)

    execute("""
    ALTER TABLE public.effects
      ADD CONSTRAINT effects_execution_status_check
        CHECK (status IN ('pending', 'claimed', 'cancelling', 'completed', 'failed', 'cancelled'))
        NOT VALID
    """)

    execute("""
    ALTER TABLE public.effects VALIDATE CONSTRAINT effects_execution_status_check
    """)

    execute("""
    ALTER TABLE public.effects
          DROP CONSTRAINT IF EXISTS effects_generation_fenced_shape_check
    """)

    execute("""
    ALTER TABLE public.effects
          ADD CONSTRAINT effects_generation_fenced_shape_check CHECK ((
            (
              runtime_owner_generation IS NULL AND
              claim_token IS NULL AND claim_owner_node IS NULL AND
              claim_heartbeat_at IS NULL AND claim_expires_at IS NULL AND
              claim_supervisor_id IS NULL AND claim_task_id IS NULL AND
              cancellation_state IS NULL AND cancellation_reason IS NULL AND
              cancellation_requested_at IS NULL AND
              cancellation_target_claim_token IS NULL AND
              cancellation_last_attempt_at IS NULL AND
              cancellation_last_error IS NULL AND cancellation_settled_at IS NULL
            ) OR (
              runtime_owner_generation IS NOT NULL AND
              effect_protocol_version = 2 AND payload_encryption_version = 1 AND
              params = '{"redacted": true}'::jsonb AND result IS NULL AND
              (
                (payload_purged_at IS NULL AND params_ciphertext IS NOT NULL) OR
                (payload_purged_at IS NOT NULL AND params_ciphertext IS NULL AND
                 result_ciphertext IS NULL)
              ) AND (
                (
                  status = 'pending' AND payload_purged_at IS NULL AND
                  claimed_by IS NULL AND claimed_at IS NULL AND
                  claim_token IS NULL AND claim_owner_node IS NULL AND
                  claim_heartbeat_at IS NULL AND claim_expires_at IS NULL AND
                  claim_supervisor_id IS NULL AND claim_task_id IS NULL AND
                  cancellation_state IS NULL AND cancellation_reason IS NULL AND
                  cancellation_requested_at IS NULL AND
                  cancellation_target_claim_token IS NULL AND
                  cancellation_last_attempt_at IS NULL AND
                  cancellation_last_error IS NULL AND cancellation_settled_at IS NULL
                ) OR (
                  status = 'claimed' AND payload_purged_at IS NULL AND
                  claimed_by IS NOT NULL AND claimed_at IS NOT NULL AND
                  claim_token IS NOT NULL AND claim_owner_node = claimed_by AND
                  claim_heartbeat_at IS NOT NULL AND claim_expires_at IS NOT NULL AND
                  claim_heartbeat_at < claim_expires_at AND
                  claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL AND
                  cancellation_state IS NULL AND cancellation_reason IS NULL AND
                  cancellation_requested_at IS NULL AND
                  cancellation_target_claim_token IS NULL AND
                  cancellation_last_attempt_at IS NULL AND
                  cancellation_last_error IS NULL AND cancellation_settled_at IS NULL
                ) OR (
                  status = 'cancelling' AND payload_purged_at IS NULL AND
                  claimed_by IS NOT NULL AND claimed_at IS NOT NULL AND
                  claim_token IS NOT NULL AND claim_owner_node = claimed_by AND
                  claim_heartbeat_at IS NOT NULL AND claim_expires_at IS NOT NULL AND
                  claim_heartbeat_at < claim_expires_at AND
                  claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL AND
                  cancellation_state = 'requested' AND cancellation_reason IS NOT NULL AND
                  cancellation_requested_at IS NOT NULL AND
                  cancellation_target_claim_token = claim_token AND
                  cancellation_settled_at IS NULL AND
                  (cancellation_last_error IS NULL OR
                   cancellation_last_attempt_at IS NOT NULL)
                ) OR (
                  status IN ('completed', 'failed') AND
                  claim_token IS NOT NULL AND claim_owner_node IS NOT NULL AND
                  claim_heartbeat_at IS NOT NULL AND claim_expires_at IS NOT NULL AND
                  claim_heartbeat_at < claim_expires_at AND
                  claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL AND
                  claimed_by IS NULL AND claimed_at IS NULL AND
                  (
                    (
                      cancellation_state IS NULL AND cancellation_reason IS NULL AND
                      cancellation_requested_at IS NULL AND
                      cancellation_target_claim_token IS NULL AND
                      cancellation_last_attempt_at IS NULL AND
                      cancellation_last_error IS NULL AND cancellation_settled_at IS NULL
                    ) OR (
                      cancellation_state = 'settled' AND cancellation_reason IS NOT NULL AND
                      cancellation_requested_at IS NOT NULL AND
                      cancellation_target_claim_token = claim_token AND
                      cancellation_last_attempt_at IS NOT NULL AND
                      cancellation_last_error IS NULL AND
                      cancellation_settled_at IS NOT NULL
                    )
                  )
                ) OR (
                  status = 'cancelled' AND
                  claimed_by IS NULL AND claimed_at IS NULL AND
                  claim_token IS NULL AND claim_owner_node IS NULL AND
                  claim_heartbeat_at IS NULL AND claim_expires_at IS NULL AND
                  claim_supervisor_id IS NULL AND claim_task_id IS NULL AND
                  cancellation_state = 'settled' AND cancellation_reason IS NOT NULL AND
                  cancellation_requested_at IS NOT NULL AND
                  cancellation_target_claim_token IS NULL AND
                  cancellation_last_attempt_at IS NULL AND
                  cancellation_last_error IS NULL AND
                  cancellation_settled_at IS NOT NULL
                )
              )
            )
          ) IS TRUE) NOT VALID
    """)

    execute("""
    ALTER TABLE public.effects VALIDATE CONSTRAINT effects_generation_fenced_shape_check
    """)

    execute("""
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
      WHERE name = 'effects';

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

        RETURN OLD;
      END IF;

      IF TG_OP = 'UPDATE' AND
         NEW.runtime_owner_generation IS DISTINCT FROM OLD.runtime_owner_generation THEN
        RAISE EXCEPTION 'Effect runtime owner generation is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.cancellation_target_claim_token IS NOT NULL AND
         NEW.cancellation_target_claim_token IS DISTINCT FROM
           OLD.cancellation_target_claim_token THEN
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
        OLD.payload_purged_at IS NULL AND NEW.payload_purged_at IS NOT NULL AND
        current_setting('maraithon.effect_payload_retention', true) =
          'PURGE_ACKNOWLEDGED_PAYLOAD' AND
        (
          (OLD.status IN ('completed', 'failed') AND
           OLD.result_acknowledged_at IS NOT NULL) OR
          (OLD.status = 'cancelled' AND
           (OLD.runtime_owner_generation IS NULL OR OLD.cancellation_state = 'settled'))
        ) AND
        NEW.params = '{"redacted": true}'::jsonb AND
        NEW.params_ciphertext IS NULL AND NEW.result IS NULL AND
        NEW.result_ciphertext IS NULL AND
        (to_jsonb(NEW) - ARRAY[
          'params', 'params_ciphertext', 'result', 'result_ciphertext',
          'payload_purged_at', 'updated_at'
        ]::text[]) IS NOT DISTINCT FROM
        (to_jsonb(OLD) - ARRAY[
          'params', 'params_ciphertext', 'result', 'result_ciphertext',
          'payload_purged_at', 'updated_at'
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
           OLD.runtime_owner_generation IS NOT NULL AND
           OLD.status = 'claimed' AND NEW.status = 'pending' AND
           OLD.cancellation_target_claim_token IS NULL
         ) THEN
        RAISE EXCEPTION 'Effect claim token can only be cleared by a known-safe retry'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.cancellation_target_claim_token IS NULL AND
         NEW.cancellation_target_claim_token IS NOT NULL AND NOT (
           OLD.status = 'claimed' AND NEW.status = 'cancelling' AND
           NEW.cancellation_target_claim_token = NEW.claim_token
         ) THEN
        RAISE EXCEPTION 'Effect cancellation target can only fence the active exact claim'
          USING ERRCODE = 'check_violation';
      END IF;

      IF protocol_mode = 'legacy' THEN
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

    execute("DROP TRIGGER IF EXISTS enforce_effect_execution_protocol_trigger ON public.effects")

    execute("""
    CREATE TRIGGER enforce_effect_execution_protocol_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.effects
      FOR EACH ROW EXECUTE FUNCTION public.enforce_effect_execution_protocol()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_agent_directive_protocol()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      protocol_mode text;
      writer_protocol text;
    BEGIN
      SELECT mode INTO STRICT protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF protocol_mode = 'legacy' THEN
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

      IF NOT ((
        NEW.payload_encryption_version = 1 AND
        NEW.payload_ciphertext IS NOT NULL AND
        NEW.payload = '{"redacted": true}'::jsonb
      ) IS TRUE) THEN
        RAISE EXCEPTION 'Exact Agent Directive payload must remain encrypted and redacted'
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

    execute(
      "DROP TRIGGER IF EXISTS enforce_agent_directive_protocol_trigger " <>
        "ON public.agent_directives"
    )

    execute("""
    CREATE TRIGGER enforce_agent_directive_protocol_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.agent_directives
      FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_directive_protocol()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_effect_termination_attestation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      attestation_valid boolean;
    BEGIN
      IF TG_OP IN ('UPDATE', 'DELETE') THEN
        RAISE EXCEPTION 'Effect termination attestations are immutable'
          USING ERRCODE = 'check_violation';
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

    execute(
      "DROP TRIGGER IF EXISTS enforce_effect_termination_attestation_trigger " <>
        "ON public.effect_termination_attestations"
    )

    execute("""
    CREATE TRIGGER enforce_effect_termination_attestation_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.effect_termination_attestations
      FOR EACH ROW EXECUTE FUNCTION public.enforce_effect_termination_attestation()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.generation_fenced_effect_index_matches(requested_name text)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
      WITH expected(
        index_name,
        is_unique,
        key_columns,
        key_options,
        opclasses,
        predicate
      ) AS (
        VALUES
          (
            'effects_claim_token_unique_index',
            true,
            ARRAY['claim_token']::text[],
            ARRAY[0]::integer[],
            ARRAY['uuid_ops']::text[],
            'claim_token IS NOT NULL'
          ),
          (
            'effects_physical_task_identity_unique_index',
            true,
            ARRAY['claim_owner_node', 'claim_supervisor_id', 'claim_task_id']::text[],
            ARRAY[0, 0, 0]::integer[],
            ARRAY['text_ops', 'uuid_ops', 'uuid_ops']::text[],
            'claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL'
          ),
          (
            'effects_cancellation_reconciliation_index',
            false,
            ARRAY['cancellation_last_attempt_at', 'cancellation_requested_at', 'id']::text[],
            ARRAY[2, 0, 0]::integer[],
            ARRAY['timestamp_ops', 'timestamp_ops', 'uuid_ops']::text[],
            $predicate$status::text = 'cancelling'::text AND cancellation_state::text = 'requested'::text$predicate$
          ),
          (
            'effects_exact_pending_claim_index',
            false,
            ARRAY['retry_after', 'inserted_at', 'id']::text[],
            ARRAY[2, 0, 0]::integer[],
            ARRAY['timestamp_ops', 'timestamp_ops', 'uuid_ops']::text[],
            $predicate$status::text = 'pending'::text AND runtime_owner_generation IS NOT NULL$predicate$
          ),
          (
            'effects_exact_claim_expiry_index',
            false,
            ARRAY['claim_expires_at', 'id']::text[],
            ARRAY[0, 0]::integer[],
            ARRAY['timestamp_ops', 'uuid_ops']::text[],
            $predicate$status::text = 'claimed'::text AND runtime_owner_generation IS NOT NULL AND claim_token IS NOT NULL$predicate$
          ),
          (
            'effects_exact_pending_llm_lane_index',
            false,
            ARRAY['execution_lane', 'retry_after', 'inserted_at', 'id']::text[],
            ARRAY[0, 2, 0, 0]::integer[],
            ARRAY['text_ops', 'timestamp_ops', 'timestamp_ops', 'uuid_ops']::text[],
            $predicate$status::text = 'pending'::text AND runtime_owner_generation IS NOT NULL AND effect_type::text = 'llm_call'::text$predicate$
          )
      ), candidates AS (
        SELECT
          expected.*,
          index_state.*,
          access_method.amname,
          ARRAY(
            SELECT attribute.attname::text
            FROM unnest(index_state.indkey::smallint[]) WITH ORDINALITY
              AS key(attnum, ordinal)
            JOIN pg_catalog.pg_attribute AS attribute
              ON attribute.attrelid = index_state.indrelid AND
                 attribute.attnum = key.attnum
            ORDER BY key.ordinal
          ) AS actual_key_columns,
          ARRAY(
            SELECT value.option::integer
            FROM unnest(index_state.indoption::smallint[]) WITH ORDINALITY
              AS value(option, ordinal)
            ORDER BY value.ordinal
          ) AS actual_key_options,
          ARRAY(
            SELECT opclass.opcname::text
            FROM unnest(index_state.indclass::oid[]) WITH ORDINALITY
              AS class(opclass_oid, ordinal)
            JOIN pg_catalog.pg_opclass AS opclass
              ON opclass.oid = class.opclass_oid
            JOIN pg_catalog.pg_namespace AS opclass_namespace
              ON opclass_namespace.oid = opclass.opcnamespace AND
                 opclass_namespace.nspname = 'pg_catalog'
            ORDER BY class.ordinal
          ) AS actual_opclasses,
          pg_catalog.pg_get_expr(
            index_state.indpred,
            index_state.indrelid,
            true
          ) AS actual_predicate
        FROM expected
        JOIN pg_catalog.pg_class AS index_relation
          ON index_relation.relname = expected.index_name
        JOIN pg_catalog.pg_index AS index_state
          ON index_state.indexrelid = index_relation.oid
        JOIN pg_catalog.pg_class AS table_relation
          ON table_relation.oid = index_state.indrelid
        JOIN pg_catalog.pg_namespace AS table_namespace
          ON table_namespace.oid = table_relation.relnamespace
        JOIN pg_catalog.pg_namespace AS index_namespace
          ON index_namespace.oid = index_relation.relnamespace
        JOIN pg_catalog.pg_am AS access_method
          ON access_method.oid = index_relation.relam
        WHERE expected.index_name = requested_name
          AND table_namespace.nspname = 'public'
          AND index_namespace.nspname = 'public'
          AND table_relation.relname = 'effects'
      )
      SELECT COALESCE(
        COUNT(*) = 1 AND bool_and(
          indisvalid AND indisready AND indislive AND
          indisunique = is_unique AND
          amname = 'btree' AND
          indexprs IS NULL AND indpred IS NOT NULL AND
          indnkeyatts = cardinality(key_columns) AND
          indnatts = cardinality(key_columns) AND
          actual_key_columns = key_columns AND
          actual_key_options = key_options AND
          actual_opclasses = opclasses AND
          actual_predicate = predicate
        ),
        false
      )
      FROM candidates;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.generation_fenced_effect_indexes_ready_count()
    RETURNS bigint
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
      SELECT COUNT(*)
      FROM (
        VALUES
          ('effects_claim_token_unique_index'),
          ('effects_physical_task_identity_unique_index'),
          ('effects_cancellation_reconciliation_index'),
          ('effects_exact_pending_claim_index'),
          ('effects_exact_claim_expiry_index'),
          ('effects_exact_pending_llm_lane_index')
      ) AS expected(index_name)
      WHERE public.generation_fenced_effect_index_matches(expected.index_name);
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_effect_protocol_one_way()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      active_legacy bigint;
      terminal_legacy bigint;
      runtime_leases bigint;
      processing_directives bigint;
      running_runs bigint;
      requested_steps bigint;
      unencrypted_effect_payloads bigint;
      unencrypted_directive_payloads bigint;
      ready_indexes bigint;
      ready_helpers bigint;
      ready_constraints bigint;
      ready_triggers bigint;
      schema_migrations_recorded boolean;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Effect execution protocol row cannot be deleted'
          USING ERRCODE = 'check_violation';
      END IF;

      IF OLD.mode = 'generation_fenced_v1' AND
         NEW.mode IS DISTINCT FROM OLD.mode THEN
        RAISE EXCEPTION 'Effect execution protocol cannot be downgraded'
          USING ERRCODE = 'check_violation';
      END IF;

      IF OLD.mode = 'generation_fenced_v1' AND
         (NEW.activated_at IS DISTINCT FROM OLD.activated_at OR
          NEW.activation_epoch IS DISTINCT FROM OLD.activation_epoch) THEN
        RAISE EXCEPTION 'Activated Effect protocol identity is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      IF OLD.mode = 'legacy' AND NEW.mode = 'generation_fenced_v1' THEN
        IF current_setting('maraithon.effect_protocol_activation', true)
             IS DISTINCT FROM 'generation_fenced_v1' THEN
          RAISE EXCEPTION 'Effect protocol activation requires the cutover barrier'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.activated_at IS NULL OR NEW.activation_epoch IS NULL THEN
          RAISE EXCEPTION 'Effect protocol activation identity is incomplete'
            USING ERRCODE = 'check_violation';
        END IF;

        -- These locks make the safety checks authoritative even if activation
        -- is invoked through direct SQL instead of the Mix task. Queued old
        -- Effect writes resume only after mode is exact and are then rejected
        -- by enforce_effect_execution_protocol().
        LOCK TABLE public.effects IN SHARE MODE;
        LOCK TABLE public.agent_runtime_leases IN SHARE MODE;
        LOCK TABLE public.agent_directives IN SHARE MODE;
        LOCK TABLE public.agent_runs IN SHARE MODE;
        LOCK TABLE public.agent_run_steps IN SHARE MODE;

        SELECT COUNT(*) INTO runtime_leases
        FROM public.agent_runtime_leases;

        IF runtime_leases <> 0 THEN
          RAISE EXCEPTION 'Effect protocol activation requires drained runtime leases'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT
          (SELECT COUNT(*) FROM public.agent_directives WHERE status = 'processing'),
          (SELECT COUNT(*) FROM public.agent_runs WHERE status = 'running'),
          (SELECT COUNT(*) FROM public.agent_run_steps WHERE status = 'requested')
        INTO processing_directives, running_runs, requested_steps;

        IF processing_directives <> 0 OR running_runs <> 0 OR requested_steps <> 0 THEN
          RAISE EXCEPTION 'Effect protocol activation requires drained durable Agent work'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT
          COUNT(*) FILTER (
            WHERE runtime_owner_generation IS NULL AND
              NOT ((
                (status = 'cancelled' AND result_envelope IS NULL) OR
                (status IN ('completed', 'failed', 'cancelled') AND
                 result_envelope IS NOT NULL AND result_acknowledged_at IS NOT NULL)
              ) IS TRUE) AND
              NOT ((
                status IN ('completed', 'failed', 'cancelled') AND
                result_envelope IS NOT NULL AND result_acknowledged_at IS NULL
              ) IS TRUE)
          ),
          COUNT(*) FILTER (
            WHERE runtime_owner_generation IS NULL AND
                  status IN ('completed', 'failed', 'cancelled') AND
                  result_envelope IS NOT NULL AND
                  result_acknowledged_at IS NULL
          )
        INTO active_legacy, terminal_legacy
        FROM public.effects;

        IF active_legacy <> 0 OR terminal_legacy <> 0 THEN
          RAISE EXCEPTION 'Effect protocol activation requires drained legacy work'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT COUNT(*) INTO unencrypted_effect_payloads
        FROM public.effects
        WHERE payload_encryption_version IS DISTINCT FROM 1
           OR (payload_purged_at IS NULL AND params_ciphertext IS NULL)
           OR (payload_purged_at IS NOT NULL AND
               (params_ciphertext IS NOT NULL OR result_ciphertext IS NOT NULL))
           OR params IS DISTINCT FROM '{"redacted": true}'::jsonb
           OR result IS NOT NULL;

        IF unencrypted_effect_payloads <> 0 THEN
          RAISE EXCEPTION 'Effect protocol activation requires encrypted payload backfill'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT COUNT(*) INTO unencrypted_directive_payloads
        FROM public.agent_directives
        WHERE payload_encryption_version IS DISTINCT FROM 1
           OR payload_ciphertext IS NULL
           OR payload IS DISTINCT FROM '{"redacted": true}'::jsonb;

        IF unencrypted_directive_payloads <> 0 THEN
          RAISE EXCEPTION 'Effect protocol activation requires encrypted Directive payload backfill'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT COUNT(*) = 3
        FROM public.schema_migrations
        WHERE version IN (20260810132102, 20260810132103, 20260810140000)
        INTO schema_migrations_recorded;

        IF NOT schema_migrations_recorded THEN
          RAISE EXCEPTION 'Effect protocol activation requires both recorded exact migrations'
            USING ERRCODE = 'check_violation';
        END IF;

        WITH required(function_id, expected_volatility, expected_language) AS (
          VALUES
            ('public.generation_fenced_effect_index_matches(text)'::regprocedure, 's'::"char", 'sql'),
            ('public.generation_fenced_effect_indexes_ready_count()'::regprocedure, 's'::"char", 'sql')
        )
        SELECT COUNT(*) INTO ready_helpers
        FROM required
        JOIN pg_catalog.pg_proc AS function_row
          ON function_row.oid = required.function_id
         AND function_row.provolatile = required.expected_volatility
         AND NOT function_row.prosecdef
         AND function_row.proconfig = ARRAY['search_path=pg_catalog, public']::text[]
        JOIN pg_catalog.pg_language AS language_row
          ON language_row.oid = function_row.prolang
         AND language_row.lanname = required.expected_language
        JOIN public.effect_execution_protocol_manifests AS manifest
          ON manifest.name = 'effects'
         AND manifest.function_fingerprints ->> function_row.proname =
               md5(function_row.prosrc);

        IF ready_helpers <> 2 THEN
          RAISE EXCEPTION 'Effect protocol activation requires attested catalog helpers'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT public.generation_fenced_effect_indexes_ready_count()
        INTO ready_indexes;

        IF ready_indexes <> 6 THEN
          RAISE EXCEPTION 'Effect protocol activation requires all exact indexes ready'
            USING ERRCODE = 'check_violation';
        END IF;

        WITH required(relation_id, constraint_name) AS (
          VALUES
            ('public.effect_execution_protocols'::regclass, 'effect_execution_protocol_singleton_check'),
            ('public.effect_execution_protocols'::regclass, 'effect_execution_protocol_mode_check'),
            ('public.effect_execution_protocols'::regclass, 'effect_execution_protocol_activation_shape_check'),
            ('public.effect_execution_protocol_manifests'::regclass,
             'effect_execution_protocol_manifest_singleton_check'),
            ('public.effect_termination_attestations'::regclass,
             'effect_termination_attestations_shape_check'),
            ('public.effects'::regclass, 'effects_execution_status_check'),
            ('public.effects'::regclass, 'effects_generation_fenced_shape_check')
        )
        SELECT COUNT(*) INTO ready_constraints
        FROM required
        JOIN pg_catalog.pg_constraint AS constraint_row
          ON constraint_row.conrelid = required.relation_id
         AND constraint_row.conname = required.constraint_name
         AND constraint_row.contype = 'c'
         AND constraint_row.convalidated
        JOIN public.effect_execution_protocol_manifests AS manifest
          ON manifest.name = 'effects'
         AND manifest.constraint_fingerprints ->> required.constraint_name =
               md5(pg_catalog.pg_get_constraintdef(constraint_row.oid, true));

        IF ready_constraints <> 7 THEN
          RAISE EXCEPTION 'Effect protocol activation requires validated safety constraints'
            USING ERRCODE = 'check_violation';
        END IF;

        WITH required(trigger_name, relation_id, function_id, trigger_type) AS (
          VALUES
            ('enforce_effect_execution_protocol_trigger', 'public.effects'::regclass,
             'public.enforce_effect_execution_protocol()'::regprocedure, 31),
            ('enforce_agent_directive_protocol_trigger', 'public.agent_directives'::regclass,
             'public.enforce_agent_directive_protocol()'::regprocedure, 31),
            ('enforce_effect_protocol_one_way_trigger', 'public.effect_execution_protocols'::regclass,
             'public.enforce_effect_protocol_one_way()'::regprocedure, 27),
            ('enforce_effect_termination_attestation_trigger',
             'public.effect_termination_attestations'::regclass,
             'public.enforce_effect_termination_attestation()'::regprocedure, 31),
            ('reject_effect_protocol_manifest_mutation_trigger',
             'public.effect_execution_protocol_manifests'::regclass,
             'public.reject_effect_protocol_manifest_mutation()'::regprocedure, 27),
            ('reject_effect_protocol_manifest_truncate_trigger',
             'public.effect_execution_protocol_manifests'::regclass,
             'public.reject_durable_effect_truncate()'::regprocedure, 34),
            ('reject_effect_termination_attestations_truncate_trigger',
             'public.effect_termination_attestations'::regclass,
             'public.reject_durable_effect_truncate()'::regprocedure, 34),
            ('reject_effect_protocol_truncate_trigger', 'public.effect_execution_protocols'::regclass,
             'public.reject_durable_effect_truncate()'::regprocedure, 34),
            ('reject_effects_truncate_trigger', 'public.effects'::regclass,
             'public.reject_durable_effect_truncate()'::regprocedure, 34)
        )
        SELECT COUNT(*) INTO ready_triggers
        FROM required
        JOIN pg_catalog.pg_trigger AS trigger_row
          ON trigger_row.tgrelid = required.relation_id
         AND trigger_row.tgname = required.trigger_name
         AND trigger_row.tgfoid = required.function_id
         AND trigger_row.tgtype = required.trigger_type
         AND NOT trigger_row.tgisinternal
         AND trigger_row.tgenabled IN ('O', 'A')
        JOIN pg_catalog.pg_proc AS function_row
          ON function_row.oid = required.function_id
         AND function_row.provolatile = 'v'
         AND NOT function_row.prosecdef
         AND function_row.proconfig = ARRAY['search_path=pg_catalog, public']::text[]
        JOIN pg_catalog.pg_language AS language_row
          ON language_row.oid = function_row.prolang
         AND language_row.lanname = 'plpgsql'
        JOIN public.effect_execution_protocol_manifests AS manifest
          ON manifest.name = 'effects'
         AND manifest.function_fingerprints ->> function_row.proname =
               md5(function_row.prosrc);

        IF ready_triggers <> 9 THEN
          RAISE EXCEPTION 'Effect protocol activation requires enabled safety triggers'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_effect_protocol_one_way_trigger ON public.effect_execution_protocols"
    )

    execute("""
    CREATE TRIGGER enforce_effect_protocol_one_way_trigger
      BEFORE UPDATE OR DELETE ON public.effect_execution_protocols
      FOR EACH ROW EXECUTE FUNCTION public.enforce_effect_protocol_one_way()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.reject_durable_effect_truncate()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      RAISE EXCEPTION 'Durable Effect protocol tables cannot be truncated'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_effect_protocol_truncate_trigger ON public.effect_execution_protocols"
    )

    execute("""
    CREATE TRIGGER reject_effect_protocol_truncate_trigger
      BEFORE TRUNCATE ON public.effect_execution_protocols
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute("DROP TRIGGER IF EXISTS reject_effects_truncate_trigger ON public.effects")

    execute("""
    CREATE TRIGGER reject_effects_truncate_trigger
      BEFORE TRUNCATE ON public.effects
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_effect_termination_attestations_truncate_trigger " <>
        "ON public.effect_termination_attestations"
    )

    execute("""
    CREATE TRIGGER reject_effect_termination_attestations_truncate_trigger
      BEFORE TRUNCATE ON public.effect_termination_attestations
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.reject_effect_protocol_manifest_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      RAISE EXCEPTION 'Effect protocol manifest is immutable'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_effect_protocol_manifest_mutation_trigger " <>
        "ON public.effect_execution_protocol_manifests"
    )

    execute("""
    CREATE TRIGGER reject_effect_protocol_manifest_mutation_trigger
      BEFORE UPDATE OR DELETE ON public.effect_execution_protocol_manifests
      FOR EACH ROW EXECUTE FUNCTION public.reject_effect_protocol_manifest_mutation()
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_effect_protocol_manifest_truncate_trigger " <>
        "ON public.effect_execution_protocol_manifests"
    )

    execute("""
    CREATE TRIGGER reject_effect_protocol_manifest_truncate_trigger
      BEFORE TRUNCATE ON public.effect_execution_protocol_manifests
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute("""
    INSERT INTO public.effect_execution_protocol_manifests
      (name, constraint_fingerprints, function_fingerprints, inserted_at, updated_at)
    SELECT
      'effects',
      (
        SELECT jsonb_object_agg(
                 constraint_row.conname,
                 md5(pg_catalog.pg_get_constraintdef(constraint_row.oid, true))
               )
        FROM pg_catalog.pg_constraint AS constraint_row
        WHERE (constraint_row.conrelid, constraint_row.conname) IN (
          ('public.effect_execution_protocols'::regclass,
           'effect_execution_protocol_singleton_check'),
          ('public.effect_execution_protocols'::regclass,
           'effect_execution_protocol_mode_check'),
          ('public.effect_execution_protocols'::regclass,
           'effect_execution_protocol_activation_shape_check'),
          ('public.effect_execution_protocol_manifests'::regclass,
           'effect_execution_protocol_manifest_singleton_check'),
          ('public.effect_termination_attestations'::regclass,
           'effect_termination_attestations_shape_check'),
          ('public.effects'::regclass, 'effects_execution_status_check'),
          ('public.effects'::regclass, 'effects_generation_fenced_shape_check')
        )
      ),
      (
        SELECT jsonb_object_agg(function_row.proname, md5(function_row.prosrc))
        FROM pg_catalog.pg_proc AS function_row
        WHERE function_row.oid IN (
          'public.generation_fenced_effect_index_matches(text)'::regprocedure,
          'public.generation_fenced_effect_indexes_ready_count()'::regprocedure,
          'public.enforce_effect_execution_protocol()'::regprocedure,
          'public.enforce_agent_directive_protocol()'::regprocedure,
          'public.enforce_effect_protocol_one_way()'::regprocedure,
          'public.enforce_effect_termination_attestation()'::regprocedure,
          'public.reject_durable_effect_truncate()'::regprocedure,
          'public.reject_effect_protocol_manifest_mutation()'::regprocedure
        )
      ),
      timezone('UTC', clock_timestamp()),
      timezone('UTC', clock_timestamp())
    ON CONFLICT (name) DO NOTHING
    """)
  end

  def down do
    raise "generation-fenced Effect execution is irreversible once expanded"
  end
end
