defmodule Maraithon.Repo.Migrations.CreateOperatorEventsAndAgentSubscriptions do
  use Ecto.Migration

  def change do
    create table(:operator_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :source, :string, null: false
      add :event_type, :string, null: false
      add :scope, :string, null: false, default: "global"
      add :source_item_id, :string
      add :dedupe_key, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :payload, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:operator_events, [:user_id, :inserted_at])
    create index(:operator_events, [:user_id, :source, :occurred_at])
    create index(:operator_events, [:project_id, :occurred_at])
    create unique_index(:operator_events, [:user_id, :dedupe_key])

    create table(:agent_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :string, on_delete: :nilify_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :topic, :string, null: false
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_subscriptions, [:agent_id, :status])
    create index(:agent_subscriptions, [:user_id, :status])
    create index(:agent_subscriptions, [:project_id, :status])
    create unique_index(:agent_subscriptions, [:agent_id, :topic])
  end
end
