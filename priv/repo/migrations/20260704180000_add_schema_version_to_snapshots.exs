defmodule Maraithon.Repo.Migrations.AddSchemaVersionToSnapshots do
  use Ecto.Migration

  # SPEC 08 R1: additive-only — `ADD COLUMN ... DEFAULT 0` backfills existing
  # rows to 0 (the pre-versioning contract), no backfill script, no downtime,
  # reversible via `change/0`.
  def change do
    alter table(:snapshots) do
      add :schema_version, :integer, null: false, default: 0
    end
  end
end
