defmodule Maraithon.Repo.Migrations.CloseUnpointedLegacyAgentRuns do
  use Ecto.Migration

  def up do
    # Every current runtime run is atomically published through
    # agents.active_run_id before work begins. A running run without that exact
    # pointer has no restorable continuation; close only its still-requested
    # steps and preserve all provider facts already recorded on terminal steps.
    execute("""
    UPDATE agent_run_steps AS step
    SET status = 'failed',
        error = COALESCE(step.error, 'legacy_run_continuation_unavailable'),
        completed_at = COALESCE(step.completed_at, timezone('UTC', NOW())),
        updated_at = timezone('UTC', NOW())
    FROM agent_runs AS run
    WHERE step.agent_run_id = run.id
      AND step.status = 'requested'
      AND run.status = 'running'
      AND NOT EXISTS (
        SELECT 1
        FROM agents AS agent
        WHERE agent.id = run.agent_id
          AND agent.active_run_id = run.id
      )
    """)

    execute("""
    UPDATE agent_runs AS run
    SET status = 'cancelled',
        error = COALESCE(run.error, 'legacy_run_continuation_unavailable'),
        completed_at = COALESCE(run.completed_at, timezone('UTC', NOW())),
        updated_at = timezone('UTC', NOW())
    WHERE run.status = 'running'
      AND NOT EXISTS (
        SELECT 1
        FROM agents AS agent
        WHERE agent.id = run.agent_id
          AND agent.active_run_id = run.id
      )
    """)
  end

  def down do
    :ok
  end
end
