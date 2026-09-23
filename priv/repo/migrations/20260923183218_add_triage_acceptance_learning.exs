defmodule Maraithon.Repo.Migrations.AddTriageAcceptanceLearning do
  use Ecto.Migration

  def up do
    drop constraint(:todo_learning_events, :todo_learning_events_resolution_status)

    create constraint(:todo_learning_events, :todo_learning_events_resolution_status,
             check: "resolution_status IN ('accepted', 'done', 'dismissed')"
           )
  end

  def down do
    # Preserve recorded acceptance evidence when reverting application code.
    :ok
  end
end
