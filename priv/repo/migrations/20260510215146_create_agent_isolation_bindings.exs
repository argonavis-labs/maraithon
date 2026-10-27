defmodule Maraithon.Repo.Migrations.CreateAgentIsolationBindings do
  use Ecto.Migration

  def change do
    create table(:agent_isolation_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :identity_key, :string, null: false
      add :status, :string, null: false, default: "active"
      add :credential_refs, :map, null: false, default: %{}
      add :connector_scope, :map, null: false, default: %{}
      add :memory_scope, :map, null: false, default: %{}
      add :tool_policy, :map, null: false, default: %{}
      add :routing_bindings, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_isolation_bindings, [:agent_id])
    create unique_index(:agent_isolation_bindings, [:user_id, :identity_key])
    create index(:agent_isolation_bindings, [:user_id, :status])

    create table(:agent_isolation_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :session_key, :string, null: false
      add :status, :string, null: false, default: "active"
      add :state, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_isolation_sessions, [:agent_id, :session_key])
    create index(:agent_isolation_sessions, [:user_id, :status])
    create index(:agent_isolation_sessions, [:expires_at])
  end
end
