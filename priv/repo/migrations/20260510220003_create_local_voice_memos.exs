defmodule Maraithon.Repo.Migrations.CreateLocalVoiceMemos do
  use Ecto.Migration

  def change do
    create table(:local_voice_memos, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :string, null: false
      add :device_id, :uuid, null: false
      add :source, :string, null: false, default: "voice_memos"
      add :guid, :string
      add :local_id, :string
      add :title, :binary
      add :snippet, :binary
      add :duration_seconds, :integer
      add :file_size_bytes, :integer
      add :created_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:local_voice_memos, [:user_id, :device_id, :source, :guid],
             name: :local_voice_memos_user_device_source_guid_index
           )

    create index(:local_voice_memos, [:user_id, :created_at])
    create index(:local_voice_memos, [:device_id])
  end
end
