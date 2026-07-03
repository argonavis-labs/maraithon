defmodule Maraithon.Repo.Migrations.CreateSourceCursors do
  use Ecto.Migration

  def change do
    create table(:source_cursors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false

      add :connected_account_id, references(:connected_accounts, on_delete: :delete_all),
        null: false

      add :provider, :string, null: false
      add :kind, :string, null: false
      add :value, :string
      add :watch_channel_id, :string
      add :watch_resource_id, :string
      add :watch_expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:source_cursors, [:connected_account_id, :kind])
    create index(:source_cursors, [:user_id])
    create index(:source_cursors, [:watch_expires_at])
  end
end
