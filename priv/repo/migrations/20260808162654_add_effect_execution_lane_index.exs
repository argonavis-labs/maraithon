defmodule Maraithon.Repo.Migrations.AddEffectExecutionLaneIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS effects_pending_llm_execution_lane_idx")

    execute("""
    CREATE INDEX CONCURRENTLY effects_pending_llm_execution_lane_idx
    ON effects ((params ->> '__maraithon_execution_lane'), inserted_at, id)
    WHERE status = 'pending' AND effect_type = 'llm_call'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS effects_pending_llm_execution_lane_idx")
  end
end
