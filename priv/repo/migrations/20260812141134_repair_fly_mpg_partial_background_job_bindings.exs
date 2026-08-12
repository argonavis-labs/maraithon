defmodule Maraithon.Repo.Migrations.RepairFlyMpgPartialBackgroundJobBindings do
  use Ecto.Migration

  alias Maraithon.DatabaseRoleCompatibility

  def up do
    if DatabaseRoleCompatibility.fly_managed_postgres?() do
      require_feature_dark_legacy_pair!()

      execute("""
      UPDATE public.background_jobs
      SET payload_ciphertext = NULL,
          result_ciphertext = NULL,
          payload_encryption_version = NULL,
          payload_binding_version = NULL,
          payload_binding_key_tag = NULL,
          payload_binding_mac = NULL
      WHERE payload_purged_at IS NULL
        AND payload_binding_version IS NOT NULL
        AND payload_binding_key_tag IS NOT NULL
        AND payload_binding_mac IS NOT NULL
        AND (payload_ciphertext IS NULL OR result_ciphertext IS NULL)
      """)
    end
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
      raise "Fly MPG partial binding repair requires the feature-dark legacy pair"
    end
  end

  def down do
    raise "Fly MPG partial background-job binding repair is irreversible"
  end
end
