defmodule Maraithon.Repo.Migrations.AddConnectedAccountCategory do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("""
    DO $$ BEGIN
      IF NOT public.privacy_protocol_catalog_ready() OR
         NOT public.durable_payload_catalog_ready() OR
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Account category requires a verified catalog baseline';
      END IF;
    END $$;
    """)

    alter table(:connected_accounts) do
      add :category, :string, null: false, default: "unassigned"
    end

    create constraint(:connected_accounts, :connected_account_category,
             check: "category IN ('unassigned', 'personal', 'work')"
           )

    flush()

    # Admit only this table's reviewed addition. The final proofs also compare
    # every unchanged function, trigger, role, ACL and table. Any drift rolls
    # back the column and both manifest updates in this same transaction.
    execute("""
    DO $refresh$
    DECLARE prior jsonb; current_snapshot jsonb; reviewed jsonb;
      catalogs jsonb; functions jsonb; triggers jsonb;
    BEGIN
      SELECT catalog_manifest INTO STRICT prior
      FROM public.durable_payload_protocol_manifests
      WHERE name = 'durable_payload_140005' AND migration_version = 20260810140005
      FOR UPDATE;
      current_snapshot := public.durable_payload_catalog_manifest_snapshot();
      IF NOT (prior->'catalogs' ? 'connected_accounts') THEN
        RAISE EXCEPTION 'Account category durable catalog entry is missing';
      END IF;
      reviewed := jsonb_set(prior, '{catalogs,connected_accounts}',
        current_snapshot #> '{catalogs,connected_accounts}', false);
      IF prior->'constraints' ? 'connected_accounts.connected_account_category' OR
         NOT (current_snapshot->'constraints' ? 'connected_accounts.connected_account_category') THEN
        RAISE EXCEPTION 'Unexpected account category constraint baseline';
      END IF;
      reviewed := jsonb_set(reviewed, '{constraints,connected_accounts.connected_account_category}',
        current_snapshot #> '{constraints,connected_accounts.connected_account_category}', true);
      IF reviewed IS DISTINCT FROM current_snapshot THEN
        RAISE EXCEPTION 'Account category found unrelated durable catalog drift';
      END IF;
      PERFORM set_config('maraithon.durable_payload_manifest_refresh', 'MIGRATOR_DARK_REFRESH_V1', true);
      UPDATE public.durable_payload_protocol_manifests
      SET catalog_manifest = reviewed,
          manifest_digest = public.digest(convert_to(reviewed::text, 'UTF8'), 'sha256'),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'durable_payload_140005' AND migration_version = 20260810140005;

      SELECT catalog_fingerprints, function_fingerprints, trigger_fingerprints
      INTO STRICT catalogs, functions, triggers
      FROM public.privacy_protocol_manifests
      WHERE name = 'operational_privacy_140007' AND migration_version = 20260810140007
      FOR UPDATE;
      IF NOT (catalogs ? 'connected_accounts') THEN
        RAISE EXCEPTION 'Account category privacy catalog entry is missing';
      END IF;
      catalogs := jsonb_set(catalogs, '{connected_accounts}',
        to_jsonb(public.runtime_catalog_table_fingerprint('public.connected_accounts'::regclass)), false);
      ALTER TABLE public.privacy_protocol_manifests
        DISABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger;
      UPDATE public.privacy_protocol_manifests
      SET catalog_fingerprints = catalogs,
          manifest_digest = public.digest(convert_to(jsonb_build_object(
            'functions', functions, 'triggers', triggers, 'catalogs', catalogs
          )::text, 'UTF8'), 'sha256'),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'operational_privacy_140007' AND migration_version = 20260810140007;
      ALTER TABLE public.privacy_protocol_manifests
        ENABLE TRIGGER reject_privacy_protocol_manifest_mutation_trigger;
      IF NOT public.privacy_protocol_catalog_ready() OR
         NOT public.durable_payload_catalog_ready() OR
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Account category did not restore all catalog proofs';
      END IF;
    END $refresh$;
    """)
  end

  def down, do: raise("Account category catalog history requires a reviewed forward migration")
end
