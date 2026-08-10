defmodule Maraithon.Runtime.AgentDirectivesTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRestartGuards

  setup do
    user_id = "directive-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{},
        install_status: "enabled",
        status: "running"
      })

    {:ok, binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    %{agent: agent, binding: binding, user_id: user_id}
  end

  test "enqueue is bounded, canonical, tenant-exact, and idempotent", %{
    agent: agent,
    binding: binding,
    user_id: user_id
  } do
    assert {:ok, first} =
             AgentDirectives.enqueue(agent.id, user_id, :message, %{body: "hello"}, "event-1")

    assert first.payload == %{"body" => "hello"}
    assert byte_size(first.request_fingerprint) == 32
    assert first.inserted_at == first.available_at
    assert first.updated_at == first.available_at

    assert {:ok, duplicate} =
             AgentDirectives.enqueue(
               agent.id,
               user_id,
               "message",
               %{"body" => "hello"},
               "event-1",
               max_attempts: 99
             )

    assert duplicate.id == first.id
    assert duplicate.max_attempts == 3

    assert {:error, :directive_idempotency_conflict} =
             AgentDirectives.enqueue(
               agent.id,
               user_id,
               "message",
               %{"body" => "changed"},
               "event-1"
             )

    assert {:error, :invalid_directive} =
             AgentDirectives.enqueue(
               agent.id,
               user_id,
               "message",
               %{"same" => 1, same: 2},
               "collision"
             )

    assert {:error, :invalid_directive} =
             AgentDirectives.enqueue(
               agent.id,
               user_id,
               "message",
               %{"body" => String.duplicate("x", 128_001)},
               "oversized"
             )

    assert {:error, :agent_owner_mismatch} =
             AgentDirectives.enqueue(
               agent.id,
               "other@example.com",
               "message",
               %{},
               "wrong-user"
             )

    binding |> Ecto.Changeset.change(status: "paused") |> Repo.update!()

    assert {:error, :agent_binding_not_active} =
             AgentDirectives.enqueue(agent.id, user_id, "message", %{}, "paused")
  end

  test "only due demand without a lease is selected for wake", %{agent: agent, user_id: user_id} do
    assert {:ok, directive} =
             AgentDirectives.enqueue(
               agent.id,
               user_id,
               "scheduled_wakeup",
               %{"schedule" => "daily"},
               "future",
               delay_ms: 60_000
             )

    refute agent.id in AgentDirectives.list_due_agent_ids()
    make_due!(directive.id)
    assert agent.id in AgentDirectives.list_due_agent_ids()

    assert {:ok, lease} = AgentLeases.claim(agent.id)
    refute agent.id in AgentDirectives.list_due_agent_ids()
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    refute agent.id in AgentDirectives.list_due_agent_ids()
  end

  test "claim requires one exact ready generation and one processing row", %{
    agent: agent,
    user_id: user_id
  } do
    assert {:ok, first} =
             AgentDirectives.enqueue(agent.id, user_id, "message", %{"n" => 1}, "first")

    assert {:ok, _second} =
             AgentDirectives.enqueue(agent.id, user_id, "message", %{"n" => 2}, "second")

    assert {:error, :runtime_lease_lost} =
             AgentDirectives.claim_next(agent.id, user_id, Ecto.UUID.generate())

    assert {:ok, lease} = AgentLeases.claim(agent.id)

    assert {:error, :runtime_not_ready} =
             AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)

    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    assert {:ok, claimed} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)
    assert claimed.id == first.id
    assert claimed.status == "processing"
    assert claimed.attempts == 1
    assert claimed.claimed_by_generation == lease.owner_token
    assert Ecto.UUID.cast(claimed.claim_token) != :error
    assert DateTime.compare(claimed.claim_expires_at, lease.lease_until) in [:lt, :eq]

    assert {:ok, nil} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)

    assert {:error, :directive_claim_lost} =
             AgentDirectives.renew_claim(
               agent.id,
               claimed.id,
               lease.owner_token,
               Ecto.UUID.generate()
             )

    assert {:ok, completed} =
             AgentDirectives.complete(
               agent.id,
               claimed.id,
               lease.owner_token,
               claimed.claim_token
             )

    assert completed.status == "completed"
    assert completed.payload == %{"redacted" => true}
    assert completed.terminal_claim_token == claimed.claim_token
    assert completed.terminal_by_generation == lease.owner_token
    assert {:ok, :released} = AgentLeases.release(agent.id, lease.owner_token)

    assert {:ok, idempotent} =
             AgentDirectives.complete(
               agent.id,
               claimed.id,
               lease.owner_token,
               claimed.claim_token
             )

    assert idempotent.id == completed.id
    assert {:ok, replacement_lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, replacement_lease.owner_token)

    assert {:ok, next_claim} =
             AgentDirectives.claim_next(agent.id, user_id, replacement_lease.owner_token)

    assert next_claim.dedupe_key == "second"
  end

  test "exact draining owner may settle work but cannot claim new work", %{
    agent: agent,
    user_id: user_id
  } do
    assert {:ok, _directive} =
             AgentDirectives.enqueue(agent.id, user_id, "background_job", %{"job" => 1}, "job")

    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    assert {:ok, claimed} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)
    assert {:ok, _draining} = AgentLeases.begin_draining(agent.id, lease.owner_token)
    assert {:error, :runtime_work_in_progress} = AgentLeases.release(agent.id, lease.owner_token)

    assert {:error, :runtime_not_ready} =
             AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)

    assert {:ok, terminal} =
             AgentDirectives.complete(
               agent.id,
               claimed.id,
               lease.owner_token,
               claimed.claim_token
             )

    assert terminal.status == "completed"
    assert {:ok, :released} = AgentLeases.release(agent.id, lease.owner_token)
  end

  test "retry retains bounded input and the last attempt dead-letters with redaction", %{
    agent: agent,
    user_id: user_id
  } do
    assert {:ok, _directive} =
             AgentDirectives.enqueue(
               agent.id,
               user_id,
               "connector_sync",
               %{"source" => "gmail"},
               "sync",
               max_attempts: 2
             )

    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)

    assert {:ok, first} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)

    assert {:ok, retrying} =
             AgentDirectives.fail(
               agent.id,
               first.id,
               lease.owner_token,
               first.claim_token,
               :timeout
             )

    assert retrying.status == "pending"
    assert retrying.payload == %{"source" => "gmail"}
    assert retrying.last_error_code == "timeout"

    assert {:ok, second} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)
    assert second.attempts == 2

    assert {:ok, terminal} =
             AgentDirectives.fail(
               agent.id,
               second.id,
               lease.owner_token,
               second.claim_token,
               :effect_failed
             )

    assert terminal.status == "dead_letter"
    assert terminal.payload == %{"redacted" => true}
    assert terminal.last_error_code == "effect_failed"
    assert terminal.terminal_at
    refute terminal.claim_token
    assert terminal.terminal_claim_token == second.claim_token
    assert {:ok, :released} = AgentLeases.release(agent.id, lease.owner_token)

    assert {:ok, duplicate_terminal} =
             AgentDirectives.fail(
               agent.id,
               second.id,
               lease.owner_token,
               second.claim_token,
               :effect_failed
             )

    assert duplicate_terminal.id == terminal.id
  end

  test "recorded crash recovery is exact and idempotent", %{agent: agent, user_id: user_id} do
    assert {:ok, _directive} =
             AgentDirectives.enqueue(
               agent.id,
               user_id,
               "message",
               %{"body" => "recover"},
               "recover"
             )

    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    assert {:ok, claimed} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)

    assert {:recorded, guard} =
             AgentRestartGuards.record_crash(agent.id, lease.owner_token, :runtime_crash,
               backoffs_ms: [0]
             )

    assert guard.last_owner_token == lease.owner_token
    assert Repo.get!(AgentRestartGuard, agent.id).needs_recovery
    refute agent.id in AgentDirectives.list_due_agent_ids()
    assert agent.id in AgentDirectives.list_recovery_agent_ids()

    assert {:error, :runtime_work_requires_reconciliation} =
             AgentLeases.claim_recovery(agent.id, guard.generation)

    assert {:error, :runtime_work_requires_reconciliation} =
             AgentRestartGuards.reset_for_operator(agent.id)

    assert [{recovered_agent_id, {:ok, recovered}}] =
             AgentDirectives.reconcile_recorded_generations(10)

    assert recovered_agent_id == agent.id
    assert recovered.id == claimed.id
    assert recovered.status == "pending"
    assert recovered.last_error_code == "runtime_crash"
    assert {:ok, nil} = AgentDirectives.recover_generation(agent.id, lease.owner_token)

    assert {:error, :stale_recovery_generation} =
             AgentDirectives.recover_generation(agent.id, Ecto.UUID.generate())

    assert {:ok, recovery_lease} = AgentLeases.claim_recovery(agent.id, guard.generation)

    assert {:error, :runtime_lease_owned} =
             AgentDirectives.recover_generation(agent.id, lease.owner_token)

    assert {:ok, _ready} =
             AgentLeases.finish_recovery(
               agent.id,
               recovery_lease.owner_token,
               guard.generation
             )

    assert {:ok, reclaimed} =
             AgentDirectives.claim_next(agent.id, user_id, recovery_lease.owner_token)

    assert reclaimed.id == claimed.id
    assert reclaimed.attempts == 2
  end

  test "expired claim tokens cannot settle and the ready owner rotates them", %{
    agent: agent,
    user_id: user_id
  } do
    assert {:ok, _directive} =
             AgentDirectives.enqueue(
               agent.id,
               user_id,
               "background_job",
               %{"job" => "bounded"},
               "expired-claim",
               max_attempts: 3
             )

    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)

    assert {:ok, first} =
             AgentDirectives.claim_next(agent.id, user_id, lease.owner_token, ttl_ms: 1_000)

    expire_claim!(first.id)
    assert {:ok, _draining} = AgentLeases.begin_draining(agent.id, lease.owner_token)

    assert {:error, :directive_claim_expired} =
             AgentDirectives.renew_claim(
               agent.id,
               first.id,
               lease.owner_token,
               first.claim_token
             )

    assert {:error, :directive_claim_expired} =
             AgentDirectives.complete(
               agent.id,
               first.id,
               lease.owner_token,
               first.claim_token
             )

    assert {:error, :directive_claim_expired} =
             AgentDirectives.fail(
               agent.id,
               first.id,
               lease.owner_token,
               first.claim_token,
               :timeout
             )

    assert [{recovered_agent_id, recovered_directive_id, {:ok, recovered}}] =
             AgentDirectives.reconcile_expired_claims(10)

    assert recovered_agent_id == agent.id
    assert recovered_directive_id == first.id
    assert recovered.status == "pending"
    assert {:ok, :released} = AgentLeases.release(agent.id, lease.owner_token)
    assert {:ok, replacement_lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, replacement_lease.owner_token)

    assert {:ok, replacement} =
             AgentDirectives.claim_next(agent.id, user_id, replacement_lease.owner_token)

    assert replacement.id == first.id
    assert replacement.attempts == 2
    assert replacement.claim_token != first.claim_token
    assert replacement.last_error_code == nil
  end

  test "expired lease reconciliation records guard before requeue", %{
    agent: agent,
    user_id: user_id
  } do
    assert {:ok, _directive} =
             AgentDirectives.enqueue(agent.id, user_id, "message", %{}, "expired-owner")

    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    assert {:ok, claimed} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)
    expire_lease!(agent.id)

    assert [{agent_id, generation, {:recorded, guard}, {:ok, recovered}}] =
             AgentDirectives.reconcile_expired_ownership(10, backoffs_ms: [0])

    assert agent_id == agent.id
    assert generation == lease.owner_token
    assert guard.last_owner_token == lease.owner_token
    assert guard.needs_recovery
    assert recovered.id == claimed.id
    assert recovered.status == "pending"
    assert AgentLeases.get(agent.id) == nil
    assert AgentDirectives.reconcile_recorded_generations(10) == []
  end

  test "a tripped generation still settles its claimed directive before reset", %{
    agent: agent,
    user_id: user_id
  } do
    assert {:ok, _directive} =
             AgentDirectives.enqueue(
               agent.id,
               user_id,
               "runtime_control",
               %{"operation" => "trip"},
               "trip",
               max_attempts: 1
             )

    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    assert {:ok, claimed} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)

    assert {:recorded, guard} =
             AgentRestartGuards.record_crash(agent.id, lease.owner_token, :runtime_crash,
               max_crashes: 1,
               backoffs_ms: [0]
             )

    assert guard.tripped
    assert guard.needs_recovery

    assert {:ok, terminal} =
             AgentDirectives.recover_generation(agent.id, lease.owner_token)

    assert terminal.id == claimed.id
    assert terminal.status == "dead_letter"
    assert terminal.terminal_claim_token == claimed.claim_token
    assert {:ok, reset} = AgentRestartGuards.reset_for_operator(agent.id)
    refute reset.needs_recovery
  end

  defp expire_claim!(directive_id) do
    Repo.query!(
      """
      UPDATE agent_directives
      SET claimed_at = timezone('UTC', clock_timestamp()) - interval '2 seconds',
          processing_started_at = timezone('UTC', clock_timestamp()) - interval '2 seconds',
          claim_expires_at = timezone('UTC', clock_timestamp()) - interval '1 second',
          updated_at = timezone('UTC', clock_timestamp())
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(directive_id)]
    )
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

  defp make_due!(directive_id) do
    Repo.query!(
      """
      UPDATE agent_directives
      SET available_at = timezone('UTC', clock_timestamp()) - interval '1 second',
          updated_at = timezone('UTC', clock_timestamp())
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(directive_id)]
    )
  end
end
