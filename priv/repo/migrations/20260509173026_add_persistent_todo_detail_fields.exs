defmodule Maraithon.Repo.Migrations.AddPersistentTodoDetailFields do
  use Ecto.Migration

  def change do
    alter table(:todos) do
      add :due_at, :utc_datetime_usec
      add :notes, :text
      add :action_plan, :text
      add :action_draft, :map, null: false, default: %{}
      add :owner_user_id, references(:users, type: :string, on_delete: :nilify_all)
      add :owner_label, :string
      add :source_account_id, references(:connected_accounts, on_delete: :nilify_all)
      add :source_account_label, :string
    end

    execute(
      "UPDATE todos SET owner_user_id = user_id WHERE owner_user_id IS NULL",
      "UPDATE todos SET owner_user_id = NULL"
    )

    create index(:todos, [:user_id, :due_at])
    create index(:todos, [:user_id, :owner_user_id, :status])
    create index(:todos, [:user_id, :source_account_id])
  end
end
