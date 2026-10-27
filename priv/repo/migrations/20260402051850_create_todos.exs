defmodule Maraithon.Repo.Migrations.CreateTodos do
  use Ecto.Migration

  def change do
    create table(:todos, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :kind, :string, null: false, default: "general"
      add :attention_mode, :string, null: false, default: "act_now"
      add :title, :string, null: false
      add :summary, :string, null: false
      add :next_action, :string, null: false
      add :priority, :integer, null: false, default: 50
      add :status, :string, null: false, default: "open"
      add :snoozed_until, :utc_datetime_usec
      add :closed_at, :utc_datetime_usec
      add :source_item_id, :string
      add :source_occurred_at, :utc_datetime_usec
      add :dedupe_key, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:todos, [:user_id, :status])
    create index(:todos, [:user_id, :kind, :source])
    create index(:todos, [:source_item_id])
    create unique_index(:todos, [:user_id, :dedupe_key])
  end
end
