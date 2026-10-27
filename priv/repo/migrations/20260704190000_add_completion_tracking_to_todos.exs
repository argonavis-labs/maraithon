defmodule Maraithon.Repo.Migrations.AddCompletionTrackingToTodos do
  use Ecto.Migration

  def change do
    alter table(:todos) do
      add :last_completion_checked_at, :utc_datetime
    end

    create index(:todos, [:user_id, :last_completion_checked_at])
  end
end
