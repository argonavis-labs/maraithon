defmodule Maraithon.Repo.Migrations.CreateDurablePayloadVerifications do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public")

    execute("""
    DO $role$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'maraithon_payload_verifier') THEN
        CREATE ROLE maraithon_payload_verifier NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
      END IF;
    EXCEPTION
      WHEN insufficient_privilege THEN
        RAISE EXCEPTION 'Provision the NOLOGIN maraithon_payload_verifier role before migration';
    END
    $role$
    """)

    execute(
      "ALTER TABLE public.events ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    execute(
      "ALTER TABLE public.agent_run_steps ADD COLUMN IF NOT EXISTS payload_encryption_version smallint"
    )

    for table <- ~w(effects agent_directives events agent_run_steps) do
      execute(
        "ALTER TABLE public.#{table} ADD COLUMN IF NOT EXISTS payload_binding_version smallint"
      )

      execute(
        "ALTER TABLE public.#{table} ADD COLUMN IF NOT EXISTS payload_binding_key_tag varchar(64)"
      )

      execute("ALTER TABLE public.#{table} ADD COLUMN IF NOT EXISTS payload_binding_mac bytea")

      execute("""
      DO $constraint$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_catalog.pg_constraint
          WHERE conrelid = 'public.#{table}'::regclass
            AND conname = '#{table}_payload_binding_shape_check'
        ) THEN
          ALTER TABLE public.#{table}
          ADD CONSTRAINT #{table}_payload_binding_shape_check
          CHECK (
            (payload_binding_version IS NULL
              AND payload_binding_key_tag IS NULL
              AND payload_binding_mac IS NULL) OR
            (payload_binding_version = 1
              AND payload_binding_key_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
              AND octet_length(payload_binding_mac) = 32)
          ) NOT VALID;
        END IF;
      END
      $constraint$
      """)
    end

    add_not_valid_constraint(
      "effects",
      "effects_durable_payload_storage_bound",
      """
      (params_ciphertext IS NULL OR octet_length(params_ciphertext) <= 200000)
      AND (result_ciphertext IS NULL OR octet_length(result_ciphertext) <= 600000)
      AND pg_column_size(params) <= 200000
      AND (result IS NULL OR pg_column_size(result) <= 600000)
      """
    )

    add_not_valid_constraint(
      "agent_directives",
      "agent_directives_durable_payload_storage_bound",
      """
      (payload_ciphertext IS NULL OR octet_length(payload_ciphertext) <= 180000)
      AND pg_column_size(payload) <= 160000
      """
    )

    add_not_valid_constraint(
      "events",
      "events_payload_encryption_version_check",
      "payload_encryption_version IS NULL OR payload_encryption_version = 1"
    )

    add_not_valid_constraint(
      "agent_run_steps",
      "agent_run_steps_payload_encryption_version_check",
      "payload_encryption_version IS NULL OR payload_encryption_version = 1"
    )

    create table(:durable_payload_verifications, primary_key: false) do
      add :payload_table, :string, null: false
      add :row_identity, :uuid, null: false
      add :ciphertext_digest, :binary, null: false
      add :projection_digest, :binary, null: false
      add :version_digest, :binary, null: false
      add :purge_digest, :binary, null: false
      add :key_tags, {:array, :string}, null: false, default: []
      add :verified_at, :utc_datetime_usec, null: false
    end

    create unique_index(:durable_payload_verifications, [:payload_table, :row_identity],
             name: :durable_payload_verifications_pkey
           )

    create index(:durable_payload_verifications, [:payload_table, :verified_at],
             name: :durable_payload_verifications_verified_at_index
           )

    create constraint(:durable_payload_verifications, :durable_payload_verifications_table_check,
             check: "payload_table ~ '^[a-z][a-z0-9_]{0,62}$'"
           )

    create constraint(:durable_payload_verifications, :durable_payload_verifications_digest_check,
             check: """
             octet_length(ciphertext_digest) = 32
             AND octet_length(projection_digest) = 32
             AND octet_length(version_digest) = 32
             AND octet_length(purge_digest) = 32
             """
           )

    create constraint(:durable_payload_verifications, :durable_payload_verifications_tags_check,
             check: """
             cardinality(key_tags) <= 8
             AND (
               cardinality(key_tags) = 0 OR
               array_to_string(key_tags, ',') ~
                 '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}(,[A-Za-z0-9][A-Za-z0-9._:-]{0,63})*$'
             )
             """
           )

    create table(:durable_payload_verification_failures, primary_key: false) do
      add :payload_table, :string, null: false
      add :row_identity, :uuid, null: false
      add :failure_class, :string, null: false
      add :failed_at, :utc_datetime_usec, null: false
    end

    create unique_index(:durable_payload_verification_failures, [:payload_table, :row_identity],
             name: :durable_payload_verification_failures_pkey
           )

    create index(:durable_payload_verification_failures, [:failed_at],
             name: :durable_payload_verification_failures_failed_at_index
           )

    create constraint(
             :durable_payload_verification_failures,
             :durable_payload_verification_failures_shape_check,
             check: """
             payload_table ~ '^[a-z][a-z0-9_]{0,62}$'
             AND failure_class ~ '^[a-z][a-z0-9_]{0,62}$'
             """
           )

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_row_identity(
      source_table text,
      source_id text
    )
    RETURNS uuid
    LANGUAGE sql
    IMMUTABLE
    STRICT
    SET search_path = pg_catalog, public
    AS $function$
      SELECT CASE source_table
        WHEN 'events' THEN md5('maraithon:durable-payload-row:v1:events:' || source_id)::uuid
        WHEN 'effects' THEN source_id::uuid
        WHEN 'agent_directives' THEN source_id::uuid
        WHEN 'agent_run_steps' THEN source_id::uuid
        ELSE NULL::uuid
      END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_digest_part(
      source_table text,
      source_row jsonb,
      digest_part text
    )
    RETURNS bytea
    LANGUAGE sql
    IMMUTABLE
    STRICT
    SET search_path = pg_catalog, public
    AS $function$
      SELECT public.digest(
        pg_catalog.convert_to(
          jsonb_build_object(
            'domain', 'maraithon:durable-payload-proof:v1',
            'table', source_table,
            'part', digest_part,
            'value',
              CASE digest_part
                WHEN 'ciphertext' THEN
                  CASE source_table
                    WHEN 'effects' THEN jsonb_build_array(
                      source_row -> 'params_ciphertext',
                      source_row -> 'result_ciphertext'
                    )
                    WHEN 'agent_directives' THEN
                      jsonb_build_array(source_row -> 'payload_ciphertext')
                    WHEN 'events' THEN
                      jsonb_build_array(source_row -> 'payload_ciphertext')
                    WHEN 'agent_run_steps' THEN jsonb_build_array(
                      source_row -> 'request_payload_ciphertext',
                      source_row -> 'response_payload_ciphertext'
                    )
                  END
                WHEN 'projection' THEN
                  CASE source_table
                    WHEN 'effects' THEN
                      jsonb_build_array(source_row -> 'params', source_row -> 'result')
                    WHEN 'agent_directives' THEN
                      jsonb_build_array(source_row -> 'payload')
                    WHEN 'events' THEN
                      jsonb_build_array(source_row -> 'payload')
                    WHEN 'agent_run_steps' THEN jsonb_build_array(
                      source_row -> 'request_payload',
                      source_row -> 'response_payload'
                    )
                  END
                WHEN 'version' THEN jsonb_build_array(
                  source_row -> 'payload_encryption_version',
                  source_row -> 'payload_binding_version',
                  source_row -> 'payload_binding_key_tag',
                  source_row -> 'payload_binding_mac'
                )
                WHEN 'purge' THEN
                  jsonb_build_array(source_row -> 'payload_purged_at')
              END
          )::text,
          'UTF8'
        ),
        'sha256'
      );
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_proof_failures()
    RETURNS bigint
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      failure_count bigint;
    BEGIN
      EXECUTE $proof_query$
        WITH source_rows AS (
          SELECT
            'effects'::text AS payload_table,
            public.durable_payload_row_identity('effects', source.id::text) AS row_identity,
            to_jsonb(source) AS source_row,
            source.payload_purged_at IS NULL AS proof_required,
            (source.payload_encryption_version = 1
              AND source.params = '{"redacted": true}'::jsonb
              AND source.result IS NULL
              AND (
                (source.payload_purged_at IS NULL
                  AND source.params_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND source.params_ciphertext IS NULL
                  AND source.result_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE AS shape_valid
          FROM public.effects AS source

          UNION ALL

          SELECT
            'agent_directives',
            public.durable_payload_row_identity('agent_directives', source.id::text),
            to_jsonb(source),
            source.payload_purged_at IS NULL OR source.payload_ciphertext IS NOT NULL,
            (source.payload_encryption_version = 1
              AND source.payload = '{"redacted": true}'::jsonb
              AND (
                (source.payload_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND source.payload_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )
            ) IS TRUE
          FROM public.agent_directives AS source

          UNION ALL

          SELECT
            'events',
            public.durable_payload_row_identity(
              'events', source.agent_id::text || ':' || source.sequence_num::text
            ),
            to_jsonb(source),
            source.payload_purged_at IS NULL,
            (source.payload = '{}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.payload_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND source.payload_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE
          FROM public.events AS source

          UNION ALL

          SELECT
            'agent_run_steps',
            public.durable_payload_row_identity('agent_run_steps', source.id::text),
            to_jsonb(source),
            source.payload_purged_at IS NULL,
            (source.request_payload = '{}'::jsonb
              AND source.response_payload = '{}'::jsonb
              AND (
                (source.payload_purged_at IS NULL
                  AND source.payload_encryption_version = 1
                  AND source.request_payload_ciphertext IS NOT NULL
                  AND source.response_payload_ciphertext IS NOT NULL
                  AND source.payload_binding_version = 1
                  AND source.payload_binding_key_tag IS NOT NULL
                  AND octet_length(source.payload_binding_mac) = 32) OR
                (source.payload_purged_at IS NOT NULL
                  AND source.request_payload_ciphertext IS NULL
                  AND source.response_payload_ciphertext IS NULL
                  AND source.payload_binding_version IS NULL
                  AND source.payload_binding_key_tag IS NULL
                  AND source.payload_binding_mac IS NULL)
              )) IS TRUE
          FROM public.agent_run_steps AS source
        )
        SELECT COUNT(*)
        FROM source_rows AS source
        LEFT JOIN public.durable_payload_verifications AS proof
          ON proof.payload_table = source.payload_table
         AND proof.row_identity = source.row_identity
        WHERE NOT source.shape_valid
           OR (source.proof_required AND (
             proof.row_identity IS NULL OR
             proof.ciphertext_digest IS DISTINCT FROM
               public.durable_payload_digest_part(
                 source.payload_table, source.source_row, 'ciphertext'
               ) OR
             proof.projection_digest IS DISTINCT FROM
               public.durable_payload_digest_part(
                 source.payload_table, source.source_row, 'projection'
               ) OR
             proof.version_digest IS DISTINCT FROM
               public.durable_payload_digest_part(
                 source.payload_table, source.source_row, 'version'
               ) OR
             proof.purge_digest IS DISTINCT FROM
               public.durable_payload_digest_part(
                 source.payload_table, source.source_row, 'purge'
               )
           ))
      $proof_query$
      INTO failure_count;

      RETURN failure_count;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.durable_payload_roles_ready()
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      roles_ready boolean;
    BEGIN
      EXECUTE $role_query$
        SELECT COALESCE((
          SELECT
            NOT verifier.rolcanlogin
            AND NOT verifier.rolsuper
            AND NOT verifier.rolcreatedb
            AND NOT verifier.rolcreaterole
            AND NOT verifier.rolreplication
            AND NOT verifier.rolbypassrls
            AND NOT pg_has_role(session_user, verifier.oid, 'member')
            AND NOT EXISTS (
              SELECT 1
              FROM pg_catalog.pg_class AS relation
              WHERE relation.relowner = verifier.oid
                AND relation.oid IN (
                  'public.durable_payload_verifications'::regclass,
                  'public.durable_payload_verification_failures'::regclass,
                  'public.effects'::regclass,
                  'public.agent_directives'::regclass,
                  'public.events'::regclass,
                  'public.agent_run_steps'::regclass,
                  'public.effect_execution_protocols'::regclass
                )
            )
            AND has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'SELECT')
            AND has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'INSERT')
            AND has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'DELETE')
            AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'UPDATE')
            AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verifications', 'TRUNCATE')
            AND has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'SELECT')
            AND has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'INSERT')
            AND has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'DELETE')
            AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'UPDATE')
            AND NOT has_table_privilege(verifier.rolname, 'public.durable_payload_verification_failures', 'TRUNCATE')
            AND has_column_privilege(verifier.rolname, 'public.effects', 'payload_binding_mac', 'UPDATE')
            AND has_column_privilege(verifier.rolname, 'public.agent_directives', 'payload_binding_mac', 'UPDATE')
            AND has_column_privilege(verifier.rolname, 'public.events', 'payload_binding_mac', 'UPDATE')
            AND has_column_privilege(verifier.rolname, 'public.agent_run_steps', 'payload_binding_mac', 'UPDATE')
            AND NOT has_column_privilege(verifier.rolname, 'public.effects', 'params_ciphertext', 'UPDATE')
            AND NOT has_column_privilege(verifier.rolname, 'public.agent_directives', 'payload_ciphertext', 'UPDATE')
            AND NOT has_column_privilege(verifier.rolname, 'public.events', 'payload_ciphertext', 'UPDATE')
            AND NOT has_column_privilege(
              verifier.rolname,
              'public.agent_run_steps',
              'request_payload_ciphertext',
              'UPDATE'
            )
            AND NOT has_table_privilege(
              session_user,
              'public.durable_payload_verifications',
              'INSERT'
            )
            AND NOT has_table_privilege(
              session_user,
              'public.durable_payload_verifications',
              'UPDATE'
            )
          FROM pg_catalog.pg_roles AS verifier
          WHERE verifier.rolname = 'maraithon_payload_verifier'
        ), false)
      $role_query$
      INTO roles_ready;

      RETURN roles_ready;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_durable_history_payload_protocol()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      protocol_mode text;
      writer_protocol text;
      valid_shape boolean;
    BEGIN
      SELECT mode INTO STRICT protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects'
      FOR SHARE;

      IF protocol_mode = 'legacy' THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
      END IF;

      IF protocol_mode <> 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Unknown durable history payload protocol mode'
          USING ERRCODE = 'check_violation';
      END IF;

      writer_protocol := current_setting('maraithon.effect_writer_protocol', true);

      IF writer_protocol IS DISTINCT FROM 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Exact durable history mutation requires generation-fenced writer marker'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      valid_shape := CASE TG_TABLE_NAME
        WHEN 'events' THEN
          NEW.payload = '{}'::jsonb
          AND (
            (NEW.payload_purged_at IS NULL
              AND NEW.payload_encryption_version = 1
              AND NEW.payload_ciphertext IS NOT NULL
              AND NEW.payload_binding_version = 1
              AND NEW.payload_binding_key_tag IS NOT NULL
              AND octet_length(NEW.payload_binding_mac) = 32) OR
            (NEW.payload_purged_at IS NOT NULL
              AND NEW.payload_ciphertext IS NULL
              AND NEW.payload_binding_version IS NULL
              AND NEW.payload_binding_key_tag IS NULL
              AND NEW.payload_binding_mac IS NULL)
          )
        WHEN 'agent_run_steps' THEN
          NEW.request_payload = '{}'::jsonb
          AND NEW.response_payload = '{}'::jsonb
          AND (
            (NEW.payload_purged_at IS NULL
              AND NEW.payload_encryption_version = 1
              AND NEW.request_payload_ciphertext IS NOT NULL
              AND NEW.response_payload_ciphertext IS NOT NULL
              AND NEW.payload_binding_version = 1
              AND NEW.payload_binding_key_tag IS NOT NULL
              AND octet_length(NEW.payload_binding_mac) = 32) OR
            (NEW.payload_purged_at IS NOT NULL
              AND NEW.request_payload_ciphertext IS NULL
              AND NEW.response_payload_ciphertext IS NULL
              AND NEW.payload_binding_version IS NULL
              AND NEW.payload_binding_key_tag IS NULL
              AND NEW.payload_binding_mac IS NULL)
          )
        ELSE false
      END;

      IF NOT (valid_shape IS TRUE) THEN
        RAISE EXCEPTION 'Exact durable history payload must remain encrypted or authoritatively purged'
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

    execute("""
    CREATE OR REPLACE FUNCTION public.guard_durable_payload_verification_failure_write()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF NOT pg_has_role(session_user, 'maraithon_payload_verifier', 'member') OR
         current_setting('maraithon.durable_payload_verifier', true)
           IS DISTINCT FROM 'VAULT_AUTHENTICATED_V1' THEN
        RAISE EXCEPTION 'Only the Vault verification operator may record verification failures'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      NEW.failed_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    END;
    $function$;
    """)

    execute("""
    CREATE TRIGGER guard_durable_payload_verification_failure_write_trigger
      BEFORE INSERT OR UPDATE ON public.durable_payload_verification_failures
      FOR EACH ROW EXECUTE FUNCTION public.guard_durable_payload_verification_failure_write()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.guard_durable_payload_verification_write()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Durable payload proofs are immutable; delete and reverify'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF NOT pg_has_role(session_user, 'maraithon_payload_verifier', 'member') OR
         current_setting('maraithon.durable_payload_verifier', true)
           IS DISTINCT FROM 'VAULT_AUTHENTICATED_V1' THEN
        RAISE EXCEPTION 'Only the Vault verification operator may insert durable payload proofs'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      NEW.verified_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    END;
    $function$;
    """)

    execute("""
    CREATE TRIGGER guard_durable_payload_verification_write_trigger
      BEFORE INSERT OR UPDATE ON public.durable_payload_verifications
      FOR EACH ROW EXECUTE FUNCTION public.guard_durable_payload_verification_write()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.delete_durable_payload_verification(
      source_table text,
      source_identity uuid
    )
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      DELETE FROM public.durable_payload_verifications
      WHERE payload_table = source_table
        AND row_identity = source_identity;

      DELETE FROM public.durable_payload_verification_failures
      WHERE payload_table = source_table
        AND row_identity = source_identity;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.invalidate_durable_payload_verification()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      source_row jsonb;
      source_identity uuid;
    BEGIN
      source_row := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
      source_identity := public.durable_payload_row_identity(
        TG_TABLE_NAME,
        CASE TG_TABLE_NAME
          WHEN 'events' THEN (source_row ->> 'agent_id') || ':' || (source_row ->> 'sequence_num')
          ELSE source_row ->> 'id'
        END
      );

      PERFORM public.delete_durable_payload_verification(TG_TABLE_NAME, source_identity);

      RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END;
    $function$;
    """)

    for table <- ~w(effects agent_directives events agent_run_steps) do
      execute(
        "DROP TRIGGER IF EXISTS invalidate_durable_payload_verification_trigger ON public.#{table}"
      )

      execute("""
      CREATE TRIGGER invalidate_durable_payload_verification_trigger
        AFTER INSERT OR UPDATE OR DELETE ON public.#{table}
        FOR EACH ROW EXECUTE FUNCTION public.invalidate_durable_payload_verification()
      """)
    end

    for table <- ~w(events agent_run_steps) do
      execute(
        "DROP TRIGGER IF EXISTS enforce_durable_history_payload_protocol_trigger ON public.#{table}"
      )

      execute("""
      CREATE TRIGGER enforce_durable_history_payload_protocol_trigger
        BEFORE INSERT OR UPDATE OR DELETE ON public.#{table}
        FOR EACH ROW EXECUTE FUNCTION public.enforce_durable_history_payload_protocol()
      """)
    end

    execute("""
    CREATE TRIGGER reject_durable_payload_verifications_truncate_trigger
      BEFORE TRUNCATE ON public.durable_payload_verifications
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute("""
    CREATE TRIGGER reject_durable_payload_verification_failures_truncate_trigger
      BEFORE TRUNCATE ON public.durable_payload_verification_failures
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_durable_effect_truncate()
    """)

    execute("REVOKE ALL ON public.durable_payload_verifications FROM PUBLIC")
    execute("REVOKE ALL ON public.durable_payload_verification_failures FROM PUBLIC")

    execute("""
    DO $grants$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'maraithon_payload_verifier'
      ) THEN
        GRANT SELECT, INSERT, DELETE
          ON public.durable_payload_verifications
          TO maraithon_payload_verifier;
        GRANT SELECT, INSERT, DELETE
          ON public.durable_payload_verification_failures
          TO maraithon_payload_verifier;
        GRANT SELECT
          ON public.effect_execution_protocols
          TO maraithon_payload_verifier;
        GRANT SELECT
          ON public.effects, public.agent_directives, public.events, public.agent_run_steps
          TO maraithon_payload_verifier;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.effects TO maraithon_payload_verifier;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.agent_directives TO maraithon_payload_verifier;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.events TO maraithon_payload_verifier;
        GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac)
          ON public.agent_run_steps TO maraithon_payload_verifier;
      END IF;
    END
    $grants$
    """)
  end

  defp add_not_valid_constraint(table, name, expression) do
    execute("""
    DO $constraint$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint
        WHERE conrelid = 'public.#{table}'::regclass
          AND conname = '#{name}'
      ) THEN
        ALTER TABLE public.#{table}
        ADD CONSTRAINT #{name} CHECK (#{expression}) NOT VALID;
      END IF;
    END
    $constraint$
    """)
  end

  def down do
    raise "durable payload authentication proofs are an irreversible activation safety layer"
  end
end
