defmodule Maraithon.Repo.Migrations.CreateBackgroundJobs do
  use Ecto.Migration

  def change do
    create table(:background_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all)
      add :queue, :string, null: false
      add :job_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :dedupe_key, :string
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 3
      add :scheduled_at, :utc_datetime_usec, null: false
      add :claimed_by, :string
      add :claimed_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      add :result, :map, null: false, default: %{}
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:background_jobs, [:status, :scheduled_at])
    create index(:background_jobs, [:queue, :status, :scheduled_at])
    create index(:background_jobs, [:user_id, :status])
    create index(:background_jobs, [:job_type, :status])

    create unique_index(:background_jobs, [:dedupe_key],
             where: "dedupe_key IS NOT NULL AND status IN ('pending', 'running')"
           )
  end
end
