defmodule Maraithon.Repo.Migrations.AddOperationalPrivacyControls do
  use Ecto.Migration

  @moduledoc false

  # Existing durable tables can be large. Every heap change is a nullable,
  # metadata-only expansion and every index over an existing table is built
  # online. The operator code performs all cleanup in bounded locked batches.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute(
      "ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_erasure_requested_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE agent_directives ADD COLUMN IF NOT EXISTS terminal_acknowledged_at timestamp(6) without time zone"
    )

    create_privacy_retention_statuses()
    create_privacy_erasure_requests()
    create_privacy_erasure_agent_targets()
    create_privacy_erasure_provider_revocations()
    create_privacy_erasure_receipts()
    reconcile_erasure_schema()
    add_erasure_constraints()
    add_legacy_cascade_constraints()
    install_privacy_erasure_write_fence()
    install_effect_retention_guard()
    install_directive_retention_guard()
    install_operational_retention_guard()
    attest_operational_privacy_protocol()
    create_online_indexes()
  end

  def down do
    raise "operational privacy controls are irreversible after erasure or payload retention"
  end

  # 140007 is nontransactional so every retry must converge from either the
  # original schema or an interrupted earlier 140007 attempt.
  defp reconcile_erasure_schema do
    execute(
      "ALTER TABLE public.privacy_erasure_agent_targets " <>
        "DROP CONSTRAINT IF EXISTS privacy_erasure_agent_targets_agent_id_fkey"
    )

    execute("""
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

  defp install_privacy_erasure_write_fence do
    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_privacy_erasure_write_fence()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $privacy$
    DECLARE
      old_user_id text;
      new_user_id text;
      expected_user_count integer;
      locked_user_count integer;
      erasure_requested boolean;
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

      IF erasure_requested THEN
        RAISE EXCEPTION 'Writes are fenced after privacy erasure is requested'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $privacy$;
    """)

    execute("""
    CREATE OR REPLACE TRIGGER enforce_users_privacy_erasure_write_fence
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.enforce_privacy_erasure_write_fence()
    """)

    for table <- ~w(
          agents oauth_tokens connected_accounts user_sessions user_magic_links
          companion_devices companion_device_keys mobile_node_pairings
          mobile_node_devices mobile_push_devices background_jobs
        ) do
      execute("""
      CREATE OR REPLACE TRIGGER enforce_#{table}_privacy_erasure_write_fence
      BEFORE INSERT OR UPDATE ON public.#{table}
      FOR EACH ROW EXECUTE FUNCTION public.enforce_privacy_erasure_write_fence()
      """)
    end
  end

  defp install_effect_retention_guard do
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
  end

  defp install_directive_retention_guard do
    execute("""
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
    execute("""
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
            'payload_binding_key_tag', 'payload_binding_mac',
            'result_purged_at', 'updated_at'
          ]::text[]) IS NOT DISTINCT FROM
          (to_jsonb(OLD) - ARRAY[
            'result', 'result_ciphertext', 'payload_binding_version',
            'payload_binding_key_tag', 'payload_binding_mac',
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

      execute("""
      CREATE OR REPLACE TRIGGER #{trigger}
      BEFORE UPDATE ON public.#{table}
      FOR EACH ROW EXECUTE FUNCTION public.enforce_operational_privacy_retention()
      """)
    end
  end

  defp attest_operational_privacy_protocol do
    execute("""
    CREATE TABLE IF NOT EXISTS public.privacy_protocol_manifests (
      name varchar(80) PRIMARY KEY,
      migration_version bigint NOT NULL,
      function_fingerprints jsonb NOT NULL,
      trigger_fingerprints jsonb NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT privacy_protocol_manifests_singleton_check CHECK (
        name = 'operational_privacy_140007'
        AND migration_version = 20260810140007
        AND jsonb_typeof(function_fingerprints) = 'object'
        AND jsonb_typeof(trigger_fingerprints) = 'object'
      )
    )
    """)

    execute("""
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
    BEGIN
      IF OLD.mode = 'legacy' AND NEW.mode = 'generation_fenced_v1' THEN
        SELECT COUNT(*) = 3 INTO migrations_ready
        FROM public.schema_migrations
        WHERE version IN (20260810140002, 20260810140005, 20260810140007);

        IF NOT migrations_ready THEN
          RAISE EXCEPTION 'Exact activation requires recorded privacy migrations through 140007'
            USING ERRCODE = 'check_violation';
        END IF;

        WITH required(function_id) AS (
          VALUES
            ('public.enforce_effect_execution_protocol()'::regprocedure),
            ('public.enforce_agent_directive_protocol()'::regprocedure),
            ('public.enforce_conversation_privacy_protocol()'::regprocedure),
            ('public.enforce_operational_privacy_retention()'::regprocedure),
            ('public.enforce_privacy_erasure_write_fence()'::regprocedure),
            ('public.enforce_operational_privacy_activation()'::regprocedure)
        )
        SELECT COUNT(*) INTO functions_ready
        FROM required
        JOIN pg_catalog.pg_proc AS function_row
          ON function_row.oid = required.function_id
         AND function_row.provolatile = 'v'
         AND NOT function_row.prosecdef
         AND function_row.proconfig = ARRAY['search_path=pg_catalog, public']::text[]
        JOIN pg_catalog.pg_language AS language_row
          ON language_row.oid = function_row.prolang
         AND language_row.lanname = 'plpgsql'
        JOIN public.privacy_protocol_manifests AS manifest
          ON manifest.name = 'operational_privacy_140007'
         AND manifest.migration_version = 20260810140007
         AND manifest.function_fingerprints ->> function_row.proname =
               md5(function_row.prosrc);

        IF functions_ready <> 6 THEN
          RAISE EXCEPTION 'Exact activation requires attested privacy functions'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT COUNT(*) INTO retention_triggers_ready
        FROM pg_catalog.pg_trigger AS trigger_row
        JOIN pg_catalog.pg_proc AS function_row
          ON function_row.oid = trigger_row.tgfoid
        JOIN public.privacy_protocol_manifests AS manifest
          ON manifest.name = 'operational_privacy_140007'
         AND manifest.trigger_fingerprints ->> trigger_row.tgname =
               md5(pg_catalog.pg_get_triggerdef(trigger_row.oid, true))
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
         AND manifest.trigger_fingerprints ->> trigger_row.tgname =
               md5(pg_catalog.pg_get_triggerdef(trigger_row.oid, true));

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
         AND manifest.trigger_fingerprints ->> trigger_row.tgname =
               md5(pg_catalog.pg_get_triggerdef(trigger_row.oid, true));

        IF erasure_triggers_ready <> 12 THEN
          RAISE EXCEPTION 'Exact activation requires every privacy erasure write fence'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $privacy$;
    """)

    execute("""
    CREATE OR REPLACE TRIGGER enforce_operational_privacy_activation_trigger
    BEFORE UPDATE ON public.effect_execution_protocols
    FOR EACH ROW EXECUTE FUNCTION public.enforce_operational_privacy_activation()
    """)

    execute("""
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

    refresh_privacy_manifest()
    refresh_effect_manifest()

    execute("""
    CREATE OR REPLACE TRIGGER reject_privacy_protocol_manifest_mutation_trigger
    BEFORE UPDATE OR DELETE ON public.privacy_protocol_manifests
    FOR EACH ROW EXECUTE FUNCTION public.reject_privacy_protocol_manifest_mutation()
    """)
  end

  defp refresh_privacy_manifest do
    execute("""
    DO $privacy$
    DECLARE
      mutation_trigger_present boolean;
    BEGIN
      SELECT EXISTS (
        SELECT 1 FROM pg_catalog.pg_trigger
        WHERE tgrelid = 'public.privacy_protocol_manifests'::regclass
          AND tgname = 'reject_privacy_protocol_manifest_mutation_trigger'
          AND NOT tgisinternal
      ) INTO mutation_trigger_present;

      IF mutation_trigger_present THEN
        EXECUTE 'ALTER TABLE public.privacy_protocol_manifests '
                'DISABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger';
      END IF;

      INSERT INTO public.privacy_protocol_manifests (
        name, migration_version, function_fingerprints, trigger_fingerprints,
        inserted_at, updated_at
      )
      SELECT
        'operational_privacy_140007',
        20260810140007,
        (
          SELECT jsonb_object_agg(function_row.proname, md5(function_row.prosrc))
          FROM pg_catalog.pg_proc AS function_row
          WHERE function_row.oid IN (
            'public.enforce_effect_execution_protocol()'::regprocedure,
            'public.enforce_agent_directive_protocol()'::regprocedure,
            'public.enforce_conversation_privacy_protocol()'::regprocedure,
            'public.enforce_operational_privacy_retention()'::regprocedure,
            'public.enforce_privacy_erasure_write_fence()'::regprocedure,
            'public.enforce_operational_privacy_activation()'::regprocedure,
            'public.reject_privacy_protocol_manifest_mutation()'::regprocedure
          )
        ),
        (
          SELECT jsonb_object_agg(
                   trigger_row.tgname,
                   md5(pg_catalog.pg_get_triggerdef(trigger_row.oid, true))
                 )
          FROM pg_catalog.pg_trigger AS trigger_row
          WHERE NOT trigger_row.tgisinternal
            AND trigger_row.tgfoid IN (
              'public.enforce_effect_execution_protocol()'::regprocedure,
              'public.enforce_agent_directive_protocol()'::regprocedure,
              'public.enforce_conversation_privacy_protocol()'::regprocedure,
              'public.enforce_operational_privacy_retention()'::regprocedure,
              'public.enforce_privacy_erasure_write_fence()'::regprocedure,
              'public.enforce_operational_privacy_activation()'::regprocedure
            )
        ),
        timezone('UTC', clock_timestamp()),
        timezone('UTC', clock_timestamp())
      ON CONFLICT (name) DO UPDATE SET
        migration_version = EXCLUDED.migration_version,
        function_fingerprints = EXCLUDED.function_fingerprints,
        trigger_fingerprints = EXCLUDED.trigger_fingerprints,
        updated_at = EXCLUDED.updated_at;

      IF mutation_trigger_present THEN
        EXECUTE 'ALTER TABLE public.privacy_protocol_manifests '
                'ENABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger';
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        IF mutation_trigger_present THEN
          EXECUTE 'ALTER TABLE public.privacy_protocol_manifests '
                  'ENABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger';
        END IF;
        RAISE;
    END;
    $privacy$
    """)
  end

  defp refresh_effect_manifest do
    execute("""
    DO $privacy$
    DECLARE
      mutation_trigger_present boolean;
    BEGIN
      SELECT EXISTS (
        SELECT 1 FROM pg_catalog.pg_trigger
        WHERE tgrelid = 'public.effect_execution_protocol_manifests'::regclass
          AND tgname = 'reject_effect_protocol_manifest_mutation_trigger'
          AND NOT tgisinternal
      ) INTO mutation_trigger_present;

      IF mutation_trigger_present THEN
        EXECUTE 'ALTER TABLE public.effect_execution_protocol_manifests '
                'DISABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger';
      END IF;

      UPDATE public.effect_execution_protocol_manifests AS manifest
      SET function_fingerprints = manifest.function_fingerprints || fingerprints.value,
          updated_at = timezone('UTC', clock_timestamp())
      FROM (
        SELECT jsonb_object_agg(function_row.proname, md5(function_row.prosrc)) AS value
        FROM pg_catalog.pg_proc AS function_row
        WHERE function_row.oid IN (
          'public.enforce_effect_execution_protocol()'::regprocedure,
          'public.enforce_agent_directive_protocol()'::regprocedure
        )
      ) AS fingerprints
      WHERE manifest.name = 'effects';

      IF mutation_trigger_present THEN
        EXECUTE 'ALTER TABLE public.effect_execution_protocol_manifests '
                'ENABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger';
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        IF mutation_trigger_present THEN
          EXECUTE 'ALTER TABLE public.effect_execution_protocol_manifests '
                  'ENABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger';
        END IF;
        RAISE;
    END;
    $privacy$
    """)
  end

  defp create_privacy_retention_statuses do
    execute("""
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
    execute("""
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
    execute("""
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
    execute("""
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
    execute("""
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

  defp create_online_indexes do
    # These tables are new in this migration; ordinary CREATE INDEX is atomic,
    # so an interrupted statement cannot leave a same-name invalid shell.
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS privacy_erasure_requests_active_user_index
    ON privacy_erasure_requests (subject_user_id)
    WHERE scope = 'user' AND state <> 'completed' AND subject_user_id IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS privacy_erasure_requests_active_agent_index
    ON privacy_erasure_requests (subject_agent_id)
    WHERE scope = 'agent' AND state <> 'completed' AND subject_agent_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS privacy_erasure_requests_work_index
    ON privacy_erasure_requests (last_attempted_at NULLS FIRST, requested_at, id)
    WHERE state <> 'completed'
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS privacy_erasure_agent_targets_identity_index
    ON privacy_erasure_agent_targets (request_id, agent_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS privacy_erasure_agent_targets_work_index
    ON privacy_erasure_agent_targets (request_id, state, last_attempted_at, id)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS privacy_erasure_provider_revocations_identity_index
    ON privacy_erasure_provider_revocations (request_id, credential_table, credential_row_id)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS privacy_erasure_receipts_request_index
    ON privacy_erasure_receipts (request_id)
    """)

    execute("""
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
  end

  defp create_retry_safe_concurrent_index(name, statement) do
    execute("DROP INDEX CONCURRENTLY IF EXISTS public.#{name}")
    execute(statement)
  end

  defp add_constraint_unless_present(table, name, definition) do
    execute("""
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
