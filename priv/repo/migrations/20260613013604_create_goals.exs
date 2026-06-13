defmodule Maraithon.Repo.Migrations.CreateGoals do
  use Ecto.Migration

  def change do
    create table(:goals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :category, :string, null: false
      add :status, :string, null: false, default: "active"
      add :title, :string, null: false
      add :desired_outcome, :text, null: false
      add :why, :text
      add :success_metric, :text
      add :priority, :integer, null: false, default: 50
      add :sensitivity, :string, null: false, default: "standard"
      add :proactive_visibility, :string, null: false, default: "summary"
      add :review_cadence, :string, null: false, default: "weekly"
      add :starts_on, :date
      add :target_at, :utc_datetime_usec
      add :last_reviewed_at, :utc_datetime_usec
      add :next_review_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:goals, [:user_id, :status, :next_review_at])
    create index(:goals, [:user_id, :category, :status])
    create index(:goals, [:user_id, :updated_at])

    create table(:goal_progress_updates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :summary, :text, null: false
      add :progress_state, :string, null: false
      add :confidence, :float
      add :evidence, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:goal_progress_updates, [:user_id, :goal_id, :occurred_at])
    create index(:goal_progress_updates, [:user_id, :progress_state, :occurred_at])

    create table(:goal_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :resource_type, :string, null: false
      add :resource_id, :string, null: false
      add :relationship, :string, null: false
      add :source, :string, null: false
      add :confidence, :float
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :goal_links,
             [:user_id, :goal_id, :resource_type, :resource_id, :relationship],
             name: :goal_links_user_goal_resource_relationship_index
           )

    create index(:goal_links, [:user_id, :resource_type, :resource_id])
    create index(:goal_links, [:user_id, :goal_id, :relationship])

    create table(:goal_review_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :goal_id, references(:goals, type: :binary_id, on_delete: :nilify_all)
      add :trigger, :string, null: false
      add :status, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :source_summary, :map, null: false, default: %{}
      add :result, :map, null: false, default: %{}
      add :error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:goal_review_runs, [:user_id, :started_at])
    create index(:goal_review_runs, [:user_id, :goal_id, :started_at])
    create index(:goal_review_runs, [:user_id, :status, :started_at])
  end
end
