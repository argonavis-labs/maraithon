defmodule Maraithon.Repo.Migrations.AddCompanionCalendarAvailability do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("""
    DO $$ BEGIN
      IF NOT public.privacy_protocol_catalog_ready() OR
         NOT public.durable_payload_catalog_ready() OR
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Calendar availability requires a verified catalog baseline';
      END IF;
    END $$;
    """)

    alter table(:companion_devices) do
      add :calendar_availability, :map, null: false, default: %{}
    end

    flush()

    # The companion registry is in the privacy manifest only. Refresh exactly
    # its table fingerprint; all unchanged protocol members must still match.
    execute("""
    DO $refresh$
    DECLARE catalogs jsonb; functions jsonb; triggers jsonb;
    BEGIN
      SELECT catalog_fingerprints, function_fingerprints, trigger_fingerprints
      INTO STRICT catalogs, functions, triggers
      FROM public.privacy_protocol_manifests
      WHERE name = 'operational_privacy_140007' AND migration_version = 20260810140007
      FOR UPDATE;
      IF NOT (catalogs ? 'companion_devices') THEN
        RAISE EXCEPTION 'Calendar availability privacy catalog entry is missing';
      END IF;
      catalogs := jsonb_set(catalogs, '{companion_devices}',
        to_jsonb(public.runtime_catalog_table_fingerprint('public.companion_devices'::regclass)), false);
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
        RAISE EXCEPTION 'Calendar availability did not restore all catalog proofs';
      END IF;
    END $refresh$;
    """)
  end

  def down, do: raise("Calendar availability requires a reviewed forward migration")
end
