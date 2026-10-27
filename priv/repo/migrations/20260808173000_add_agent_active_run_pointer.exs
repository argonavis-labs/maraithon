defmodule Maraithon.Repo.Migrations.AddAgentActiveRunPointer do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("ALTER TABLE agents ADD COLUMN IF NOT EXISTS active_run_id uuid")
    execute("DROP INDEX CONCURRENTLY IF EXISTS agents_active_run_id_index")

    execute("""
    CREATE INDEX CONCURRENTLY agents_active_run_id_index
    ON agents (active_run_id)
    WHERE active_run_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS agents_active_run_id_index")
    execute("ALTER TABLE agents DROP COLUMN IF EXISTS active_run_id")
  end
end
