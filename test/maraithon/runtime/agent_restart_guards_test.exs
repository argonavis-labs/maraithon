defmodule Maraithon.Runtime.AgentRestartGuardsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentRuntimeLease

  setup do
    user_id = "restart-guard-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{},
        install_status: "enabled",
        status: "running"
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    %{agent: agent}
  end

  test "records the exact owner before release and duplicate DOWN is idempotent", %{agent: agent} do
    assert {:ok, lease} = AgentLeases.claim(agent.id)

    assert {:recorded, guard} =
             AgentRestartGuards.record_crash(agent.id, lease.owner_token, :boom, backoffs_ms: [0])

    assert guard.last_owner_token == lease.owner_token
    assert guard.crash_count == 1
    assert guard.needs_recovery
    refute guard.tripped
    assert Repo.get(AgentRuntimeLease, agent.id) == nil

    assert {:duplicate, duplicate} =
             AgentRestartGuards.record_crash(agent.id, lease.owner_token, :duplicate,
               backoffs_ms: [0]
             )

    assert duplicate.agent_id == guard.agent_id
    assert duplicate.crash_count == 1
    assert duplicate.generation == guard.generation
  end

  test "expired ownership is recorded before its lease evidence is removed", %{agent: agent} do
    assert {:ok, lease} = AgentLeases.claim(agent.id)

    assert {:ignored, :lease_renewed} =
             AgentRestartGuards.record_expired(agent.id, lease.owner_token, backoffs_ms: [0])

    assert AgentLeases.owner?(agent.id, lease.owner_token)
    expire_lease!(agent.id)

    assert {:recorded, guard} =
             AgentRestartGuards.record_expired(agent.id, lease.owner_token, backoffs_ms: [0])

    assert guard.last_owner_token == lease.owner_token
    assert guard.needs_recovery
    assert Repo.get(AgentRuntimeLease, agent.id) == nil
  end

  test "an old delayed DOWN cannot penalize or delete a replacement generation", %{agent: agent} do
    assert {:ok, old_lease} = AgentLeases.claim(agent.id)

    assert {:recorded, first_guard} =
             AgentRestartGuards.record_crash(agent.id, old_lease.owner_token, :old_crash,
               backoffs_ms: [0]
             )

    assert {:ok, replacement} =
             AgentLeases.claim_recovery(agent.id, first_guard.generation)

    assert {:ignored, :stale_owner} =
             AgentRestartGuards.record_crash(agent.id, old_lease.owner_token, :delayed_down,
               backoffs_ms: [0]
             )

    persisted = Repo.get!(AgentRestartGuard, agent.id)
    assert persisted.crash_count == 1
    assert persisted.generation == first_guard.generation
    assert Repo.get!(AgentRuntimeLease, agent.id).owner_token == replacement.owner_token

    assert {:ok, ready} =
             AgentLeases.finish_recovery(
               agent.id,
               replacement.owner_token,
               first_guard.generation
             )

    assert ready.ready_at != nil
    assert AgentLeases.ready?(agent.id, replacement.owner_token)
    refute Repo.get!(AgentRestartGuard, agent.id).needs_recovery
  end

  test "recovery requires the exact due generation", %{agent: agent} do
    assert {:ok, lease} = AgentLeases.claim(agent.id)

    assert {:recorded, guard} =
             AgentRestartGuards.record_crash(agent.id, lease.owner_token, :boom,
               backoffs_ms: [1_000]
             )

    assert {:error, :stale_recovery_generation} =
             AgentLeases.claim_recovery(agent.id, Ecto.UUID.generate())

    assert {:error, :agent_restart_backoff} =
             AgentLeases.claim_recovery(agent.id, guard.generation)

    make_guard_due!(agent.id)
    assert {:ok, recovery} = AgentLeases.claim_recovery(agent.id, guard.generation)

    assert {:error, :stale_recovery_generation} =
             AgentLeases.finish_recovery(
               agent.id,
               recovery.owner_token,
               Ecto.UUID.generate()
             )

    refute AgentLeases.ready?(agent.id, recovery.owner_token)
    assert {:error, :runtime_lease_owned} = AgentRestartGuards.reset_for_operator(agent.id)
    assert Repo.get!(AgentRestartGuard, agent.id).needs_recovery
  end

  test "crash-loop threshold trips durably and stops desired execution", %{agent: agent} do
    owner_token = record_and_recover!(agent, nil, 1)
    owner_token = record_and_recover!(agent, owner_token, 2)

    assert {:recorded, tripped} =
             AgentRestartGuards.record_crash(agent.id, owner_token, :third_crash,
               backoffs_ms: [0],
               max_crashes: 3
             )

    assert tripped.crash_count == 3
    assert tripped.tripped
    assert tripped.needs_recovery
    assert Repo.get!(Agent, agent.id).status == "stopped"
    assert Repo.get(AgentRuntimeLease, agent.id) == nil

    assert {:error, :agent_not_runnable} = AgentLeases.claim(agent.id)

    assert {:error, :agent_not_runnable} =
             AgentLeases.claim_recovery(agent.id, tripped.generation)

    assert {:ok, reset} = AgentRestartGuards.reset_for_operator(agent.id)
    refute reset.tripped
    refute reset.needs_recovery
    assert reset.crash_count == 0
    assert reset.window_started_at == nil
  end

  test "replacement token is never accepted as evidence for another owner", %{agent: agent} do
    assert {:ok, lease} = AgentLeases.claim(agent.id)

    assert {:error, :invalid_restart_guard} =
             AgentRestartGuards.record_crash(agent.id, lease.owner_token, :forged, unknown: true)

    assert {:ignored, :stale_owner} =
             AgentRestartGuards.record_crash(agent.id, Ecto.UUID.generate(), :forged)

    assert AgentLeases.owner?(agent.id, lease.owner_token)
    assert AgentRestartGuards.get(agent.id) == nil
  end

  defp record_and_recover!(agent, nil, expected_count) do
    {:ok, lease} = AgentLeases.claim(agent.id)
    record_and_recover!(agent, lease.owner_token, expected_count)
  end

  defp record_and_recover!(agent, owner_token, expected_count) do
    {:recorded, guard} =
      AgentRestartGuards.record_crash(agent.id, owner_token, :crash,
        backoffs_ms: [0],
        max_crashes: 3
      )

    assert guard.crash_count == expected_count
    {:ok, recovery} = AgentLeases.claim_recovery(agent.id, guard.generation)
    {:ok, _ready} = AgentLeases.finish_recovery(agent.id, recovery.owner_token, guard.generation)
    recovery.owner_token
  end

  defp expire_lease!(agent_id) do
    Repo.query!(
      """
      UPDATE agent_runtime_leases
      SET claimed_at = timezone('UTC', clock_timestamp()) - interval '3 minutes',
          renewed_at = timezone('UTC', clock_timestamp()) - interval '2 minutes',
          lease_until = timezone('UTC', clock_timestamp()) - interval '1 minute',
          ready_at = NULL,
          draining_at = NULL,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE agent_id = $1::uuid
      """,
      [Ecto.UUID.dump!(agent_id)]
    )
  end

  defp make_guard_due!(agent_id) do
    Repo.query!(
      """
      UPDATE agent_restart_guards
      SET blocked_until = timezone('UTC', clock_timestamp()) - interval '1 second'
      WHERE agent_id = $1::uuid
      """,
      [Ecto.UUID.dump!(agent_id)]
    )
  end
end
