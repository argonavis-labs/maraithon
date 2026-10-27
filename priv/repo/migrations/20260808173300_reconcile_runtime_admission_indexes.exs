defmodule Maraithon.Repo.Migrations.ReconcileRuntimeAdmissionIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Forward-reconcile databases that already recorded an earlier form of the
    # active-run and lane migrations. Dropping first also removes an INVALID
    # concurrent index left by an interrupted CREATE INDEX CONCURRENTLY.
    execute("ALTER TABLE agents ADD COLUMN IF NOT EXISTS active_run_id uuid")

    execute("DROP INDEX CONCURRENTLY IF EXISTS agents_active_run_id_index")

    execute("""
    CREATE INDEX CONCURRENTLY agents_active_run_id_index
    ON agents (active_run_id)
    WHERE active_run_id IS NOT NULL
    """)

    execute("DROP INDEX CONCURRENTLY IF EXISTS effects_pending_llm_execution_lane_idx")

    execute("""
    CREATE INDEX CONCURRENTLY effects_pending_llm_execution_lane_idx
    ON effects ((params ->> '__maraithon_execution_lane'), inserted_at, id)
    WHERE status = 'pending' AND effect_type = 'llm_call'
    """)
  end

  def down do
    :ok
  end
end
