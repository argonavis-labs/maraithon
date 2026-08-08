defmodule Maraithon.Repo.Migrations.NarrowEffectTerminalResultDispatchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS effects_terminal_result_dispatch_idx")

    execute("""
    CREATE INDEX CONCURRENTLY effects_terminal_result_dispatch_idx
    ON effects (result_dispatch_after ASC NULLS FIRST, inserted_at, id)
    WHERE status IN ('completed', 'failed')
      AND result_envelope IS NOT NULL
      AND result_acknowledged_at IS NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS effects_terminal_result_dispatch_idx")

    execute("""
    CREATE INDEX CONCURRENTLY effects_terminal_result_dispatch_idx
    ON effects (result_dispatch_after ASC NULLS FIRST, inserted_at, id)
    WHERE status IN ('completed', 'failed')
      AND result_acknowledged_at IS NULL
    """)
  end
end
