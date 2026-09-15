defmodule Maraithon.Repo.Migrations.RefreshDelegatedEffectPayloadFingerprints do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # The delegation migrations registered these definitions with the durable
    # payload catalog. Effect activation also keeps their older body hashes.
    # Admit only the definitions already proven by the stronger catalog.
    execute("""
    DO $refresh$
    DECLARE reviewed jsonb; live jsonb;
      changed constant text[] := ARRAY[
        'durable_payload_row_identity', 'durable_payload_digest_part',
        'durable_payload_proof_failures'
      ];
    BEGIN
      IF NOT public.privacy_protocol_catalog_ready() OR
         NOT public.durable_payload_catalog_ready() OR
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Effect payload refresh requires a verified catalog baseline';
      END IF;
      SELECT function_fingerprints INTO STRICT reviewed
      FROM public.effect_execution_protocol_manifests WHERE name = 'effects' FOR UPDATE;
      SELECT jsonb_object_agg(item.key, md5(proc.prosrc)) INTO live
      FROM jsonb_each_text(reviewed) item
      JOIN pg_proc proc ON proc.proname = item.key AND proc.pronamespace = 'public'::regnamespace;
      IF NOT reviewed ?& changed OR (reviewed - changed) IS DISTINCT FROM (live - changed) THEN
        RAISE EXCEPTION 'Effect payload refresh found unrelated function drift';
      END IF;
      ALTER TABLE public.effect_execution_protocol_manifests
        DISABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger;
      UPDATE public.effect_execution_protocol_manifests
      SET function_fingerprints = live, updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'effects';
      ALTER TABLE public.effect_execution_protocol_manifests
        ENABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger;
      IF NOT public.privacy_protocol_catalog_ready() OR
         NOT public.durable_payload_catalog_ready() OR
         public.runtime_coordination_catalog_ready_count() <> 120 THEN
        RAISE EXCEPTION 'Effect payload refresh did not preserve catalog readiness';
      END IF;
    END $refresh$;
    """)
  end

  def down, do: raise("Effect payload fingerprints require a reviewed forward migration")
end
