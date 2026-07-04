defmodule Maraithon.Repo.Migrations.CreateTodoStalenessBatches do
  use Ecto.Migration

  def change do
    create table(:todo_staleness_batches, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :chat_id, :string, null: false
      add :message_id, :string, null: false
      add :todo_ids, {:array, :binary_id}, null: false
      add :rationales, :map, default: %{}
      add :resolved, :map, default: %{}
      add :status, :string, null: false, default: "open"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:todo_staleness_batches, [:chat_id, :message_id])
    create index(:todo_staleness_batches, [:user_id, :status])
  end
end
