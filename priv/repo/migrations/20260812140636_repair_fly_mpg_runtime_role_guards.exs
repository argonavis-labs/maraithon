defmodule Maraithon.Repo.Migrations.RepairFlyMpgRuntimeRoleGuards do
  use Ecto.Migration

  alias Maraithon.DatabaseRoleCompatibility

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    if DatabaseRoleCompatibility.fly_managed_postgres?() do
      require_feature_dark_legacy_pair!()
    end

    execute(
      DatabaseRoleCompatibility.rewrite_migration_sql("""
      CREATE OR REPLACE FUNCTION public.guard_durable_payload_operator_source_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $function$
      BEGIN
        IF current_user IN (
          'maraithon_incident_operator', 'maraithon_activation_operator'
        ) THEN
          IF public.durable_payload_operator_row_mutation_authorized(
               TG_RELID::regclass, TG_OP, pg_catalog.to_jsonb(OLD), pg_catalog.to_jsonb(NEW)
             ) IS NOT TRUE THEN
            RAISE EXCEPTION 'durable payload operator mutation is outside reviewed authority'
              USING ERRCODE = 'insufficient_privilege';
          END IF;
        END IF;

        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
      END;
      $function$;
      """)
    )
  end

  defp require_feature_dark_legacy_pair! do
    runtime_rows =
      repo().query!(
        "SELECT mode FROM public.runtime_coordination_protocols WHERE name = 'runtime'",
        [],
        timeout: :infinity
      ).rows

    effect_rows =
      repo().query!(
        "SELECT mode FROM public.effect_execution_protocols WHERE name = 'effects'",
        [],
        timeout: :infinity
      ).rows

    unless runtime_rows == [["dark"]] and effect_rows == [["legacy"]] do
      raise "Fly MPG role-guard repair requires the feature-dark legacy pair"
    end
  end

  def down do
    raise "Fly MPG runtime role-guard repair is irreversible"
  end
end
