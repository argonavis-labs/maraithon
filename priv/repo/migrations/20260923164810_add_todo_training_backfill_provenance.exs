defmodule Maraithon.Repo.Migrations.AddTodoTrainingBackfillProvenance do
  use Ecto.Migration

  def change do
    for table <- [:todo_training_runs, :todo_training_examples, :todo_training_feedback] do
      alter table(table) do
        add :origin, :string, null: false, default: "live"
        add :occurred_at, :utc_datetime_usec
      end

      create constraint(table, :"#{table}_origin", check: "origin IN ('live', 'backfill')")
      create index(table, [:user_id, :origin, :occurred_at])
    end

    alter table(:todo_training_runs) do
      add :source_key, :string
    end

    create unique_index(:todo_training_runs, [:user_id, :source_key])
  end
end
