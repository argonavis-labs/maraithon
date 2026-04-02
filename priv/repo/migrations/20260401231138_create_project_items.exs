defmodule Maraithon.Repo.Migrations.CreateProjectItems do
  use Ecto.Migration

  def change do
    create table(:project_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :item_type, :string, null: false
      add :title, :string
      add :content, :text, null: false
      add :status, :string, null: false, default: "active"
      add :source, :string, null: false, default: "manual"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:project_items, [:project_id])
    create index(:project_items, [:user_id, :inserted_at])
    create index(:project_items, [:project_id, :status])
  end
end
