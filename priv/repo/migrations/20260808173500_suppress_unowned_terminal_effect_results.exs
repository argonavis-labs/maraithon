defmodule Maraithon.Repo.Migrations.SuppressUnownedTerminalEffectResults do
  use Ecto.Migration

  def up do
    # Preserve terminal payloads for audit, but remove contradictory ownership
    # rows from the dispatch outbox so they can never cross tenant boundaries or
    # permanently occupy the NULLS-FIRST head of the partial index.
    execute("""
    UPDATE effects AS effect
    SET result_acknowledged_at = timezone('UTC', NOW()),
        updated_at = timezone('UTC', NOW())
    WHERE effect.status IN ('completed', 'failed')
      AND effect.result_envelope IS NOT NULL
      AND effect.result_acknowledged_at IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM agents AS agent
        LEFT JOIN agent_runs AS run
          ON run.id = effect.agent_run_id
         AND run.agent_id = effect.agent_id
        WHERE agent.id = effect.agent_id
          AND effect.owner_user_id IS NOT DISTINCT FROM agent.user_id
          AND (
            effect.agent_run_id IS NULL OR
            (run.id IS NOT NULL AND
             run.user_id IS NOT DISTINCT FROM effect.owner_user_id)
          )
      )
    """)
  end

  def down do
    :ok
  end
end
