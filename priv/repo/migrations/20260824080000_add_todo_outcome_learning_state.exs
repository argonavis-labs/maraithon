defmodule Maraithon.Repo.Migrations.AddTodoOutcomeLearningState do
  use Ecto.Migration

  def change do
    alter table(:todos) do
      add :model_selected_at, :utc_datetime_usec
      add :first_user_opened_at, :utc_datetime_usec
    end

    create index(:todos, [:user_id, :model_selected_at])

    create table(:todo_learning_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :todo_id, references(:todos, type: :binary_id, on_delete: :delete_all), null: false
      add :outcome, :string, null: false
      add :signal_strength, :float, null: false
      add :resolution_status, :string, null: false
      add :opened_before_resolution, :boolean, null: false, default: false
      add :surface, :string
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :operation, :string
      add :memory_id, references(:memory_items, type: :binary_id, on_delete: :nilify_all)
      add :processed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:todo_learning_events, [:user_id, :status, :inserted_at])
    create index(:todo_learning_events, [:todo_id, :inserted_at])

    create constraint(:todo_learning_events, :todo_learning_events_outcome,
             check: "outcome IN ('bad', 'weak_bad', 'ok', 'great')"
           )

    create constraint(:todo_learning_events, :todo_learning_events_resolution_status,
             check: "resolution_status IN ('done', 'dismissed')"
           )

    create constraint(:todo_learning_events, :todo_learning_events_status,
             check: "status IN ('pending', 'processing', 'processed', 'failed')"
           )

    execute(
      """
      UPDATE todos
      SET model_selected_at = inserted_at
      WHERE model_selected_at IS NULL
        AND source NOT IN ('manual', 'mobile')
      """,
      "UPDATE todos SET model_selected_at = NULL"
    )
  end
end
