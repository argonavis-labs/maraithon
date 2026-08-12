defmodule Maraithon.Runtime.AgentDirectivesTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.Coordination.{Authority, Partition, Partitioning}
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol

  @activation_evidence [
    evidence_id: "test:stopped-fleet:agent-directives",
    evidence_digest: :crypto.hash(:sha256, "agent directives stopped fleet evidence"),
    activated_by: "agent-directives@example.test",
    revision: String.duplicate("d", 40)
  ]

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    original_terminations = Application.get_env(:maraithon, AgentTerminations)
    {termination_public_key, termination_private_key} = :crypto.generate_key(:eddsa, :ed25519)

    Application.put_env(:maraithon, AgentTerminations,
      external_attestation_public_key: termination_public_key
    )

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      original_runtime
      |> Keyword.put(:multinode_coordination_enabled, true)
      |> Keyword.delete(:coordination_test_session)
      |> Keyword.delete(:coordination_test_leader)
    )

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)

      if original_terminations,
        do: Application.put_env(:maraithon, AgentTerminations, original_terminations),
        else: Application.delete_env(:maraithon, AgentTerminations)
    end)

    assert ProtocolCutover.mode() == :legacy

    assert {:ok, :attested} =
             CoordinationProtocol.attest_effect_activation_evidence(@activation_evidence)

    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    assert {:ok, :activated} = activate_exact()

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
    :ok = ensure_user_partition!(user_id)

    %{
      agent: agent,
      binding: binding,
      user_id: user_id,
      termination_private_key: termination_private_key
    }
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

  test "transaction-aware enqueue participates in the caller commit", %{
    agent: agent,
    user_id: user_id
  } do
    assert {:error, :transaction_required} =
             AgentDirectives.enqueue_in_transaction(
               agent.id,
               user_id,
               "message",
               %{"body" => "outside"},
               "outside"
             )

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert {:ok, _directive} =
                        AgentDirectives.enqueue_in_transaction(
                          agent.id,
                          user_id,
                          "message",
                          %{"body" => "atomic"},
                          "atomic"
                        )

               Repo.rollback(:forced_rollback)
             end)

    refute Repo.get_by(AgentDirective, agent_id: agent.id, dedupe_key: "atomic")
  end

  test "settle_with runs terminal writes once and immutable proof survives lease release", %{
    agent: agent,
    user_id: user_id
  } do
    assert {:ok, _directive} =
             AgentDirectives.enqueue(agent.id, user_id, "message", %{}, "settle-once")

    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    assert {:ok, claimed} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)
    caller = self()

    terminal_callback = fn _directive, _now ->
      send(caller, :terminal_callback_ran)
      {:ok, :terminal_write}
    end

    assert {:ok,
            %{newly_terminal?: true, result: :terminal_write, directive: %{status: "completed"}}} =
             AgentDirectives.settle_with(
               agent.id,
               claimed.id,
               lease.owner_token,
               claimed.claim_token,
               "completed",
               nil,
               terminal_callback
             )

    assert_receive :terminal_callback_ran
    assert {:ok, :released} = AgentLeases.release(agent.id, lease.owner_token)

    assert {:ok, %{newly_terminal?: false, result: nil}} =
             AgentDirectives.settle_with(
               agent.id,
               claimed.id,
               lease.owner_token,
               claimed.claim_token,
               "completed",
               nil,
               terminal_callback
             )

    refute_receive :terminal_callback_ran
  end

  test "ready and owner claim fences differ only for draining settlement", %{
    agent: agent,
    user_id: user_id
  } do
    assert {:ok, _directive} =
             AgentDirectives.enqueue(agent.id, user_id, "message", %{}, "claim-modes")

    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    assert {:ok, claimed} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)
    assert {:ok, _draining} = AgentLeases.begin_draining(agent.id, lease.owner_token)

    assert {:error, :runtime_not_ready} =
             AgentDirectives.with_live_claim(
               agent.id,
               claimed.id,
               lease.owner_token,
               claimed.claim_token,
               :ready,
               fn _directive, _now -> {:ok, :unsafe_new_work} end
             )

    assert {:ok, :terminal_closure} =
             AgentDirectives.with_live_claim(
               agent.id,
               claimed.id,
               lease.owner_token,
               claimed.claim_token,
               :owner,
               fn _directive, _now -> {:ok, :terminal_closure} end
             )

    assert {:ok, _terminal} =
             AgentDirectives.complete(
               agent.id,
               claimed.id,
               lease.owner_token,
               claimed.claim_token
             )
  end

  test "lease and claim renewal can be rolled back as one authority transaction", %{
    agent: agent,
    user_id: user_id
  } do
    assert {:ok, _directive} =
             AgentDirectives.enqueue(agent.id, user_id, "message", %{}, "joint-renewal")

    assert {:ok, lease} = AgentLeases.claim(agent.id, ttl_ms: 60_000)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)

    assert {:ok, claimed} =
             AgentDirectives.claim_next(agent.id, user_id, lease.owner_token, ttl_ms: 30_000)

    original_lease_until = AgentLeases.get(agent.id).lease_until
    original_claim_until = Repo.get!(AgentDirective, claimed.id).claim_expires_at

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert {:ok, _renewed_lease} =
                        AgentLeases.renew(agent.id, lease.owner_token, ttl_ms: 120_000)

               assert {:ok, _renewed_claim} =
                        AgentDirectives.renew_claim_in_transaction(
                          agent.id,
                          claimed.id,
                          lease.owner_token,
                          claimed.claim_token,
                          ttl_ms: 90_000
                        )

               Repo.rollback(:forced_rollback)
             end)

    assert AgentLeases.get(agent.id).lease_until == original_lease_until
    assert Repo.get!(AgentDirective, claimed.id).claim_expires_at == original_claim_until
  end

  test "owner loss after effect admission dead-letters instead of replaying", %{
    agent: agent,
    user_id: user_id
  } do
    assert {:ok, _directive} =
             AgentDirectives.enqueue(agent.id, user_id, "message", %{}, "effect-boundary")

    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    assert {:ok, claimed} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)

    assert {:ok, %{run_id: run_id, ordinal: 1}} =
             AgentDirectives.with_live_claim(
               agent.id,
               claimed.id,
               lease.owner_token,
               claimed.claim_token,
               :ready,
               fn directive, now ->
                 with {:ok, run} <-
                        Agents.start_runtime_agent_run(agent, %{trigger_type: "message"}),
                      {:ok, directive} <- AgentDirectives.bind_run_locked(directive, run.id, now),
                      {:ok, _directive, ordinal} <-
                        AgentDirectives.admit_effect_locked(directive, run.id, now) do
                   {:ok, %{run_id: run.id, ordinal: ordinal}}
                 end
               end
             )

    assert is_binary(run_id)

    assert {:recorded, _guard} =
             AgentRestartGuards.record_crash(agent.id, lease.owner_token, :runtime_crash,
               backoffs_ms: [0]
             )

    assert {:ok, terminal} = AgentDirectives.recover_generation(agent.id, lease.owner_token)
    assert terminal.status == "dead_letter"
    assert terminal.last_error_code == "owner_lost_after_effect"
    assert terminal.ambiguity_code == "effect_outcome_ambiguous"
    assert terminal.effect_count == 1
    assert terminal.active_run_id == run_id
    refute agent.id in AgentDirectives.list_due_agent_ids()
  end

  defp activate_exact do
    effect_result =
      ProtocolCutover.activate(
        [confirmation: ProtocolCutover.activation_confirmation()] ++ @activation_evidence
      )

    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)

    case effect_result do
      {:ok, effect_status} when effect_status in [:activated, :already_active] ->
        Repo.query!("SET LOCAL ROLE maraithon_activation_operator", [], log: false)

        runtime_result =
          CoordinationProtocol.activate(
            [confirmation: CoordinationProtocol.activation_confirmation()] ++ @activation_evidence
          )

        Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)

        case runtime_result do
          {:ok, runtime_status} when runtime_status in [:activated, :already_active] ->
            ensure_coordination_authority!()
            {:ok, effect_status}

          {:error, reason} ->
            {:error, reason}
        end

      other ->
        other
    end
  end

  defp ensure_coordination_authority! do
    runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    unless Keyword.get(runtime, :coordination_test_session) do
      {:ok, joining} =
        Authority.register_node(
          node_name: "agent-directives@test",
          revision: String.duplicate("d", 40),
          ttl_ms: 300_000
        )

      {:ok, session} = Authority.mark_node_ready(joining)
      {:ok, preparing_leader} = Authority.acquire_leader(session, 300_000)
      {:ok, leader} = Authority.mark_leader_ready(preparing_leader)

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        runtime
        |> Keyword.put(:coordination_test_session, session)
        |> Keyword.put(:coordination_test_leader, leader)
      )
    end

    :ok
  end

  defp ensure_user_partition!(user_id) do
    runtime = Application.fetch_env!(:maraithon, Maraithon.Runtime)
    session = Keyword.fetch!(runtime, :coordination_test_session)
    leader = Keyword.fetch!(runtime, :coordination_test_leader)
    partition_id = user_id |> Partitioning.tenant_key() |> Partitioning.partition_for()

    case Repo.get!(Partition, partition_id) do
      %Partition{state: "unassigned"} ->
        {:ok, _preparing} =
          Authority.assign_partition(leader, session, partition_id, ttl_ms: 300_000)

        {:ok, _ready} = Authority.mark_partition_ready(session, partition_id)
        :ok

      %Partition{
        state: "ready",
        owner_node_incarnation_id: owner_id,
        activation_epoch: activation_epoch
      }
      when owner_id == session.id and activation_epoch == session.activation_epoch ->
        :ok
    end
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
    runtime_role =
      Repo.query!("SELECT current_role::text", [], log: false).rows
      |> List.first()
      |> List.first()

    try do
      Repo.query!("RESET ROLE", [], log: false)
      Repo.query!("SET LOCAL session_replication_role = replica", [], log: false)

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
    after
      Repo.query!("SET LOCAL session_replication_role = origin", [], log: false)
      Repo.query!("SET LOCAL ROLE #{runtime_role}", [], log: false)
    end
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
