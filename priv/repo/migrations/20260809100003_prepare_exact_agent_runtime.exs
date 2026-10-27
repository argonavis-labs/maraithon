defmodule Maraithon.Repo.Migrations.PrepareExactAgentRuntime do
  use Ecto.Migration

  def up do
    execute(normalize_proven_recovery_sql())
    execute(quarantine_unproven_runtime_sql())
  end

  # `recovering` was transient process state in the legacy runtime. Exact
  # ownership keeps desired state in agents.status and recovery state in the
  # restart guard. Only an already-persisted same-user ACTIVE Binding is proof
  # that the legacy row may retain running intent; this migration never creates
  # or revives authority from an Agent/User row, OAuth readiness, or empty maps.
  def normalize_proven_recovery_sql do
    """
    UPDATE agents
    SET
      status = 'running',
      stopped_at = NULL,
      updated_at = timezone('UTC', clock_timestamp())
    WHERE agents.status = 'recovering'
      AND agents.install_status = 'enabled'
      AND EXISTS (
        SELECT 1
        FROM agent_isolation_bindings
        WHERE agent_isolation_bindings.agent_id = agents.id
          AND agent_isolation_bindings.user_id = agents.user_id
          AND agent_isolation_bindings.status = 'active'
      )
    """
  end

  # Missing, paused, revoked, or mismatched consent is fail-closed. Preserve the
  # Binding and every persisted grant verbatim, but make the Agent non-runnable
  # so it cannot hold BootGate closed or claim unscoped runtime authority.
  def quarantine_unproven_runtime_sql do
    """
    UPDATE agents
    SET
      status = 'stopped',
      stopped_at = COALESCE(stopped_at, timezone('UTC', clock_timestamp())),
      updated_at = timezone('UTC', clock_timestamp())
    WHERE agents.status IN ('recovering', 'running', 'degraded')
      AND (
        agents.install_status IS DISTINCT FROM 'enabled'
        OR NOT EXISTS (
          SELECT 1
          FROM agent_isolation_bindings
          WHERE agent_isolation_bindings.agent_id = agents.id
            AND agent_isolation_bindings.user_id = agents.user_id
            AND agent_isolation_bindings.status = 'active'
        )
      )
    """
  end

  def down do
    # Desired-state quarantine may have been reviewed or changed after cutover;
    # mechanically reviving rows during rollback would recreate unsafe authority.
    :ok
  end
end
