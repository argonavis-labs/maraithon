defmodule Maraithon.Repo.Migrations.RepairDurableRuntimeAuthority do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @repairs [
    {
      "20260810140004_create_runtime_coordination_authority.exs",
      Maraithon.Repo.Migrations.CreateRuntimeCoordinationAuthority,
      "41023cfb05e41665ae62aa5bc7d6b61cd5f09c0b9cc6ce04e2611817abf5d605"
    },
    {
      "20260810140005_create_durable_payload_verifications.exs",
      Maraithon.Repo.Migrations.CreateDurablePayloadVerifications,
      "746e5ea9d003c83bcea16b4f1e53644d3315bf9c365f61dc384f2377757a0131"
    },
    {
      "20260810140007_add_operational_privacy_controls.exs",
      Maraithon.Repo.Migrations.AddOperationalPrivacyControls,
      "122eaf5370b698d32b83a04c95ee7de9daa10e04f9065f454de6a7e2ad6566e3"
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
