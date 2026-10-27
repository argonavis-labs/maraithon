defmodule Maraithon.Repo.Migrations.CreateProactivePlannerUserCursors do
  use Ecto.Migration

  def change do
    create table(:proactive_planner_user_cursors, primary_key: false) do
      add :user_id, references(:users, type: :string, on_delete: :delete_all), primary_key: true
      add :last_attempted_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:proactive_planner_user_cursors, [:last_attempted_at, :user_id])

    create index(:proactive_candidates, [:status, :expires_at, :user_id],
             name: :proactive_candidates_due_users_idx
           )
  end
end
