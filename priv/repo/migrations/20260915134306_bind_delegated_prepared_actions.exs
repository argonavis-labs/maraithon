defmodule Maraithon.Repo.Migrations.BindDelegatedPreparedActions do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("""
    DO $baseline$ BEGIN
      IF NOT public.privacy_protocol_catalog_ready() OR NOT public.durable_payload_catalog_ready() OR
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Delegated execution requires a verified catalog baseline';
      END IF;
      CREATE TEMP TABLE delegation_execution_prior_catalogs ON COMMIT DROP AS
        SELECT function_fingerprints AS functions, trigger_fingerprints AS triggers,
          catalog_fingerprints AS catalogs,
          public.durable_payload_catalog_manifest_snapshot() AS payload
        FROM public.privacy_protocol_manifests WHERE name = 'operational_privacy_140007'
          AND migration_version = 20260810140007;
    END $baseline$;
    """)

    alter table(:telegram_prepared_actions) do
      add :authorization_kind, :text, null: false, default: "human_confirmed"
      # Logical, immutable references avoid a deletion cycle with
      # delegation_turns.prepared_action_id. The existing guard proves their
      # tenant, turn, run and grant on insertion; retained payloads bind them.
      add :delegation_id, :uuid
      add :delegation_turn_id, :uuid
      add :grant_version, :integer
    end

    create constraint(:telegram_prepared_actions, :prepared_action_delegation_shape,
             check:
               "(authorization_kind = 'human_confirmed' AND surface IN ('telegram','mobile') AND delegation_id IS NULL AND delegation_turn_id IS NULL AND grant_version IS NULL) OR (authorization_kind = 'delegation_grant' AND surface = 'delegation' AND conversation_id IS NULL AND delegation_id IS NOT NULL AND delegation_turn_id IS NOT NULL AND grant_version IS NOT NULL AND grant_version > 0)"
           )

    create unique_index(:telegram_prepared_actions, [:delegation_turn_id],
             name: :prepared_action_delegation_turn_unique,
             where: "authorization_kind = 'delegation_grant'"
           )

    create index(:telegram_prepared_actions, [:delegation_id])

    create constraint(:telegram_assistant_runs, :assistant_run_delegation_shape,
             check:
               "surface <> 'delegation' OR (conversation_id IS NULL AND trigger_type = 'delegation_event' AND chat_id LIKE 'delegation:%')"
           )

    patch(
      "guard_delegation_record()",
      "IF TG_OP = 'UPDATE' AND (NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id) THEN",
      action_guard() <>
        "\nIF TG_OP = 'UPDATE' AND (NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id) THEN"
    )

    execute(
      "CREATE TRIGGER guard_delegated_prepared_action BEFORE INSERT OR UPDATE ON telegram_prepared_actions FOR EACH ROW EXECUTE FUNCTION public.guard_delegation_record()"
    )

    patch(
      "privacy_protocol_catalog_ready()",
      "jsonb_object_keys(stored_triggers)) = 60",
      "jsonb_object_keys(stored_triggers)) = 61"
    )

    for {table, suffix, additions} <- [
          {"telegram_prepared_actions", ", source_row -> 'run_id'",
           ~w(surface chat_id authorization_kind delegation_id delegation_turn_id grant_version)},
          {"telegram_assistant_runs", "", ~w(surface chat_id trigger_type)}
        ] do
      before =
        "WHEN '#{table}' THEN jsonb_build_array(source_row -> 'payload_encryption_version', source_row -> 'payload_binding_version', source_row -> 'payload_binding_key_tag', source_row -> 'payload_binding_mac', source_row -> 'id', source_row -> 'user_id', source_row -> 'conversation_id'#{suffix})"

      after_value =
        String.trim_trailing(before, ")") <>
          Enum.map_join(additions, "", &", source_row -> '#{&1}'") <> ")"

      patch("durable_payload_digest_part(text,jsonb,text)", before, after_value)
    end

    execute(File.read!(Path.join(__DIR__, "../delegation_execution_catalogs.sql")))
  end

  def down, do: raise("Delegated action authority requires a reviewed forward migration")

  defp action_guard do
    """
    IF TG_TABLE_NAME = 'telegram_prepared_actions' THEN
      IF TG_OP = 'UPDATE' AND
        ((NEW.id, NEW.user_id, NEW.authorization_kind, NEW.delegation_id, NEW.delegation_turn_id, NEW.grant_version)
          IS DISTINCT FROM
         (OLD.id, OLD.user_id, OLD.authorization_kind, OLD.delegation_id, OLD.delegation_turn_id, OLD.grant_version)
         OR (OLD.authorization_kind = 'delegation_grant' AND
             (NEW.run_id, NEW.conversation_id, NEW.chat_id, NEW.surface) IS DISTINCT FROM
             (OLD.run_id, OLD.conversation_id, OLD.chat_id, OLD.surface))) THEN
        RAISE EXCEPTION 'Prepared action authority is immutable' USING ERRCODE = 'check_violation';
      END IF;
      IF TG_OP = 'INSERT' AND NEW.authorization_kind = 'delegation_grant' AND NOT EXISTS (
        SELECT 1 FROM public.delegation_turns t
        JOIN public.delegations d ON d.id = t.delegation_id AND d.user_id = t.user_id
        JOIN public.delegation_grants g ON g.id = d.current_grant_id AND g.delegation_id = d.id AND g.user_id = d.user_id
        JOIN public.telegram_assistant_runs r ON r.id = t.run_id AND r.user_id = d.user_id
        WHERE t.id = NEW.delegation_turn_id AND t.delegation_id = NEW.delegation_id AND t.user_id = NEW.user_id
          AND t.run_id = NEW.run_id AND r.surface = 'delegation' AND t.grant_version = NEW.grant_version
          AND t.grant_version = g.version AND g.control_state = 'active' AND t.status = 'validated'
          AND t.source_revision = d.source_revision AND d.state IN ('deciding','sending')
          AND t.prepared_action_id IS NULL
      ) THEN
        RAISE EXCEPTION 'Prepared action delegation scope mismatch' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END IF;
    """
  end

  defp patch(function, before, after_value) do
    execute("""
    DO $patch$ DECLARE definition text; BEGIN
      definition := pg_get_functiondef(#{literal("public." <> function)}::regprocedure);
      IF cardinality(string_to_array(definition, #{literal(before)})) <> 2 THEN
        RAISE EXCEPTION 'Unexpected delegated execution migration anchor in %', #{literal(function)};
      END IF;
      EXECUTE replace(definition, #{literal(before)}, #{literal(after_value)});
    END $patch$;
    """)
  end

  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
