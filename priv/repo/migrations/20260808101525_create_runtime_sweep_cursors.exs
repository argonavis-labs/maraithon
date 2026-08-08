defmodule Maraithon.Repo.Migrations.CreateRuntimeSweepCursors do
  use Ecto.Migration

  def change do
    create table(:runtime_sweep_cursors, primary_key: false) do
      add :sweep_key, :string, primary_key: true
      add :after_user_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:todos, [:user_id, :status, :last_completion_checked_at, :id],
             name: :todos_completion_rotation_idx
           )

    create index(:todos, [:status, :user_id], name: :todos_open_user_sweep_idx)
  end
end
