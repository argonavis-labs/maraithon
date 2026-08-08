defmodule Maraithon.Repo.Migrations.QuarantineUnprovenActiveEffectOwners do
  use Ecto.Migration

  def up do
    # Forward reconciliation for databases that recorded the earlier legacy
    # owner backfill. Do not rewrite non-NULL provenance mismatches.
    # Pending work has never crossed the command boundary and is safe to
    # cancel. Never erase the exact generation of claimed work here: release
    # migrations run while old application nodes may still be executing it.
    execute("""
    UPDATE effects AS effect
    SET status = 'cancelled',
        result = NULL,
        error = 'effect_owner_unproven',
        result_envelope = NULL,
        retry_after = NULL,
        updated_at = timezone('UTC', NOW())
    WHERE effect.status = 'pending'
      AND NOT EXISTS (
        SELECT 1
        FROM agents AS agent
        JOIN agent_runs AS run
          ON run.id = effect.agent_run_id
         AND run.agent_id = effect.agent_id
        JOIN agent_run_steps AS step
          ON step.id = effect.agent_run_step_id
         AND step.agent_run_id = run.id
         AND step.agent_id = effect.agent_id
        WHERE agent.id = effect.agent_id
          AND effect.owner_user_id IS NOT DISTINCT FROM agent.user_id
          AND run.user_id IS NOT DISTINCT FROM agent.user_id
          AND run.status = 'running'
          AND agent.active_run_id = run.id
          AND step.status = 'requested'
      )
    """)

    execute("""
    UPDATE effects AS effect
    SET status = 'cancelling',
        result = NULL,
        result_envelope = NULL,
        retry_after = NULL,
        updated_at = timezone('UTC', NOW())
    WHERE effect.status IN ('claimed', 'cancelling')
      AND NOT EXISTS (
        SELECT 1
        FROM agents AS agent
        JOIN agent_runs AS run
          ON run.id = effect.agent_run_id
         AND run.agent_id = effect.agent_id
        JOIN agent_run_steps AS step
          ON step.id = effect.agent_run_step_id
         AND step.agent_run_id = run.id
         AND step.agent_id = effect.agent_id
        WHERE agent.id = effect.agent_id
          AND effect.owner_user_id IS NOT DISTINCT FROM agent.user_id
          AND run.user_id IS NOT DISTINCT FROM agent.user_id
          AND run.status = 'running'
          AND agent.active_run_id = run.id
          AND step.status = 'requested'
      )
    """)
  end

  def down do
    :ok
  end
end
