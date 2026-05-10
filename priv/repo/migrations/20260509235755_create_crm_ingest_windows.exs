defmodule Maraithon.Repo.Migrations.CreateCrmIngestWindows do
  use Ecto.Migration

  def change do
    create table(:crm_ingest_windows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :source, :string, null: false
      add :status, :string, null: false, default: "open"
      add :opened_at, :utc_datetime_usec, null: false
      add :flushed_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec
      add :observation_count, :integer, null: false, default: 0
      add :flush_job_id, :binary_id
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:crm_ingest_windows, [:user_id, :source],
             where: "status = 'open'",
             name: :crm_ingest_windows_open_per_source_index
           )

    create index(:crm_ingest_windows, [:status, :opened_at])
    create index(:crm_ingest_windows, [:user_id, :inserted_at])
  end
end
