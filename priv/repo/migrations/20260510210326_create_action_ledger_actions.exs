defmodule Maraithon.Repo.Migrations.CreateActionLedgerActions do
  use Ecto.Migration

  def change do
    create table(:action_ledger_actions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string
      add :agent_id, :binary_id
      add :surface, :string, null: false
      add :event_type, :string, null: false
      add :status, :string, null: false
      add :source_evidence, :map, null: false, default: %{}
      add :policy_decision, :map, null: false, default: %{}
      add :model_summary, :string
      add :confirmation_state, :string
      add :result_object_refs, :map, null: false, default: %{}
      add :remediation_hint, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:action_ledger_actions, [:user_id, :event_type, :inserted_at])
    create index(:action_ledger_actions, [:surface, :event_type, :inserted_at])
    create index(:action_ledger_actions, [:agent_id, :inserted_at])
  end
end
