defmodule Maraithon.Repo.Migrations.CreateLocalReminders do
  use Ecto.Migration

  def change do
    create table(:local_reminders, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :string, null: false
      add :device_id, :uuid, null: false
      add :source, :string, null: false, default: "reminders"
      add :guid, :string
      add :local_id, :string
      add :list_name, :string
      add :list_color, :string
      add :title, :binary
      add :notes, :binary
      add :priority, :integer, null: false, default: 0
      add :due_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :is_completed, :boolean, null: false, default: false
      add :has_alarm, :boolean, null: false, default: false
      add :url_attachment, :string
      add :created_at, :utc_datetime_usec
      add :modified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:local_reminders, [:user_id, :device_id, :source, :guid],
             name: :local_reminders_user_device_source_guid_index
           )

    create index(:local_reminders, [:user_id, :due_at])
    create index(:local_reminders, [:user_id, :is_completed, :due_at])
    create index(:local_reminders, [:user_id, :list_name, :modified_at])
    create index(:local_reminders, [:device_id])
  end
end
