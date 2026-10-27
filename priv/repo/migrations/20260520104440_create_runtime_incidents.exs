defmodule Maraithon.Repo.Migrations.CreateRuntimeIncidents do
  use Ecto.Migration

  def change do
    create table(:runtime_incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :reason, :text
      add :metadata, :map, null: false, default: %{}
      add :node, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:runtime_incidents, [:occurred_at])
    create index(:runtime_incidents, [:kind, :occurred_at])
    create index(:runtime_incidents, [:agent_id, :occurred_at])
  end
end
