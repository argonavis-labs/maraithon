defmodule Maraithon.Repo.Migrations.CreateTodoActivityEvents do
  use Ecto.Migration

  def change do
    create table(:todo_activity_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :todo_id, references(:todos, type: :binary_id, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :actor_type, :string, null: false
      add :actor_id, :string
      add :actor_label, :string
      add :todo_title, :string
      add :todo_source, :string
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:todo_activity_events, [:user_id, :occurred_at])
    create index(:todo_activity_events, [:user_id, :event_type, :occurred_at])
    create index(:todo_activity_events, [:todo_id])
  end
end
