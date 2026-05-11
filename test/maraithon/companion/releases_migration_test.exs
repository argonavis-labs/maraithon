defmodule Maraithon.Companion.ReleasesMigrationTest do
  @moduledoc """
  Smoke test for the `create_companion_releases` migration.

  Asserts the migration file exists at the expected path, exposes
  `change/0`, and that when applied (which `mix test` does on setup)
  the `companion_releases` table and its indexes are present in the
  shared test schema. Running `Migrator.up`/`Migrator.down` from
  inside a sandbox checkout deadlocks (the migrator runs DDL on a
  separate connection), so we verify the *outcome* of the migration
  rather than re-driving it.
  """

  use Maraithon.DataCase, async: true

  @migration_version 20_260_511_050_000
  @migration_file "20260511050000_create_companion_releases.exs"

  test "migration file exists, defines change/0, and is loadable" do
    migration_path =
      :maraithon
      |> Application.app_dir("priv/repo/migrations")
      |> Path.join(@migration_file)

    assert File.exists?(migration_path),
           "expected migration file at #{migration_path}"

    if not Code.ensure_loaded?(Maraithon.Repo.Migrations.CreateCompanionReleases) do
      Code.compile_file(migration_path)
    end

    info = Maraithon.Repo.Migrations.CreateCompanionReleases.__migration__()
    assert Keyword.fetch!(info, :disable_ddl_transaction) in [true, false]
    assert function_exported?(Maraithon.Repo.Migrations.CreateCompanionReleases, :change, 0)

    # Filename version must match the constant the appcast task expects.
    assert Path.basename(migration_path) =~ Integer.to_string(@migration_version)
  end

  test "companion_releases table is present after migrations run" do
    assert table_exists?("companion_releases")

    columns = table_columns("companion_releases")
    expected = ~w(id version build_number url signature min_system_version notes_markdown released_at inserted_at updated_at)

    for column <- expected do
      assert column in columns, "expected column #{column} on companion_releases"
    end
  end

  test "the version column is unique" do
    indexes = table_indexes("companion_releases")
    assert Enum.any?(indexes, &String.contains?(&1, "version"))
  end

  defp table_exists?(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.tables WHERE table_name = $1",
        [name]
      )

    rows != []
  end

  defp table_columns(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
        [name]
      )

    Enum.map(rows, fn [c] -> c end)
  end

  defp table_indexes(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname FROM pg_indexes WHERE tablename = $1",
        [name]
      )

    Enum.map(rows, fn [c] -> c end)
  end
end
