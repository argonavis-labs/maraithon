defmodule Maraithon.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  def change do
    create table(:agent_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      add :agent_package_id, references(:agent_packages, type: :binary_id, on_delete: :nilify_all)

      add :agent_package_version_id,
          references(:agent_package_versions, type: :binary_id, on_delete: :nilify_all)

      add :user_id, :string
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :behavior, :string, null: false
      add :status, :string, null: false, default: "running"
      add :trigger_type, :string
      add :trigger, :map, null: false, default: %{}
      add :resolved_model, :string
      add :intelligence, :string
      add :finish_reason, :string
      add :generation_mode, :string
      add :active_skills, {:array, :string}, null: false, default: []
      add :tool_allowlist, {:array, :string}, null: false, default: []
      add :budget_snapshot, :map, null: false, default: %{}
      add :error, :text
      add :metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_runs, [:agent_id, :started_at])
    create index(:agent_runs, [:agent_package_version_id])

    create table(:agent_run_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_run_id, references(:agent_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :sequence, :integer, null: false
      add :step_type, :string, null: false
      add :status, :string, null: false
      add :tool_name, :string
      add :effect_type, :string
      add :resolved_model, :string
      add :intelligence, :string
      add :finish_reason, :string
      add :generation_mode, :string
      add :request_payload, :map, null: false, default: %{}
      add :response_payload, :map, null: false, default: %{}
      add :error, :text
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_run_steps, [:agent_run_id, :sequence])
    create index(:agent_run_steps, [:agent_id, :started_at])
  end
end
