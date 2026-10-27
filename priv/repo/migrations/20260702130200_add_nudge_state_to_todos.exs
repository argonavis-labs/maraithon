defmodule Maraithon.Repo.Migrations.AddNudgeStateToTodos do
  use Ecto.Migration

  def change do
    alter table(:todos) do
      add :last_nudged_at, :utc_datetime
      add :nudge_count, :integer, null: false, default: 0
      add :next_nudge_at, :utc_datetime
      add :follow_up_channel, :string
    end

    create index(:todos, [:user_id, :next_nudge_at])
  end
end
