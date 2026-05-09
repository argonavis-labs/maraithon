defmodule Maraithon.Repo.Migrations.CreateMemoryItems do
  use Ecto.Migration

  def change do
    create table(:memory_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "active"
      add :kind, :string, null: false, default: "fact"
      add :scope, :string, null: false, default: "user"
      add :title, :string, null: false
      add :content, :text, null: false
      add :summary, :text
      add :source, :string, null: false, default: "manual"
      add :source_ref_type, :string
      add :source_ref_id, :string
      add :author_type, :string, null: false, default: "user"
      add :author_id, :string
      add :tags, {:array, :string}, null: false, default: []
      add :importance, :integer, null: false, default: 50
      add :confidence, :float, null: false, default: 0.75
      add :polarity, :string, null: false, default: "neutral"
      add :dedupe_key, :string
      add :metadata, :map, null: false, default: %{}
      add :last_used_at, :utc_datetime_usec
      add :use_count, :integer, null: false, default: 0
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:memory_items, [:user_id, :status])
    create index(:memory_items, [:user_id, :kind])
    create index(:memory_items, [:user_id, :scope])
    create index(:memory_items, [:user_id, :source])
    create index(:memory_items, [:user_id, :source_ref_type, :source_ref_id])
    create index(:memory_items, [:user_id, :updated_at])
    create index(:memory_items, [:user_id, :last_used_at])
    create index(:memory_items, [:tags], using: :gin)

    create unique_index(:memory_items, [:user_id, :dedupe_key],
             name: :memory_items_user_active_dedupe_index,
             where: "status = 'active' AND dedupe_key IS NOT NULL"
           )

    create table(:memory_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :memory_id, references(:memory_items, type: :binary_id, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :source, :string, null: false, default: "system"
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:memory_events, [:user_id, :inserted_at])
    create index(:memory_events, [:memory_id, :inserted_at])
  end
end
