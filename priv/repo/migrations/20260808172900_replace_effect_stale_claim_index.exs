defmodule Maraithon.Repo.Migrations.ReplaceEffectStaleClaimIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS effects_stale_claimed_at_id_index")

    execute("""
    CREATE INDEX CONCURRENTLY effects_stale_claimed_at_id_index
    ON effects (claimed_at ASC NULLS FIRST, id)
    WHERE status IN ('claimed', 'cancelling')
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS effects_stale_claimed_at_id_index")

    execute("""
    CREATE INDEX CONCURRENTLY effects_stale_claimed_at_id_index
    ON effects (claimed_at ASC NULLS FIRST, id)
    WHERE status = 'claimed'
    """)
  end
end
