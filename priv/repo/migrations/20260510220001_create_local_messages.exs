defmodule Maraithon.Repo.Migrations.CreateLocalMessages do
  use Ecto.Migration

  def change do
    create table(:local_messages, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :string, null: false
      add :device_id, :uuid, null: false
      add :source, :string, null: false
      add :guid, :string
      add :local_id, :string
      add :is_from_me, :boolean, null: false, default: false
      add :sender_handle, :binary
      add :chat_key, :string
      add :chat_display_name, :string
      add :chat_style, :string
      add :text, :binary
      add :sent_at, :utc_datetime_usec
      add :has_attachments, :boolean, null: false, default: false
      add :attachments, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:local_messages, [:user_id, :device_id, :source, :guid],
             name: :local_messages_user_device_source_guid_index
           )

    create index(:local_messages, [:user_id, :sent_at])
    create index(:local_messages, [:user_id, :chat_key, :sent_at])
    create index(:local_messages, [:device_id])
  end
end
