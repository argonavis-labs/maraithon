defmodule Maraithon.Repo.Migrations.RegisterPeopleNetworkCatalogTriggers do
  use Ecto.Migration

  # The earlier cache migration added one trigger on a catalog-protected source.
  # Admit precisely its three fingerprints. Removing this new cache trigger
  # temporarily must reproduce the previously reviewed catalog in full.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")
    execute("LOCK TABLE public.local_calendar_events IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $people_catalog$
    DECLARE
      item record;
      definition text;
      prior_payload jsonb;
      current_payload jsonb;
      reviewed_payload jsonb;
    BEGIN
      IF current_user <> 'maraithon_migrator' THEN
        RAISE EXCEPTION 'People Network catalog registration requires migrator authority';
      END IF;

      IF public.durable_payload_catalog_ready() AND
         public.privacy_protocol_catalog_ready() AND
         public.runtime_coordination_catalog_ready_count() = 120 THEN
        RETURN;
      END IF;

      SELECT * INTO STRICT item FROM pg_catalog.pg_proc
      WHERE oid = 'public.people_network_forget_sources()'::regprocedure;
      IF item.prosecdef OR pg_catalog.regexp_replace(item.prosrc, '\\s+', '', 'g') <>
         'BEGINDELETEFROMpublic.people_network_generationsWHEREuser_idIN(SELECTDISTINCTuser_idFROMdeleted_people_sources);RETURNNULL;END' THEN
        RAISE EXCEPTION 'Unexpected People Network deletion function';
      END IF;

      SELECT t.*, pg_catalog.pg_get_triggerdef(t.oid, true) AS definition
      INTO STRICT item FROM pg_catalog.pg_trigger t
      WHERE t.tgrelid = 'public.local_calendar_events'::regclass
        AND t.tgname = 'people_network_forget_sources' AND NOT t.tgisinternal;
      IF item.tgenabled <> 'O' OR item.tgfoid <> 'public.people_network_forget_sources()'::regprocedure
         OR item.tgqual IS NOT NULL OR item.tgconstraint <> 0 OR item.tgargs <> ''::bytea
         OR item.tgtype <> 8 OR item.tgoldtable IS DISTINCT FROM 'deleted_people_sources'
         OR item.tgnewtable IS NOT NULL OR item.tgattr <> ''::int2vector THEN
        RAISE EXCEPTION 'Unexpected People Network calendar-deletion trigger';
      END IF;
      definition := item.definition;

      SELECT catalog_manifest INTO STRICT prior_payload
      FROM public.durable_payload_protocol_manifests
      WHERE name = 'durable_payload_140005' AND migration_version = 20260810140005
      FOR UPDATE;

      -- The source remains exclusively locked until commit. No source deletion
      -- can miss cache cleanup, and every existing security guard stays enabled.
      DROP TRIGGER people_network_forget_sources ON public.local_calendar_events;
      IF public.durable_payload_catalog_manifest_snapshot() IS DISTINCT FROM prior_payload OR
         NOT public.durable_payload_catalog_ready() OR
         NOT public.privacy_protocol_catalog_ready() OR
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'People Network registration found unrelated protocol catalog drift';
      END IF;
      EXECUTE definition;

      current_payload := public.durable_payload_catalog_manifest_snapshot();
      reviewed_payload := pg_catalog.jsonb_set(prior_payload,
        '{catalogs,local_calendar_events}',
        current_payload #> '{catalogs,local_calendar_events}', false);
      reviewed_payload := pg_catalog.jsonb_set(reviewed_payload,
        '{functions,people_network_forget_sources()}',
        current_payload #> '{functions,people_network_forget_sources()}', true);
      reviewed_payload := pg_catalog.jsonb_set(reviewed_payload,
        '{triggers,local_calendar_events.people_network_forget_sources}',
        current_payload #> '{triggers,local_calendar_events.people_network_forget_sources}', true);
      IF reviewed_payload IS DISTINCT FROM current_payload THEN
        RAISE EXCEPTION 'People Network registration found unrelated durable catalog drift';
      END IF;

      -- Existing migrator-only manifest write path, also used by the reviewed
      -- Effect retry migration. Runtime ownership, modes and epochs stay intact.
      PERFORM set_config('maraithon.durable_payload_manifest_refresh', 'MIGRATOR_DARK_REFRESH_V1', true);
      UPDATE public.durable_payload_protocol_manifests
      SET catalog_manifest = reviewed_payload,
          manifest_digest = public.digest(pg_catalog.convert_to(reviewed_payload::text, 'UTF8'), 'sha256'),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'durable_payload_140005' AND migration_version = 20260810140005;

      IF NOT public.durable_payload_catalog_ready() OR
         NOT public.privacy_protocol_catalog_ready() OR
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Protocol catalog is not ready after People Network registration';
      END IF;
    END;
    $people_catalog$;
    """)
  end

  def down do
    raise "People Network catalog registration requires a reviewed forward migration to change"
  end
end
