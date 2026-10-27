defmodule Maraithon.Repo.Migrations.AddDelegatedConversations do
  use Ecto.Migration

  @tables ~w(assistant_identities delegation_preferences delegations delegation_grants delegation_events delegation_turns)a

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")
    capture_catalogs()

    create table(:assistant_identities, primary_key: false) do
      payload_columns()
      add :gmail_connected_account_id, references(:connected_accounts, on_delete: :restrict)
      add :gmail_mode, :text, null: false, default: "account"
    end

    create unique_index(:assistant_identities, [:user_id])

    create constraint(:assistant_identities, :assistant_identities_mode,
             check: "gmail_mode IN ('account', 'alias')"
           )

    create table(:delegation_preferences, primary_key: false) do
      payload_columns()
    end

    create unique_index(:delegation_preferences, [:user_id])

    create table(:delegations, primary_key: false) do
      payload_columns()
      add :todo_id, references(:todos, type: :uuid, on_delete: :restrict), null: false
      # A coordinator is replaceable. Deleting its process record must not
      # delete the conversation or obstruct the runtime's fenced drain.
      add :agent_id, :uuid
      add :kind, :text, null: false, default: "information"
      add :actor, :text, null: false, default: "as_user"
      add :provider, :text, null: false

      add :connected_account_id, references(:connected_accounts, on_delete: :restrict),
        null: false

      add :provider_thread_id, :text
      add :slack_channel, :text
      add :state, :text, null: false, default: "ready"
      add :current_grant_id, :uuid
      add :revision, :bigint, null: false, default: 1
      add :source_revision, :bigint, null: false, default: 0
      add :workflow_revision, :bigint, null: false, default: 0
      add :next_wake_at, :utc_datetime_usec
      add :follow_up_at, :utc_datetime_usec
      add :deadline_at, :utc_datetime_usec
      add :last_action_id, :uuid
      add :reminder_count_cycle, :integer, null: false, default: 0
      add :lifetime_sends, :bigint, null: false, default: 0
      add :lifetime_micro_usd, :bigint, null: false, default: 0
      add :schema_version, :integer, null: false, default: 1
    end

    live = "state NOT IN ('completed', 'stopped', 'expired')"

    create unique_index(:delegations, [:user_id, :todo_id],
             name: :delegations_live_todo,
             where: live
           )

    create unique_index(
             :delegations,
             [:connected_account_id, :slack_channel, :provider_thread_id],
             name: :delegations_live_thread,
             where: live <> " AND provider_thread_id IS NOT NULL",
             nulls_distinct: false
           )

    create index(:delegations, [:user_id, :next_wake_at], where: live)
    create index(:delegations, [:agent_id])

    create constraint(:delegations, :delegations_kind,
             check: "kind IN ('information', 'scheduling', 'coordination')"
           )

    create constraint(:delegations, :delegations_actor,
             check: "actor IN ('as_user', 'as_assistant')"
           )

    create constraint(:delegations, :delegations_provider,
             check: "provider IN ('gmail', 'slack')"
           )

    create constraint(:delegations, :delegations_state,
             check:
               "state IN ('ready','syncing','deciding','sending','reconciling','waiting_reply','waiting_capacity','needs_user','paused','completed','stopped','expired')"
           )

    create constraint(:delegations, :delegations_counters,
             check:
               "revision > 0 AND source_revision >= 0 AND reminder_count_cycle >= 0 AND lifetime_sends >= 0 AND lifetime_micro_usd >= 0 AND schema_version = 1"
           )

    create table(:delegation_grants, primary_key: false) do
      payload_columns()

      add :delegation_id, references(:delegations, type: :uuid, on_delete: :delete_all),
        null: false

      add :version, :integer, null: false
      add :origin_request_id, :text, null: false
      add :control_state, :text, null: false, default: "active"
      add :policy_version, :integer, null: false, default: 1
    end

    create unique_index(:delegation_grants, [:delegation_id, :version])
    create unique_index(:delegation_grants, [:user_id, :origin_request_id])

    create constraint(:delegation_grants, :delegation_grants_control,
             check:
               "control_state IN ('active','paused','revoked','expired') AND version > 0 AND policy_version > 0"
           )

    create table(:delegation_turns, primary_key: false) do
      payload_columns()

      add :delegation_id, references(:delegations, type: :uuid, on_delete: :delete_all),
        null: false

      add :seq, :bigint, null: false
      add :grant_version, :integer, null: false
      add :source_revision, :bigint, null: false
      add :wake_reason, :text
      add :run_id, references(:telegram_assistant_runs, type: :uuid, on_delete: :restrict)

      add :prepared_action_id,
          references(:telegram_prepared_actions, type: :uuid, on_delete: :restrict)

      add :status, :text, null: false, default: "deciding"
      add :model, :text
      add :reserved_micro_usd, :bigint, null: false, default: 0
      add :cost_micro_usd, :bigint, null: false, default: 0
      add :model_calls, :integer, null: false, default: 0
      add :available_at, :utc_datetime_usec
    end

    create unique_index(:delegation_turns, [:delegation_id, :seq])

    create unique_index(:delegation_turns, [:delegation_id],
             name: :delegation_turns_one_live,
             where: "status IN ('deciding','validated','dispatched')"
           )

    create index(:delegation_turns, [:user_id, :inserted_at])
    create index(:delegation_turns, [:prepared_action_id])

    create constraint(:delegation_turns, :delegation_turns_status,
             check:
               "status IN ('deciding','validated','dispatched','settled','superseded','failed')"
           )

    create constraint(:delegation_turns, :delegation_turns_counters,
             check:
               "seq > 0 AND grant_version > 0 AND source_revision >= 0 AND reserved_micro_usd >= 0 AND cost_micro_usd >= 0 AND model_calls >= 0"
           )

    create table(:delegation_events, primary_key: false) do
      payload_columns()

      add :delegation_id, references(:delegations, type: :uuid, on_delete: :delete_all),
        null: false

      add :seq, :bigserial, null: false
      add :kind, :text, null: false
      add :event_key, :text, null: false
      add :source_ref, :text
      add :source_revision, :text
      add :occurred_at, :utc_datetime_usec, null: false
      add :consumed_by_turn_id, references(:delegation_turns, type: :uuid, on_delete: :restrict)
      add :wake_state, :text, null: false, default: "pending"
    end

    create unique_index(:delegation_events, [:delegation_id, :event_key])
    create index(:delegation_events, [:delegation_id, :seq])
    create index(:delegation_events, [:user_id, :seq], where: "wake_state <> 'consumed'")

    create constraint(:delegation_events, :delegation_events_wake,
             check: "wake_state IN ('pending','dispatched','consumed')"
           )

    execute(
      "ALTER TABLE delegations ADD CONSTRAINT delegations_current_grant_id_fkey FOREIGN KEY (current_grant_id) REFERENCES delegation_grants(id) DEFERRABLE INITIALLY DEFERRED"
    )

    record_guard()

    for table <- @tables do
      execute(
        "CREATE TRIGGER enforce_#{table}_privacy_erasure_write_fence BEFORE INSERT OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION public.enforce_privacy_erasure_write_fence()"
      )

      execute(
        "CREATE TRIGGER guard_#{table} BEFORE INSERT OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION public.guard_delegation_record()"
      )

      sql("ALTER TABLE #{table} OWNER TO maraithon_object_owner")
      sql("REVOKE ALL ON TABLE #{table} FROM PUBLIC")
      sql("GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE #{table} TO maraithon_runtime")

      sql(
        "GRANT SELECT ON TABLE #{table} TO maraithon_payload_verifier, maraithon_incident_operator, maraithon_activation_operator"
      )

      sql(
        "GRANT UPDATE (data_ciphertext, payload_encryption_version, payload_binding_version, payload_binding_key_tag, payload_binding_mac) ON TABLE #{table} TO maraithon_incident_operator"
      )

      sql(
        "GRANT UPDATE (payload_binding_version, payload_binding_key_tag, payload_binding_mac) ON TABLE #{table} TO maraithon_activation_operator"
      )

      create constraint(table, "#{table}_payload",
               check:
                 "(payload_purged_at IS NULL AND data_ciphertext IS NOT NULL AND payload_encryption_version = 1 AND payload_binding_version = 1 AND payload_binding_key_tag IS NOT NULL AND octet_length(payload_binding_mac) = 32) OR (payload_purged_at IS NOT NULL AND data_ciphertext IS NULL AND payload_binding_version IS NULL AND payload_binding_key_tag IS NULL AND payload_binding_mac IS NULL)"
             )
    end

    sql("ALTER SEQUENCE delegation_events_seq_seq OWNER TO maraithon_object_owner")
    sql("GRANT USAGE ON SEQUENCE delegation_events_seq_seq TO maraithon_runtime")
    sql("ALTER FUNCTION public.guard_delegation_record() OWNER TO maraithon_object_owner")
    sql("REVOKE ALL ON FUNCTION public.guard_delegation_record() FROM PUBLIC")

    sql(
      "GRANT EXECUTE ON FUNCTION public.guard_delegation_record() TO maraithon_runtime, maraithon_incident_operator, maraithon_activation_operator"
    )

    register_payloads()
    refresh_catalogs()
  end

  def down, do: raise("Delegation history requires a reviewed forward migration")

  defp payload_columns do
    add :id, :uuid, primary_key: true
    add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
    add :data_ciphertext, :binary
    add :payload_encryption_version, :integer, null: false, default: 1
    add :payload_binding_version, :integer
    add :payload_binding_key_tag, :text
    add :payload_binding_mac, :binary
    add :payload_purged_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  defp record_guard do
    execute("""
    CREATE FUNCTION public.guard_delegation_record() RETURNS trigger
    LANGUAGE plpgsql SET search_path = pg_catalog, public AS $guard$
    DECLARE row_data jsonb := to_jsonb(NEW); parent_user text; parent_delegation uuid;
    BEGIN
      IF TG_OP = 'UPDATE' AND (NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id) THEN
        RAISE EXCEPTION 'Delegation identity is immutable' USING ERRCODE = 'check_violation';
      END IF;
      IF row_data->>'delegation_id' IS NOT NULL THEN
        SELECT user_id INTO parent_user FROM public.delegations WHERE id = (row_data->>'delegation_id')::uuid;
        IF parent_user IS DISTINCT FROM NEW.user_id THEN
          RAISE EXCEPTION 'Delegation tenant mismatch' USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      IF TG_TABLE_NAME = 'delegations' THEN
        SELECT user_id INTO parent_user FROM public.todos WHERE id = NEW.todo_id;
        IF parent_user IS DISTINCT FROM NEW.user_id THEN
          RAISE EXCEPTION 'Todo tenant mismatch' USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.agent_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.agent_id IS DISTINCT FROM OLD.agent_id) THEN
          SELECT user_id INTO parent_user FROM public.agents WHERE id = NEW.agent_id;
          IF parent_user IS DISTINCT FROM NEW.user_id THEN
            RAISE EXCEPTION 'Agent tenant mismatch' USING ERRCODE = 'check_violation';
          END IF;
        END IF;
        IF NEW.current_grant_id IS NOT NULL THEN
          SELECT delegation_id INTO parent_delegation FROM public.delegation_grants WHERE id = NEW.current_grant_id;
          IF parent_delegation IS DISTINCT FROM NEW.id THEN
            RAISE EXCEPTION 'Grant scope mismatch' USING ERRCODE = 'check_violation';
          END IF;
        END IF;
      END IF;
      IF COALESCE(row_data->>'connected_account_id', row_data->>'gmail_connected_account_id') IS NOT NULL THEN
        SELECT user_id INTO parent_user FROM public.connected_accounts
        WHERE id = COALESCE(row_data->>'connected_account_id', row_data->>'gmail_connected_account_id')::bigint;
        IF parent_user IS DISTINCT FROM NEW.user_id THEN
          RAISE EXCEPTION 'Account tenant mismatch' USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      IF row_data->>'run_id' IS NOT NULL THEN
        SELECT user_id INTO parent_user FROM public.telegram_assistant_runs WHERE id = (row_data->>'run_id')::uuid;
        IF parent_user IS DISTINCT FROM NEW.user_id THEN
          RAISE EXCEPTION 'Run tenant mismatch' USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      IF row_data->>'prepared_action_id' IS NOT NULL THEN
        SELECT user_id INTO parent_user FROM public.telegram_prepared_actions WHERE id = (row_data->>'prepared_action_id')::uuid;
        IF parent_user IS DISTINCT FROM NEW.user_id THEN
          RAISE EXCEPTION 'Action tenant mismatch' USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      IF row_data->>'consumed_by_turn_id' IS NOT NULL THEN
        SELECT delegation_id INTO parent_delegation FROM public.delegation_turns WHERE id = (row_data->>'consumed_by_turn_id')::uuid;
        IF parent_delegation IS DISTINCT FROM (row_data->>'delegation_id')::uuid THEN
          RAISE EXCEPTION 'Event turn mismatch' USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      IF TG_TABLE_NAME = 'delegation_grants' AND TG_OP = 'UPDATE' AND
         row_data IS DISTINCT FROM to_jsonb(OLD) THEN
        IF current_user NOT IN ('maraithon_incident_operator','maraithon_activation_operator') THEN
          RAISE EXCEPTION 'Delegation grants are immutable' USING ERRCODE = 'check_violation';
        ELSIF NOT public.durable_payload_operator_row_mutation_authorized(
          TG_RELID, TG_OP, to_jsonb(OLD), row_data) THEN
          RAISE EXCEPTION 'Delegation grant rotation is outside reviewed authority' USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      RETURN NEW;
    END; $guard$;
    """)
  end

  defp capture_catalogs do
    execute("""
    DO $check$ BEGIN
      IF NOT public.privacy_protocol_catalog_ready() OR
         NOT public.durable_payload_catalog_ready() OR
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Delegation storage requires a verified catalog baseline';
      END IF;
    CREATE TEMP TABLE delegation_prior_catalogs ON COMMIT DROP AS
      SELECT function_fingerprints AS functions, trigger_fingerprints AS triggers,
        catalog_fingerprints AS catalogs,
        public.durable_payload_catalog_manifest_snapshot() AS payload
      FROM public.privacy_protocol_manifests
      WHERE name = 'operational_privacy_140007' AND migration_version = 20260810140007;
    END $check$;
    """)
  end

  # Extend the existing key lifecycle rather than introducing another cipher or
  # rotation protocol. Every replacement has one checked anchor and the final
  # refresh admits only the exact functions and new relations reviewed here.
  defp register_payloads do
    tables = Enum.map_join(@tables, ", ", &"public.#{&1}")
    table_literals = Enum.map_join(@tables, ",", &literal(to_string(&1)))

    patch("durable_payload_row_identity(text,text)", [
      {"WHEN source_table IN (", "WHEN source_table IN (#{table_literals},"}
    ])

    patch(
      "durable_payload_digest_part(text,jsonb,text)",
      Enum.map(
        [
          {"'state_data_ciphertext', source_row -> 'budget_ciphertext'",
           "jsonb_build_array(source_row -> 'data_ciphertext')"},
          {"'state_data', source_row -> 'budget'", "'[]'::jsonb"},
          {"'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'agent_id', source_row -> 'sequence_num', source_row -> 'schema_version', source_row -> 'state_name'",
           "source_row - ARRAY['data_ciphertext','inserted_at','updated_at','payload_purged_at']"},
          {"'payload_purged_at'", "jsonb_build_array(source_row -> 'payload_purged_at')"}
        ],
        fn {fields, value} ->
          anchor = "WHEN 'snapshots' THEN jsonb_build_array(source_row -> #{fields})"
          {anchor, Enum.map_join(@tables, "\n", &"WHEN '#{&1}' THEN #{value}") <> "\n" <> anchor}
        end
      )
    )

    new_sources =
      Enum.map_join(@tables, "\nUNION ALL\n", fn table ->
        """
        SELECT '#{table}', source.id::text, to_jsonb(source), source.payload_purged_at IS NULL,
          ((source.payload_purged_at IS NULL AND source.data_ciphertext IS NOT NULL AND
            source.payload_encryption_version = 1 AND source.payload_binding_version = 1 AND
            source.payload_binding_key_tag IS NOT NULL AND octet_length(source.payload_binding_mac) = 32) OR
           (source.payload_purged_at IS NOT NULL AND source.data_ciphertext IS NULL AND
            source.payload_binding_version IS NULL AND source.payload_binding_key_tag IS NULL AND
            source.payload_binding_mac IS NULL)) IS TRUE
        FROM public.#{table} AS source
        """
      end)

    patch("durable_payload_proof_failures()", [
      {"FROM public.snapshots AS source",
       "FROM public.snapshots AS source\nUNION ALL\n#{new_sources}"}
    ])

    patch("durable_payload_source_acl_ready()", [
      {"('snapshots', 'public.snapshots')",
       "('snapshots', 'public.snapshots')," <>
         Enum.map_join(@tables, ",", &"('#{&1}', 'public.#{&1}')")},
      {"('maraithon_payload_verifier', ARRAY[",
       "('maraithon_payload_verifier', ARRAY[#{table_literals},"},
      {"('maraithon_incident_operator', ARRAY[",
       "('maraithon_incident_operator', ARRAY[#{table_literals},"},
      {"('maraithon_activation_operator', ARRAY[",
       "('maraithon_activation_operator', ARRAY[#{table_literals},"},
      {"), expected_column_acls AS (",
       "," <>
         Enum.map_join(@tables, ",", fn table ->
           "('maraithon_incident_operator', '#{table}', ARRAY['data_ciphertext','payload_encryption_version','payload_binding_version','payload_binding_key_tag','payload_binding_mac']::text[])," <>
             "('maraithon_activation_operator', '#{table}', ARRAY['payload_binding_version','payload_binding_key_tag','payload_binding_mac']::text[])"
         end) <> "), expected_column_acls AS ("}
    ])

    execute("""
    DO $constraint$ DECLARE definition text; anchor text := 'ARRAY[''effects''::character varying,'; BEGIN
      SELECT pg_get_constraintdef(oid) INTO STRICT definition FROM pg_constraint
      WHERE conrelid = 'public.durable_payload_binding_operations'::regclass
        AND conname = 'durable_payload_binding_operations_shape';
      IF cardinality(string_to_array(definition, anchor)) <> 2 THEN
        RAISE EXCEPTION 'Unexpected binding operation constraint';
      END IF;
      definition := replace(definition, anchor, 'ARRAY[' || #{literal(table_literals)} || ',''effects''::character varying,');
      ALTER TABLE public.durable_payload_binding_operations DROP CONSTRAINT durable_payload_binding_operations_shape;
      EXECUTE 'ALTER TABLE public.durable_payload_binding_operations ADD CONSTRAINT durable_payload_binding_operations_shape ' || definition;
    END $constraint$;
    """)

    for {function, mode} <- [
          {"lock_durable_runtime_activation_sources()", "SHARE"},
          {"lock_durable_payload_binding_sources()", "SHARE"},
          {"lock_durable_payload_contraction_sources()", "SHARE ROW EXCLUSIVE"}
        ] do
      patch(function, [{"IN #{mode} MODE;", ", #{tables} IN #{mode} MODE;"}])
    end

    counts =
      Enum.map_join(@tables, "\n", fn table ->
        """
        live_count := live_count + (SELECT count(*) FROM public.#{table}
          WHERE CASE requested_key_kind
            WHEN 'binding' THEN payload_binding_key_tag = requested_old_tag
            WHEN 'vault' THEN public.durable_payload_ciphertext_key_tag(data_ciphertext) = requested_old_tag
            ELSE false END);
        """
      end)

    patch("durable_payload_old_key_live_count(text,text)", [
      {"RETURN live_count;", "LOCK TABLE #{tables} IN SHARE MODE;\n#{counts}\nRETURN live_count;"}
    ])

    patch("durable_payload_key_registry_definition(text)", [
      {"memory_items.metadata'",
       "memory_items.metadata," <> Enum.map_join(@tables, ",", &"#{&1}.data_ciphertext") <> "'"},
      {"agent_work_results:authority'",
       "agent_work_results:authority," <> Enum.map_join(@tables, ",", &"#{&1}:payload") <> "'"}
    ])

    patch("durable_payload_old_key_source_digest(text,text)", [
      {"'vault_ciphertext_targets', 42", "'vault_ciphertext_targets', 48"},
      {"'binding_targets', 19", "'binding_targets', 25"}
    ])

    patch("guard_durable_payload_retired_key_write()", [
      {"ELSE NULL::text[]",
       Enum.map_join(@tables, "\n", &"WHEN '#{&1}' THEN ARRAY['data_ciphertext']") <>
         "\nELSE NULL::text[]"}
    ])

    patch("durable_payload_operator_row_mutation_authorized(regclass,text,jsonb,jsonb)", [
      {"IF requested_relation NOT IN (",
       "IF requested_relation NOT IN (" <>
         Enum.map_join(@tables, ",", &"'public.#{&1}'::regclass") <> ","},
      {"WHEN 'public.connected_accounts'::regclass THEN",
       Enum.map_join(
         @tables,
         "\n",
         &"WHEN 'public.#{&1}'::regclass THEN vault_fields := ARRAY['data_ciphertext']; encryption_field := 'payload_encryption_version';"
       ) <> "\nWHEN 'public.connected_accounts'::regclass THEN"}
    ])

    patch("durable_payload_catalog_manifest_snapshot()", [
      {"('public.durable_payload_protocol_manifests'::regclass)",
       "('public.durable_payload_protocol_manifests'::regclass)," <>
         Enum.map_join(@tables, ",", &"('public.#{&1}'::regclass)")}
    ])

    patch("privacy_protocol_catalog_ready()", [
      {"jsonb_object_keys(stored_functions)) = 11", "jsonb_object_keys(stored_functions)) = 12"},
      {"jsonb_object_keys(stored_triggers)) = 48", "jsonb_object_keys(stored_triggers)) = 60"},
      {"jsonb_object_keys(stored_catalogs)) = 47", "jsonb_object_keys(stored_catalogs)) = 53"}
    ])

    for table <- @tables do
      execute(
        "CREATE TRIGGER guard_#{table}_retired_key BEFORE INSERT OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION public.guard_durable_payload_retired_key_write()"
      )

      execute(
        "CREATE TRIGGER guard_#{table}_operator BEFORE INSERT OR UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION public.guard_durable_payload_operator_source_mutation()"
      )

      execute(
        "CREATE TRIGGER invalidate_#{table}_payload AFTER INSERT OR UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION public.invalidate_durable_payload_verification()"
      )
    end
  end

  defp patch(function, replacements) do
    replacements =
      Enum.map_join(replacements, "\n", fn {before, after_value} ->
        """
        IF cardinality(string_to_array(definition, #{literal(before)})) <> 2 THEN
          RAISE EXCEPTION 'Unexpected delegation migration anchor in %', #{literal(function)};
        END IF;
        definition := replace(definition, #{literal(before)}, #{literal(after_value)});
        """
      end)

    execute("""
    DO $patch$ DECLARE definition text; BEGIN
      definition := pg_get_functiondef(#{literal("public." <> function)}::regprocedure);
      #{replacements}
      EXECUTE definition;
    END $patch$;
    """)
  end

  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp refresh_catalogs do
    execute(File.read!(Path.join(__DIR__, "../delegation_storage_catalogs.sql")))
  end

  defp sql(statement),
    do: execute(Maraithon.DatabaseRoleCompatibility.rewrite_migration_sql(statement))
end
