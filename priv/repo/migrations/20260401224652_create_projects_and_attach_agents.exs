defmodule Maraithon.Repo.Migrations.CreateProjectsAndAttachAgents do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "active"
      add :priority, :string, null: false, default: "normal"
      add :description, :text
      add :summary, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:projects, [:user_id])
    create index(:projects, [:status])
    create unique_index(:projects, [:user_id, :slug])

    alter table(:agents) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:agents, [:project_id])
  end
end
