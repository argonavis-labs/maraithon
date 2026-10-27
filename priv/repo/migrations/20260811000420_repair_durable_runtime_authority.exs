defmodule Maraithon.Repo.Migrations.RepairDurableRuntimeAuthority do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @repairs [
    {
      "20260810140004_create_runtime_coordination_authority.exs",
      Maraithon.Repo.Migrations.CreateRuntimeCoordinationAuthority,
      "2c57f6a55466e3857bd24b7c5329ca7e88dd036276c871728e9da5a4909e6f8d"
    },
    {
      "20260810140005_create_durable_payload_verifications.exs",
      Maraithon.Repo.Migrations.CreateDurablePayloadVerifications,
      "d7ef75cd9d056782eca274a7fda2d33c1de9bca8d457e0d4c8d02182f76c3102"
    },
    {
      "20260810140007_add_operational_privacy_controls.exs",
      Maraithon.Repo.Migrations.AddOperationalPrivacyControls,
      "39fd4d3796324ff1bf51472209d6b1283a9d447e353e6ba7e6909a23899f023b"
    }
  ]

  # This forward migration is the production repair for fleets that recorded
  # 140004/140005/140007 before their additive definitions were complete. It
  # deliberately reruns the retry-safe expansion under the same session-level
  # advisory locks. Deleting schema_migrations rows is never an upgrade path.
  def up do
    repo().checkout(
      fn ->
        repo().query!(
          "SELECT pg_catalog.pg_advisory_lock(20260811, 420)",
          [],
          timeout: :infinity
        )

        try do
          require_feature_dark_legacy_pair!()
          run_repairs()
        after
          repo().query!(
            "SELECT pg_catalog.pg_advisory_unlock(20260811, 420)",
            [],
            timeout: :infinity
          )
        end
      end,
      timeout: :infinity
    )
  end

  defp require_feature_dark_legacy_pair! do
    runtime_rows =
      repo().query!(
        """
        SELECT mode
        FROM public.runtime_coordination_protocols
        WHERE name = 'runtime'
        FOR SHARE
        """,
        [],
        timeout: :infinity
      ).rows

    effect_rows =
      repo().query!(
        """
        SELECT mode
        FROM public.effect_execution_protocols
        WHERE name = 'effects'
        FOR SHARE
        """,
        [],
        timeout: :infinity
      ).rows

    case {runtime_rows, effect_rows} do
      {[["dark"]], [["legacy"]]} ->
        :ok

      _other ->
        raise "durable runtime repair requires the feature-dark legacy pair"
    end
  end

  defp run_repairs do
    validated =
      Enum.map(@repairs, fn {filename, module, expected_sha256} ->
        path = Path.join(__DIR__, filename)
        source = File.read!(path)

        actual_sha256 = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

        if actual_sha256 != expected_sha256 do
          raise "durable runtime repair source digest mismatch for #{filename}"
        end

        {path, source, module}
      end)

    Enum.each(validated, fn {path, source, module} ->
      :code.purge(module)
      :code.delete(module)

      compiled_modules =
        source
        |> Code.compile_string(path)
        |> Enum.map(&elem(&1, 0))

      unless module in compiled_modules do
        raise "durable runtime repair did not compile expected module from #{path}"
      end

      apply(module, :up, [])
    end)
  end

  def down do
    raise "durable runtime authority repair is irreversible"
  end
end
