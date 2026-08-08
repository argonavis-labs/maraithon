defmodule Maraithon.Repo.Migrations.AddStalenessTriageCursorToTodos do
  use Ecto.Migration

  def change do
    alter table(:todos) do
      add :last_staleness_triage_checked_at, :utc_datetime_usec
    end

    create index(:todos, [:user_id, :status, :last_staleness_triage_checked_at, :id],
             name: :todos_staleness_rotation_idx
           )
  end
end
