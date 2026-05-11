defmodule Maraithon.Repo.Migrations.CreateLocalNotes do
  use Ecto.Migration

  def change do
    create table(:local_notes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :string, null: false
      add :device_id, :uuid, null: false
      add :source, :string, null: false, default: "notes"
      add :guid, :string
      add :local_id, :string
      add :title, :binary
      add :snippet, :binary
      add :folder, :string
      add :is_pinned, :boolean, null: false, default: false
      add :created_at, :utc_datetime_usec
      add :modified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:local_notes, [:user_id, :device_id, :source, :guid],
             name: :local_notes_user_device_source_guid_index
           )

    create index(:local_notes, [:user_id, :modified_at])
    create index(:local_notes, [:user_id, :folder, :modified_at])
    create index(:local_notes, [:device_id])
  end
end
