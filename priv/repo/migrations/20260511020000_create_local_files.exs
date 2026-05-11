defmodule Maraithon.Repo.Migrations.CreateLocalFiles do
  use Ecto.Migration

  def change do
    create table(:local_files, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :string, null: false
      add :device_id, :uuid, null: false
      add :source, :string, null: false, default: "files"

      # Stable hash of (path + inode) supplied by the device. Used for
      # idempotent dedupe together with the user + device + source.
      add :guid, :string
      add :local_id, :string

      # `path` is stored plain (with home redacted to `~/`) so we can
      # index/filter on substrings. `filename` is encrypted at rest via
      # the existing Cloak vault because it can leak user-sensitive
      # context (project names, person names, etc.).
      add :path, :text
      add :filename, :binary
      add :extension, :string
      add :mime_type, :string
      add :byte_size, :bigint

      # Extracted plaintext from PDFs, Markdown, .txt, .rtf, .docx,
      # .pages — encrypted at rest. Capped at 200 KB by the controller
      # and context; oversize text trips `text_truncated`.
      add :text_content, :binary
      add :text_truncated, :boolean, default: false, null: false

      add :created_at, :utc_datetime_usec
      add :modified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:local_files, [:user_id, :device_id, :source, :guid],
             name: :local_files_user_device_source_guid_index
           )

    create index(:local_files, [:user_id, :modified_at],
             name: :local_files_user_modified_at_index
           )

    create index(:local_files, [:user_id, :extension, :modified_at],
             name: :local_files_user_extension_modified_at_index
           )

    create index(:local_files, [:device_id])
  end
end
