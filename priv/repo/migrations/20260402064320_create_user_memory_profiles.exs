defmodule Maraithon.Repo.Migrations.CreateUserMemoryProfiles do
  use Ecto.Migration

  def change do
    create table(:user_memory_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :summary, :text, null: false
      add :profile, :map, null: false, default: %{}
      add :source_window_start, :utc_datetime_usec
      add :source_window_end, :utc_datetime_usec
      add :confidence, :float, null: false, default: 0.0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_memory_profiles, [:user_id])
  end
end
