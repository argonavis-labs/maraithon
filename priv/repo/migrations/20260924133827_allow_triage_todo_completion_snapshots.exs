defmodule Maraithon.Repo.Migrations.AllowTriageTodoCompletionSnapshots do
  use Ecto.Migration

  def change do
    execute(
      """
      ALTER TABLE todo_snapshot_items
      DROP CONSTRAINT todo_snapshot_items_shape_check,
      ADD CONSTRAINT todo_snapshot_items_shape_check
      CHECK (ordinal >= 0 AND eligible_status IN ('triage','open','snoozed'))
      """,
      """
      ALTER TABLE todo_snapshot_items
      DROP CONSTRAINT todo_snapshot_items_shape_check,
      ADD CONSTRAINT todo_snapshot_items_shape_check
      CHECK (ordinal >= 0 AND eligible_status IN ('open','snoozed'))
      """
    )
  end
end
