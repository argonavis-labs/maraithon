defmodule Maraithon.Repo.Migrations.CreateAgentMarketplace do
  use Ecto.Migration

  def change do
    create table(:agent_packages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false
      add :summary, :text
      add :category, :string
      add :source_kind, :string, null: false, default: "builtin"
      add :status, :string, null: false, default: "published"
      add :owner_user_id, :string
      add :manifest, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_packages, [:slug])
    create index(:agent_packages, [:status])
    create index(:agent_packages, [:owner_user_id])

    create table(:agent_package_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_package_id,
          references(:agent_packages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version, :string, null: false
      add :behavior, :string, null: false
      add :system_prompt, :text
      add :model, :string
      add :intelligence, :string
      add :goals, {:array, :string}, null: false, default: []
      add :skill_paths, {:array, :string}, null: false, default: []
      add :required_connectors, :map, null: false, default: %{}
      add :tool_allowlist, {:array, :string}, null: false, default: []
      add :mcp_allowlist, {:array, :string}, null: false, default: []
      add :default_config, :map, null: false, default: %{}
      add :manifest, :map, null: false, default: %{}
      add :status, :string, null: false, default: "published"
      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_package_versions, [:agent_package_id, :version])
    create index(:agent_package_versions, [:agent_package_id, :status])

    alter table(:agent_packages) do
      add :latest_version_id,
          references(:agent_package_versions, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:agents) do
      add :agent_package_id, references(:agent_packages, type: :binary_id, on_delete: :nilify_all)

      add :agent_package_version_id,
          references(:agent_package_versions, type: :binary_id, on_delete: :nilify_all)

      add :install_status, :string, null: false, default: "enabled"
      add :installed_at, :utc_datetime_usec
      add :removed_at, :utc_datetime_usec
      add :connector_grants, :map, null: false, default: %{}
      add :schedule_policy, :map, null: false, default: %{}
      add :delivery_policy, :map, null: false, default: %{}
      add :memory_scope, :map, null: false, default: %{}
    end

    create index(:agents, [:agent_package_id])
    create index(:agents, [:agent_package_version_id])
    create index(:agents, [:user_id, :install_status])
  end
end
