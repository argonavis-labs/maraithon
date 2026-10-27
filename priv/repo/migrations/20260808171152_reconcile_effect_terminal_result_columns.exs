defmodule Maraithon.Repo.Migrations.ReconcileEffectTerminalResultColumns do
  use Ecto.Migration

  def up do
    alter table(:effects) do
      add_if_not_exists :completion_claimed_by, :string
      add_if_not_exists :completion_claimed_at, :utc_datetime_usec
      add_if_not_exists :agent_run_id, :binary_id
      add_if_not_exists :agent_run_step_id, :binary_id
      add_if_not_exists :result_envelope, :map
      add_if_not_exists :result_dispatched_at, :utc_datetime_usec
      add_if_not_exists :result_dispatch_after, :utc_datetime_usec
      add_if_not_exists :result_dispatch_attempts, :integer, null: false, default: 0
      add_if_not_exists :result_acknowledged_at, :utc_datetime_usec
    end
  end

  def down do
    raise "irreversible: effect terminal result column reconciliation cannot be safely undone"
  end
end
