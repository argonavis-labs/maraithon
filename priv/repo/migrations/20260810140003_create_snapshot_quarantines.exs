defmodule Maraithon.Repo.Migrations.CreateSnapshotQuarantines do
  use Ecto.Migration

  def change do
    create table(:snapshot_quarantines) do
      # The source snapshot is deleted after quarantine, but the sanitized
      # report remains owned by the Agent and must follow Agent erasure.
      add :snapshot_id, :bigint, null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :sequence_num, :bigint, null: false
      add :failure_code, :string, null: false
      add :status, :string, null: false
      add :state_bytes, :bigint, null: false
      add :budget_bytes, :bigint, null: false
      add :snapshot_inserted_at, :utc_datetime_usec, null: false
      add :quarantined_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:snapshot_quarantines, [:snapshot_id])
    create index(:snapshot_quarantines, [:status, :inserted_at])
    create index(:snapshot_quarantines, [:agent_id, :sequence_num])

    create constraint(:snapshot_quarantines, :snapshot_quarantines_status_check,
             check: "status IN ('blocked_active', 'quarantined')"
           )

    create constraint(:snapshot_quarantines, :snapshot_quarantines_sizes_check,
             check: "state_bytes >= 0 AND budget_bytes >= 0"
           )
  end
end
