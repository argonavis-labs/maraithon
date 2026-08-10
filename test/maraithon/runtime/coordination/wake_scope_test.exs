defmodule Maraithon.Runtime.Coordination.WakeScopeTest do
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
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.WakeCoordinator

  alias Maraithon.Runtime.Coordination.{
    Authority,
    Partitioning,
    Protocol,
    Scope,
    Session
  }

  @revision "wake-scope-test"
  @evidence_id "fly:machines-destroyed:wake-scope-test"
  @activated_by "wake-scope@example.test"
  @evidence_digest Base.encode16(:crypto.hash(:sha256, "wake-scope-test-evidence"))

  setup do
    old_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      old_runtime
      |> Keyword.put(:exact_agent_runtime_enabled, true)
      |> Keyword.put(:multinode_coordination_enabled, true)
      |> Keyword.put(:allow_legacy_effect_protocol_in_test, false)
    )

    session =
      start_supervised!(
        {Session,
         tick_ms: 600_000,
         node_ttl_ms: 300_000,
         partition_ttl_ms: 300_000,
         required_workers: [__MODULE__.NeverReady]}
      )

    # The initial dark-protocol coordinate message is a mailbox barrier; no sleep.
    _ = :sys.get_state(session)

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, old_runtime)

      try do
        :sys.replace_state(session, fn state ->
          %{state | session: nil, leader: nil, phase: :dormant}
        end)
      catch
        :exit, {:noproc, _details} -> :ok
      end
    end)

    :ok
  end

  test "exact admission stays closed while coordination is dark" do
    assert Protocol.mode() == :dark
    assert Scope.active_or_legacy() == {:error, :runtime_coordination_not_active}
    assert AgentLeases.list_bootstrap_agents() == []

    assert {:ok, summary} = WakeCoordinator.reconcile_once()
    assert summary.gate == :closed
    assert summary.ownership == []
    assert summary.admissions == []
  end

  test "two ready nodes select disjoint due, recovery, and bootstrap work before LIMIT" do
    {user_a, user_b} = distinct_partition_users("selection")
    %{node_a: node_a, node_b: node_b} = active_two_node_authority!(user_a, user_b)

    # Insert B first so a global LIMIT 1 would starve A before an Elixir-side filter.
    agent_b = create_bound_agent!(user_b)
    directive_b = enqueue_due!(agent_b, "due-b")
    agent_a = create_bound_agent!(user_a)
    directive_a = enqueue_due!(agent_a, "due-a")
    order_directives!(directive_b.id, directive_a.id)

    recovery_b = create_bound_agent!(user_b)
    put_recovery_guard!(recovery_b)
    recovery_a = create_bound_agent!(user_a)
    put_recovery_guard!(recovery_a)

    put_session!(node_a)
    assert AgentDirectives.list_due_agent_ids(1) == [agent_a.id]
    assert AgentDirectives.list_recovery_agent_ids(1) == [recovery_a.id]
    assert AgentLeases.list_unowned_runnable_ids(1) == [agent_a.id]

    assert AgentLeases.list_bootstrap_agents() |> Enum.map(& &1.id) |> MapSet.new() ==
             MapSet.new([agent_a.id, recovery_a.id])

    put_session!(node_b)
    assert AgentDirectives.list_due_agent_ids(1) == [agent_b.id]
    assert AgentDirectives.list_recovery_agent_ids(1) == [recovery_b.id]
    assert AgentLeases.list_unowned_runnable_ids(1) == [agent_b.id]

    assert AgentLeases.list_bootstrap_agents() |> Enum.map(& &1.id) |> MapSet.new() ==
             MapSet.new([agent_b.id, recovery_b.id])
  end

  test "expired claim, ownership, and recorded-generation reconciliation is partition exact" do
    {user_a, user_b} = distinct_partition_users("reconciliation")
    %{node_a: node_a, node_b: node_b} = active_two_node_authority!(user_a, user_b)

    claim_b = create_expired_claim!(node_b, user_b, "claim-b", 120)
    claim_a = create_expired_claim!(node_a, user_a, "claim-a", 60)
    claim_a_agent_id = claim_a.agent.id
    claim_a_directive_id = claim_a.directive.id
    claim_b_agent_id = claim_b.agent.id
    claim_b_directive_id = claim_b.directive.id

    put_session!(node_a)

    assert [{^claim_a_agent_id, ^claim_a_directive_id, {:ok, recovered_a}}] =
             AgentDirectives.reconcile_expired_claims(1)

    assert recovered_a.status == "pending"
    assert Repo.get!(AgentDirective, claim_b.directive.id).status == "processing"

    put_session!(node_b)

    assert [{^claim_b_agent_id, ^claim_b_directive_id, {:ok, recovered_b}}] =
             AgentDirectives.reconcile_expired_claims(1)

    assert recovered_b.status == "pending"

    ownership_b = create_expired_lease!(node_b, user_b, 120)
    ownership_a = create_expired_lease!(node_a, user_a, 60)
    ownership_a_agent_id = ownership_a.agent.id
    ownership_a_token = ownership_a.lease.owner_token
    ownership_b_agent_id = ownership_b.agent.id
    ownership_b_token = ownership_b.lease.owner_token

    put_session!(node_a)

    assert [{^ownership_a_agent_id, ^ownership_a_token, {:recorded, _}, nil}] =
             AgentDirectives.reconcile_expired_ownership(1, backoffs_ms: [0])

    refute Repo.get(AgentRuntimeLease, ownership_a.agent.id)

    assert Repo.get!(AgentRuntimeLease, ownership_b.agent.id).owner_token ==
             ownership_b.lease.owner_token

    put_session!(node_b)

    assert [{^ownership_b_agent_id, ^ownership_b_token, {:recorded, _}, nil}] =
             AgentDirectives.reconcile_expired_ownership(1, backoffs_ms: [0])

    recorded_b = create_recorded_generation!(node_b, user_b, "recorded-b", 120)
    recorded_a = create_recorded_generation!(node_a, user_a, "recorded-a", 60)
    recorded_a_agent_id = recorded_a.agent.id
    recorded_b_agent_id = recorded_b.agent.id

    put_session!(node_a)

    assert [{^recorded_a_agent_id, {:ok, settled_a}}] =
             AgentDirectives.reconcile_recorded_generations(1)

    assert settled_a.status == "pending"
    assert Repo.get!(AgentDirective, recorded_b.directive.id).status == "processing"

    put_session!(node_b)

    assert [{^recorded_b_agent_id, {:ok, settled_b}}] =
             AgentDirectives.reconcile_recorded_generations(1)

    assert settled_b.status == "pending"
  end

  test "stale ownership epochs and expired node sessions return no wake work" do
    {user_a, user_b} = distinct_partition_users("stale")

    %{
      node_a: node_a,
      node_b: node_b,
      leader: leader,
      partition_a: partition_a
    } = active_two_node_authority!(user_a, user_b)

    agent = create_bound_agent!(user_a)
    directive = enqueue_due!(agent, "stale-due")
    put_session!(node_a)
    assert AgentDirectives.list_due_agent_ids(1) == [agent.id]

    assert {:ok, draining} =
             Authority.begin_partition_drain(leader, partition_a.partition_id,
               target_node_incarnation_id: node_b.id
             )

    assert draining.ownership_epoch == partition_a.ownership_epoch
    assert {:ok, :revoked} = Authority.revoke_partition_workload(node_a, partition_a.partition_id)

    assert {:ok, :released} =
             Authority.release_drained_partition(leader, partition_a.partition_id)

    assert {:ok, preparing} =
             Authority.assign_partition(leader, node_b, partition_a.partition_id, ttl_ms: 300_000)

    assert preparing.ownership_epoch == partition_a.ownership_epoch + 1
    assert {:ok, ready} = Authority.mark_partition_ready(node_b, partition_a.partition_id)

    # The synchronous handoff commits are PostgreSQL barriers. The cached old
    # session can no longer see the row after the ownership epoch advances.
    assert AgentDirectives.list_due_agent_ids(1) == []
    assert AgentLeases.list_unowned_runnable_ids(1) == []

    put_session!(node_b)
    assert AgentDirectives.list_due_agent_ids(1) == [agent.id]

    expire_node_incarnation!(node_b)
    assert {:error, :coordination_session_stale} = Scope.current()
    assert AgentDirectives.list_due_agent_ids(1) == []
    assert AgentDirectives.list_recovery_agent_ids(1) == []
    assert AgentLeases.list_unowned_runnable_ids(1) == []
    assert AgentLeases.list_bootstrap_agents() == []

    assert {:ok,
            %{
              ownership: [],
              recorded: [],
              lifecycle: [],
              recoveries: [],
              admissions: [],
              tripped_effects: 0,
              gate: :closed
            }} = WakeCoordinator.reconcile_once(admit_recoveries: false, limit: 1)

    assert Repo.get!(AgentDirective, directive.id).status == "pending"
    assert ready.ownership_epoch == partition_a.ownership_epoch + 1
  end

  defp active_two_node_authority!(user_a, user_b) do
    activate_protocols!()
    set_role!("maraithon_runtime")

    node_a =
      Authority.register_node(revision: @revision, node_name: "wake-node-a", ttl_ms: 300_000)
      |> ok!()
      |> Authority.mark_node_ready()
      |> ok!()

    node_b =
      Authority.register_node(revision: @revision, node_name: "wake-node-b", ttl_ms: 300_000)
      |> ok!()
      |> Authority.mark_node_ready()
      |> ok!()

    leader =
      Authority.acquire_leader(node_a, 300_000) |> ok!() |> Authority.mark_leader_ready() |> ok!()

    partition_a = assign_user_partition!(leader, node_a, user_a)
    partition_b = assign_user_partition!(leader, node_b, user_b)

    %{
      node_a: node_a,
      node_b: node_b,
      leader: leader,
      partition_a: partition_a,
      partition_b: partition_b
    }
  end

  defp assign_user_partition!(leader, node, user_id) do
    partition_id = Partitioning.partition_for("user:" <> user_id)
    Authority.assign_partition(leader, node, partition_id, ttl_ms: 300_000) |> ok!()
    Authority.mark_partition_ready(node, partition_id) |> ok!()
  end

  defp activate_protocols! do
    set_role!("maraithon_activation_operator")

    assert {:ok, effect_status} =
             ProtocolCutover.activate(confirmation: ProtocolCutover.activation_confirmation())

    assert effect_status in [:activated, :already_active]

    assert {:ok, evidence_status} =
             Protocol.attest_effect_activation_evidence(
               Keyword.delete(coordination_activation_opts(), :confirmation)
             )

    assert evidence_status in [:attested, :already_attested]
    assert {:ok, coordination_status} = Protocol.activate(coordination_activation_opts())
    assert coordination_status in [:activated, :already_active]
    reset_role!()
  end

  defp coordination_activation_opts do
    [
      confirmation: Protocol.activation_confirmation(),
      evidence_id: @evidence_id,
      evidence_digest: @evidence_digest,
      activated_by: @activated_by,
      exact_revision: @revision
    ]
  end

  defp create_bound_agent!(user_id) do
    reset_role!()
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    set_role!("maraithon_runtime")

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{},
        install_status: "enabled",
        status: "running"
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    agent
  end

  defp enqueue_due!(agent, dedupe) do
    {:ok, directive} =
      AgentDirectives.enqueue(agent.id, agent.user_id, "message", %{"dedupe" => dedupe}, dedupe)

    directive
  end

  defp put_recovery_guard!(agent) do
    now = DatabaseClock.now!()

    %AgentRestartGuard{inserted_at: now, updated_at: now}
    |> AgentRestartGuard.changeset(%{
      agent_id: agent.id,
      generation: Ecto.UUID.generate(),
      last_owner_token: Ecto.UUID.generate(),
      blocked_until: nil,
      window_started_at: now,
      crash_count: 1,
      tripped: false,
      needs_recovery: true,
      last_reason: "scope_test"
    })
    |> Repo.insert!()
  end

  defp create_expired_claim!(node, user_id, dedupe, age_seconds) do
    agent = create_bound_agent!(user_id)
    _directive = enqueue_due!(agent, dedupe)
    put_session!(node)
    lease = AgentLeases.claim(agent.id, ttl_ms: 300_000) |> ok!()
    _ready = AgentLeases.mark_ready(agent.id, lease.owner_token) |> ok!()
    claimed = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token) |> ok!()

    Repo.query!(
      """
      UPDATE public.agent_directives
      SET claimed_at = timezone('UTC', clock_timestamp()) - ($2::bigint * interval '1 second'),
          claim_expires_at = timezone('UTC', clock_timestamp()) - interval '1 second',
          updated_at = timezone('UTC', clock_timestamp())
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(claimed.id), age_seconds]
    )

    %{agent: agent, directive: claimed, lease: lease}
  end

  defp create_expired_lease!(node, user_id, age_seconds) do
    agent = create_bound_agent!(user_id)
    put_session!(node)
    lease = AgentLeases.claim(agent.id, ttl_ms: 300_000) |> ok!()
    expire_lease!(agent.id, age_seconds)
    %{agent: agent, lease: lease}
  end

  defp create_recorded_generation!(node, user_id, dedupe, age_seconds) do
    agent = create_bound_agent!(user_id)
    _directive = enqueue_due!(agent, dedupe)
    put_session!(node)
    lease = AgentLeases.claim(agent.id, ttl_ms: 300_000) |> ok!()
    _ready = AgentLeases.mark_ready(agent.id, lease.owner_token) |> ok!()
    claimed = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token) |> ok!()
    expire_lease!(agent.id, age_seconds)

    assert {:recorded, _guard} =
             AgentRestartGuards.record_expired(agent.id, lease.owner_token, backoffs_ms: [0])

    %{agent: agent, directive: claimed, lease: lease}
  end

  defp expire_lease!(agent_id, age_seconds) do
    Repo.query!(
      """
      UPDATE public.agent_runtime_leases
      SET claimed_at = timezone('UTC', clock_timestamp()) - (($2::bigint + 2) * interval '1 second'),
          renewed_at = timezone('UTC', clock_timestamp()) - (($2::bigint + 1) * interval '1 second'),
          lease_until = timezone('UTC', clock_timestamp()) - ($2::bigint * interval '1 second'),
          ready_at = NULL, draining_at = NULL,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE agent_id = $1::uuid
      """,
      [Ecto.UUID.dump!(agent_id), age_seconds]
    )
  end

  defp order_directives!(older_id, newer_id) do
    Repo.query!(
      """
      UPDATE public.agent_directives
      SET available_at = CASE id
            WHEN $1::uuid THEN timezone('UTC', clock_timestamp()) - interval '2 minutes'
            ELSE timezone('UTC', clock_timestamp()) - interval '1 minute'
          END,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE id IN ($1::uuid, $2::uuid)
      """,
      [Ecto.UUID.dump!(older_id), Ecto.UUID.dump!(newer_id)]
    )
  end

  defp expire_node_incarnation!(node) do
    Repo.query!(
      "SELECT set_config('maraithon.runtime_node_action', $1, true)",
      [node.id]
    )

    Repo.query!(
      """
      UPDATE public.runtime_node_incarnations
      SET lease_expires_at = timezone('UTC', clock_timestamp()) - interval '1 second',
          updated_at = timezone('UTC', clock_timestamp())
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(node.id)]
    )

    # Synchronous SQL is the expiry observation barrier.
    assert [[false]] =
             Repo.query!(
               "SELECT lease_expires_at > timezone('UTC', clock_timestamp()) FROM public.runtime_node_incarnations WHERE id = $1::uuid",
               [Ecto.UUID.dump!(node.id)]
             ).rows
  end

  defp put_session!(node) do
    :sys.replace_state(Session, fn state ->
      %{state | session: node, leader: nil, phase: :ready}
    end)

    assert %{phase: :ready, session: %{id: id}} = :sys.get_state(Session)
    assert id == node.id
    :ok
  end

  defp distinct_partition_users(prefix) do
    first = "#{prefix}-0@example.test"
    first_partition = Partitioning.partition_for("user:" <> first)

    second =
      1
      |> Stream.iterate(&(&1 + 1))
      |> Enum.find_value(fn number ->
        candidate = "#{prefix}-#{number}@example.test"

        if Partitioning.partition_for("user:" <> candidate) != first_partition,
          do: candidate,
          else: nil
      end)

    {first, second}
  end

  defp set_role!(role)
       when role in ["maraithon_runtime", "maraithon_activation_operator"] do
    Repo.query!("SET LOCAL ROLE " <> role, [])
    :ok
  end

  defp reset_role! do
    Repo.query!("RESET ROLE", [])
    :ok
  end

  defp ok!({:ok, value}), do: value
end
