defmodule Maraithon.Repo.Migrations.CreateProjectDeliveryWorkflows do
  use Ecto.Migration

  def change do
    create table(:project_recommendation_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false

      add :source_insight_id, references(:insights, type: :binary_id, on_delete: :delete_all),
        null: false

      add :decision, :string, null: false
      add :decision_note, :text
      add :accepted_plan, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:project_recommendation_decisions, [:project_id])
    create index(:project_recommendation_decisions, [:user_id, :decision])
    create unique_index(:project_recommendation_decisions, [:user_id, :source_insight_id])

    create table(:project_repo_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false

      add :granted_by_user_id, references(:users, type: :string, on_delete: :nilify_all),
        null: false

      add :provider, :string, null: false
      add :repo_full_name, :string, null: false
      add :scope, :string, null: false
      add :status, :string, null: false, default: "active"
      add :granted_at, :utc_datetime_usec, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:project_repo_grants, [:project_id])
    create index(:project_repo_grants, [:user_id, :provider, :repo_full_name])

    create unique_index(
             :project_repo_grants,
             [:project_id, :provider, :repo_full_name, :scope],
             name: :project_repo_grants_project_repo_scope_index
           )

    create table(:project_implementation_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)

      add :recommendation_decision_id,
          references(:project_recommendation_decisions, type: :binary_id, on_delete: :nilify_all),
          null: false

      add :repo_full_name, :string
      add :status, :string, null: false
      add :branch_name, :string
      add :pull_request_url, :string
      add :result_summary, :text
      add :queued_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:project_implementation_runs, [:project_id, :status])
    create index(:project_implementation_runs, [:user_id, :queued_at])
    create index(:project_implementation_runs, [:recommendation_decision_id])
  end
end
