defmodule Maraithon.Repo.Migrations.HardenSnapshotFormatBounds do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE snapshots
    ADD CONSTRAINT snapshots_nonnegative_sequence
    CHECK (sequence_num >= 0) NOT VALID
    """

    execute """
    ALTER TABLE snapshots
    ADD CONSTRAINT snapshots_schema_version_range
    CHECK (schema_version >= 0 AND schema_version <= 2147483647) NOT VALID
    """

    execute """
    ALTER TABLE snapshots
    ADD CONSTRAINT snapshots_payload_objects
    CHECK (jsonb_typeof(state_data) = 'object' AND jsonb_typeof(budget) = 'object') NOT VALID
    """

    execute """
    ALTER TABLE snapshots
    ADD CONSTRAINT snapshots_payload_storage_bound
    CHECK (pg_column_size(state_data) + pg_column_size(budget) <= 1200000) NOT VALID
    """
  end

  def down do
    execute "ALTER TABLE snapshots DROP CONSTRAINT IF EXISTS snapshots_payload_storage_bound"
    execute "ALTER TABLE snapshots DROP CONSTRAINT IF EXISTS snapshots_payload_objects"
    execute "ALTER TABLE snapshots DROP CONSTRAINT IF EXISTS snapshots_schema_version_range"
    execute "ALTER TABLE snapshots DROP CONSTRAINT IF EXISTS snapshots_nonnegative_sequence"
  end
end
