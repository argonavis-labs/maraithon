defmodule Maraithon.Repo.Migrations.CreateUserCalendarLinks do
  use Ecto.Migration

  def change do
    create table(:user_calendar_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :context, :string, null: false
      add :duration_minutes, :integer, null: false
      add :label, :string, null: false
      add :url, :string, null: false
      add :active, :boolean, null: false, default: true
      add :priority, :integer, null: false, default: 100
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_calendar_links, [:user_id])
    create index(:user_calendar_links, [:user_id, :context, :duration_minutes])
    create index(:user_calendar_links, [:user_id, :active])
    create unique_index(:user_calendar_links, [:user_id, :url])
  end
end
