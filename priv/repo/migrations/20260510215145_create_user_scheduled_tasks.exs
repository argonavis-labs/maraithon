defmodule Maraithon.Repo.Migrations.CreateUserScheduledTasks do
  use Ecto.Migration

  def change do
    create table(:user_scheduled_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :description, :text
      add :schedule, :map, null: false, default: %{}
      add :timezone, :string, null: false, default: "Etc/UTC"
      add :status, :string, null: false, default: "active"
      add :command, :map, null: false, default: %{}
      add :failure_destination, :map, null: false, default: %{}
      add :source, :string, null: false, default: "api"
      add :metadata, :map, null: false, default: %{}
      add :last_run_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_scheduled_tasks, [:user_id, :status, :next_run_at])
    create index(:user_scheduled_tasks, [:status, :next_run_at])
    create index(:user_scheduled_tasks, [:source])

    create table(:user_scheduled_task_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_id,
          references(:user_scheduled_tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :scheduled_for, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :result, :map, null: false, default: %{}
      add :error, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_scheduled_task_runs, [:task_id, :scheduled_for])
    create index(:user_scheduled_task_runs, [:user_id, :status, :scheduled_for])
  end
end
