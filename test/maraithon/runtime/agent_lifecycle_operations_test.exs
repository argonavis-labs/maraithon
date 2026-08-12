defmodule Maraithon.Runtime.AgentLifecycleOperationsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentSubscriptions.AgentSubscription
  alias Maraithon.Agents
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Repo
  alias Maraithon.Runtime
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.Bootstrap
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.ScheduledJob
  alias Maraithon.Runtime.WakeCoordinator
  alias Maraithon.Runtime.Coordination.{Authority, Partition, Partitioning}
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol

  @activation_evidence [
    evidence_id: "test:stopped-fleet:agent-lifecycle-operations",
    evidence_digest: :crypto.hash(:sha256, "test stopped fleet evidence"),
    activated_by: "agent-lifecycle-operations@example.test",
    revision: String.duplicate("b", 40)
  ]

  test "establishes one immutable marker with the stopped/readiness fence and adopts retries" do
    agent = running_consented_agent("marker-adopt")
    {lease, watcher, owner_pid} = monitored_owner(agent.id)

    request = %{"params" => %{"config" => %{"revision" => 2}}}

    planner = fn _locked ->
      %{"action" => "update", "attrs" => %{"config" => %{"revision" => 2}}}
    end

    assert {:ok, first} = AgentLifecycleOperations.begin(agent.id, :update, request, planner)
    assert first.disposition == :created
    assert first.operation.operation_token == first.operation_token
    assert first.operation.expected_owner_token == lease.owner_token

    stopped = Agents.get_agent(agent.id)
    assert stopped.status == "stopped"

    assert %AgentRuntimeLease{owner_token: owner_token, ready_at: nil, draining_at: draining_at} =
             AgentLeases.get(agent.id)

    assert owner_token == lease.owner_token
    assert draining_at != nil
    assert {:error, :agent_drain_pending} = Agents.claim_agent_start(agent.id)
    assert {:error, :agent_drain_pending} = AgentLeases.claim(agent.id)

    assert {:ok, retry} = AgentLifecycleOperations.begin(agent.id, :update, request, planner)
    assert retry.disposition == :adopted
    assert retry.operation_token == first.operation_token

    assert {:error, :agent_drain_pending} =
             AgentLifecycleOperations.begin(
               agent.id,
               :update,
               %{"params" => %{"config" => %{"revision" => 3}}},
               planner
             )

    assert {:error, :termination_proof_required} =
             AgentLeases.release(agent.id, lease.owner_token)

    prove_owner_down(watcher, owner_pid)
    assert AgentLeases.get(agent.id) == nil

    assert {:ok, %{status: :finalized, agent: finalized, resume_after: true}} =
             AgentLifecycleOperations.finalize(agent.id, first.operation_token)

    assert finalized.status == "running"
    assert finalized.config == %{"revision" => 2}
    assert AgentLifecycleOperations.get(agent.id) == nil
  end

  test "unresolved work retains the marker and performs no delivery or config mutation" do
    agent = running_consented_agent("atomic-finalize", %{"subscribe" => ["topic:old"]})
    scheduled = scheduled_job(agent.id)
    subscription = Repo.get_by!(AgentSubscription, agent_id: agent.id, topic: "topic:old")
    effect = pending_effect(agent.id)

    request = %{"params" => %{"config" => %{"revision" => "new"}}}

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(agent.id, :update, request, fn locked ->
               %{
                 "action" => "update",
                 "attrs" => %{
                   "behavior" => locked.behavior,
                   "config" => Map.put(locked.config || %{}, "revision", "new")
                 }
               }
             end)

    assert {:ok, %{status: :reconciliation_pending, reason: :active_effect}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert AgentLifecycleOperations.get(agent.id).operation_token == fence.operation_token
    assert Agents.get_agent(agent.id).config["revision"] == nil
    assert Repo.reload!(scheduled).status == "pending"
    assert Repo.reload!(subscription).status == "active"

    effect
    |> Ecto.Changeset.change(status: "cancelled", error: "test_quiesced")
    |> Repo.update!()

    assert {:ok, %{status: :finalized, agent: finalized}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert finalized.config["revision"] == "new"
    assert Repo.reload!(scheduled).status == "cancelled"
    # Finalization deletes its marker under the retained prefix locks before it
    # derives delivery authority, so the resumed plan is active only on commit.
    assert AgentLifecycleOperations.get(agent.id) == nil
    assert Repo.reload!(subscription).status == "active"
  end

  test "delete cannot cascade while work is live and start cannot cross its marker" do
    agent = running_consented_agent("delete-fence")
    effect = pending_effect(agent.id)

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :delete,
               %{"delete" => true},
               fn _agent -> %{"action" => "delete"} end
             )

    assert {:error, :agent_drain_pending} = Agents.claim_agent_start(agent.id)

    assert {:ok, %{status: :reconciliation_pending, reason: :active_effect}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert Agents.get_agent(agent.id, include_removed: true) != nil

    effect |> Ecto.Changeset.change(status: "cancelled") |> Repo.update!()

    assert {:ok, %{status: :finalized, action: :deleted}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert Agents.get_agent(agent.id, include_removed: true) == nil
    assert AgentLifecycleOperations.get(agent.id) == nil
  end

  test "legacy lifecycle delete accepts terminal Effects that predate result envelopes" do
    agent = running_consented_agent("legacy-terminal-delete")

    effect =
      agent.id
      |> pending_effect()
      |> Ecto.Changeset.change(status: "completed")
      |> Repo.update!()

    assert effect.runtime_owner_generation == nil
    assert effect.result_envelope == nil

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :delete,
               %{"delete" => true},
               fn _agent -> %{"action" => "delete"} end
             )

    assert {:ok, %{status: :finalized, action: :deleted}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    refute Repo.get(Effect, effect.id)
    refute Agents.get_agent(agent.id, include_removed: true)
  end

  test "corrupt Effect ciphertext is deleted only after active authority is cancelled" do
    terminal_agent = running_consented_agent("corrupt-terminal-delete")
    terminal_effect = pending_effect(terminal_agent.id)

    terminal_effect
    |> Ecto.Changeset.change(status: "cancelled")
    |> Repo.update!()

    seed_preexisting_corrupt_ciphertext!(terminal_effect.id)

    assert {:ok, terminal_fence} =
             AgentLifecycleOperations.begin(
               terminal_agent.id,
               :delete,
               %{"delete" => true},
               fn _agent -> %{"action" => "delete"} end
             )

    assert {:ok, %{status: :finalized, action: :deleted}} =
             AgentLifecycleOperations.finalize(
               terminal_agent.id,
               terminal_fence.operation_token
             )

    refute Repo.get(Effect, terminal_effect.id)

    active_agent = running_consented_agent("corrupt-active-block")
    active_effect = pending_effect(active_agent.id)

    seed_preexisting_corrupt_ciphertext!(active_effect.id)

    assert {:ok, active_fence} =
             AgentLifecycleOperations.begin(
               active_agent.id,
               :delete,
               %{"delete" => true},
               fn _agent -> %{"action" => "delete"} end
             )

    assert {:ok, %{status: :reconciliation_pending, reason: :active_effect}} =
             AgentLifecycleOperations.finalize(active_agent.id, active_fence.operation_token)

    assert Agents.get_agent(active_agent.id, include_removed: true)

    assert AgentLifecycleOperations.get(active_agent.id).operation_token ==
             active_fence.operation_token

    assert %{rows: [["cancelled"]]} =
             Repo.query!("SELECT status FROM effects WHERE id = $1", [
               Ecto.UUID.dump!(active_effect.id)
             ])

    assert {:ok, %{status: :finalized, action: :deleted}} =
             AgentLifecycleOperations.finalize(active_agent.id, active_fence.operation_token)

    refute Agents.get_agent(active_agent.id, include_removed: true)
  end

  test "expired lease loss is adopted into the marker and its matching guard is cleared" do
    agent = running_consented_agent("expired-guard")
    {:ok, lease} = AgentLeases.claim(agent.id)
    {:ok, ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)

    ready
    |> Ecto.Changeset.change(lease_until: DateTime.add(ready.ready_at, 1, :microsecond))
    |> Repo.update!()

    assert {:error, :agent_stop_reconciliation_pending} =
             Runtime.stop_agent(agent.id, "expired_owner")

    assert %{owner_token: owner_token} = AgentLeases.get(agent.id)
    assert owner_token == lease.owner_token
    assert AgentRestartGuards.get(agent.id) == nil
    assert AgentLifecycleOperations.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "running"

    assert %{status: "requested", lease_token: ^owner_token} =
             AgentTerminations.get_by_lease(owner_token)
  end

  test "WakeCoordinator finishes a stranded ordinary operation from its stored digest" do
    enable_exact_reconciliation!()
    agent = running_consented_agent("wake-finalize")
    ensure_user_partition!(agent.user_id)

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :stop,
               %{"reason" => "crash_after_fence"},
               fn _agent -> %{"action" => "stop"} end
             )

    assert AgentLifecycleOperations.get(agent.id).operation_token == fence.operation_token

    assert {:ok, %{lifecycle: lifecycle}} =
             WakeCoordinator.reconcile_once(admit_recoveries: false, limit: 10)

    assert Enum.any?(lifecycle, fn
             {agent_id, {:ok, %{status: :finalized}}, :not_started} -> agent_id == agent.id
             _other -> false
           end)

    assert AgentLifecycleOperations.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "stopped"
  end

  test "closed admission finalizes resume lifecycle work without starting an Agent" do
    enable_exact_reconciliation!()
    agent = running_consented_agent("wake-finalize-closed-gate")
    ensure_user_partition!(agent.user_id)

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :update,
               %{"params" => %{"config" => %{"revision" => 2}}},
               fn locked ->
                 %{
                   "action" => "update",
                   "attrs" => %{
                     "behavior" => locked.behavior,
                     "config" => Map.put(locked.config || %{}, "revision", 2)
                   }
                 }
               end
             )

    assert fence.operation.payload["resume_after"]

    assert {:ok, %{gate: :closed, lifecycle: lifecycle, admissions: []}} =
             WakeCoordinator.reconcile_once(admit_recoveries: false, limit: 10)

    assert Enum.any?(lifecycle, fn
             {agent_id, {:ok, %{status: :finalized, resume_after: true}}, :boot_gate_closed} ->
               agent_id == agent.id

             _other ->
               false
           end)

    assert AgentLifecycleOperations.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "running"
    assert AgentLeases.get(agent.id) == nil
  end

  test "a conservative retry upgrades an adopted operation to require external drain" do
    agent = running_consented_agent("external-drain-adoption")
    request = %{"reason" => "concurrent_registry_observation"}
    planner = fn _agent -> %{"action" => "stop"} end

    assert {:ok, first} =
             AgentLifecycleOperations.begin(agent.id, :stop, request, planner)

    refute first.operation.requires_external_drain

    assert {:ok, adopted} =
             AgentLifecycleOperations.begin(agent.id, :stop, request, planner,
               requires_external_drain: true
             )

    assert adopted.disposition == :adopted
    assert adopted.operation_token == first.operation_token
    assert adopted.operation.requires_external_drain

    assert {:ok, %{status: :reconciliation_pending, reason: :external_fleet_drain_required}} =
             AgentLifecycleOperations.finalize(agent.id, adopted.operation_token)
  end

  test "unfenced legacy evidence requires explicit non-rolling fleet-drain confirmation" do
    agent = running_consented_agent("external-drain")

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :stop,
               %{"reason" => "legacy_process_observed"},
               fn _agent -> %{"action" => "stop"} end,
               requires_external_drain: true
             )

    assert fence.operation.requires_external_drain

    assert {:ok, %{status: :reconciliation_pending, reason: :external_fleet_drain_required}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert {:error, :invalid_external_drain_evidence} =
             AgentLifecycleOperations.confirm_external_drain(
               agent.id,
               fence.operation_token,
               %{"non_rolling" => false}
             )

    evidence = %{
      "non_rolling" => true,
      "proof_id" => "cutover-change-123",
      "confirmed_by" => "release-operator@example.com",
      "legacy_revision" => "legacy-revision-sha"
    }

    assert {:ok, confirmed} =
             AgentLifecycleOperations.confirm_external_drain(
               agent.id,
               fence.operation_token,
               evidence
             )

    assert confirmed.external_drain_confirmed_at != nil
    assert byte_size(confirmed.external_drain_evidence_digest) == 32

    assert {:ok, %{status: :finalized}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)
  end

  test "reconciler never guesses when a stranded payload fails its digest" do
    enable_exact_reconciliation!()
    agent = running_consented_agent("digest-fail-closed")
    ensure_user_partition!(agent.user_id)

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :stop,
               %{"reason" => "stored_exactly"},
               fn _agent -> %{"action" => "stop"} end
             )

    operation = AgentLifecycleOperations.get(agent.id)

    operation
    |> Ecto.Changeset.change(
      payload: put_in(operation.payload, ["request", "reason"], "tampered")
    )
    |> Repo.update!()

    assert {:ok, %{lifecycle: lifecycle}} =
             WakeCoordinator.reconcile_once(admit_recoveries: false, limit: 10)

    assert Enum.any?(lifecycle, fn
             {agent_id, {:error, :invalid_lifecycle_payload}, :not_started} ->
               agent_id == agent.id

             _other ->
               false
           end)

    assert AgentLifecycleOperations.get(agent.id).operation_token == fence.operation_token
    assert Agents.get_agent(agent.id).status == "stopped"
  end

  test "running updates return the persisted Agent after starting the finalized generation" do
    agent = running_consented_agent("running-update-result")

    assert {:ok, %Maraithon.Agents.Agent{} = updated} =
             Runtime.update_agent(agent.id, %{
               "behavior" => "prompt_agent",
               "config" => %{"revision" => "updated"}
             })

    assert updated.id == agent.id
    assert updated.status == "running"
    assert updated.config["revision"] == "updated"

    assert [{pid, owner_token}] = Registry.lookup(AgentRegistry, agent.id)
    assert :ok = AgentSupervisor.stop_agent(pid, "test_cleanup", owner_token)
  end

  test "the production gate fails closed before creation, claim, or reconciliation" do
    runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Runtime, runtime_config) end)

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(runtime_config, :exact_agent_runtime_enabled, false)
    )

    agent = running_consented_agent("gate-closed")
    before_count = Agents.list_agents() |> length()

    owner_token = Ecto.UUID.generate()
    assert {:error, :exact_runtime_disabled} = AgentLeases.claim(agent.id)
    assert {:error, :exact_runtime_disabled} = AgentLeases.renew(agent.id, owner_token)
    assert {:error, :exact_runtime_disabled} = AgentLeases.mark_ready(agent.id, owner_token)
    refute AgentLeases.ready?(agent.id, owner_token)
    assert {:error, :exact_runtime_disabled} = AgentSupervisor.preflight()
    assert {:error, :exact_runtime_disabled} = AgentSupervisor.start_agent(agent)
    assert {:error, :exact_runtime_disabled} = Runtime.resume_all_agents()

    assert {:stop, :normal, %{retry_attempts: 0, retry_interval_ms: 5_000}} =
             Bootstrap.handle_info(:bootstrap, %{retry_attempts: 0, retry_interval_ms: 5_000})

    assert {:ok, %{gate: :closed, ownership: [], lifecycle: [], recoveries: []}} =
             WakeCoordinator.reconcile_once()

    assert {:error, :exact_runtime_disabled} =
             Runtime.start_agent(%{
               "user_id" => agent.user_id,
               "behavior" => "prompt_agent",
               "binding_consent" => binding_consent(agent)
             })

    assert length(Agents.list_agents()) == before_count
  end

  defp enable_exact_reconciliation! do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      original_runtime
      |> Keyword.put(:multinode_coordination_enabled, true)
      |> Keyword.delete(:coordination_test_session)
      |> Keyword.delete(:coordination_test_leader)
    )

    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Runtime, original_runtime) end)

    assert ProtocolCutover.mode() == :legacy

    assert {:ok, :attested} =
             CoordinationProtocol.attest_effect_activation_evidence(@activation_evidence)

    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    assert {:ok, status} = activate_exact_reconciliation()
    assert status in [:activated, :already_active]
  end

  defp activate_exact_reconciliation do
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
            [confirmation: CoordinationProtocol.activation_confirmation()] ++
              @activation_evidence
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
    runtime = Application.fetch_env!(:maraithon, Maraithon.Runtime)

    unless Keyword.get(runtime, :coordination_test_session) do
      {:ok, joining} =
        Authority.register_node(
          node_name: "agent-lifecycle-operations@test",
          revision: String.duplicate("b", 40),
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

  defp running_consented_agent(label, config \\ %{}) do
    user_id = "lifecycle-#{label}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        install_status: "enabled",
        config: config
      })

    {:ok, _binding} =
      AgentIsolation.grant_binding_consent(agent, binding_consent(agent))

    agent
  end

  defp scheduled_job(agent_id) do
    %ScheduledJob{}
    |> ScheduledJob.changeset(%{
      agent_id: agent_id,
      job_type: "checkpoint",
      fire_at: DateTime.add(DateTime.utc_now(), 60, :second),
      status: "pending"
    })
    |> Repo.insert!()
  end

  defp monitored_owner(agent_id) do
    suffix = System.unique_integer([:positive])
    watcher_name = :"lifecycle_operation_watcher_#{suffix}"

    watcher =
      start_supervised!(
        {AgentWatcher,
         [
           name: watcher_name,
           reconcile?: false,
           recover?: false,
           reresume_backoffs: [0]
         ]},
        id: watcher_name
      )

    {:ok, lease} = AgentLeases.claim(agent_id, watcher: watcher)
    {:ok, _ready} = AgentLeases.mark_ready(agent_id, lease.owner_token)
    owner_pid = registered_owner(agent_id, lease.owner_token)
    assert :ok = AgentWatcher.track(watcher, owner_pid, agent_id, lease.owner_token)
    {lease, watcher, owner_pid}
  end

  defp registered_owner(agent_id, owner_token) do
    parent = self()

    pid =
      spawn(fn ->
        result = Registry.register(AgentRegistry, agent_id, owner_token)
        send(parent, {:owner_registered, self(), result})
        receive do: (:terminate -> :ok)
      end)

    assert_receive {:owner_registered, ^pid, {:ok, _owner}}, 1_000
    pid
  end

  defp prove_owner_down(watcher, owner_pid) do
    ref = Process.monitor(owner_pid)
    send(owner_pid, :terminate)
    assert_receive {:DOWN, ^ref, :process, ^owner_pid, :normal}, 1_000
    await_watcher_release(watcher, owner_pid, 100)
  end

  defp await_watcher_release(_watcher, _owner_pid, 0),
    do: flunk("AgentWatcher did not reconcile the exact DOWN")

  defp await_watcher_release(watcher, owner_pid, attempts) do
    case :sys.get_state(watcher) do
      %{pids: pids, pending_downs: pending} when not is_map_key(pids, owner_pid) ->
        if map_size(pending) == 0,
          do: :ok,
          else: await_watcher_release(watcher, owner_pid, attempts - 1)

      _state ->
        await_watcher_release(watcher, owner_pid, attempts - 1)
    end
  end

  defp seed_preexisting_corrupt_ciphertext!(effect_id) do
    Repo.query!("RESET ROLE", [], log: false)

    try do
      Repo.query!("SET LOCAL session_replication_role = replica", [], log: false)

      Repo.query!(
        """
        UPDATE effects
        SET params_ciphertext = set_byte(
          params_ciphertext,
          octet_length(params_ciphertext) - 1,
          get_byte(params_ciphertext, octet_length(params_ciphertext) - 1) # 1
        )
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(effect_id)]
      )
    after
      Repo.query!("SET LOCAL session_replication_role = origin", [], log: false)
      Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    end
  end

  defp pending_effect(agent_id) do
    %Effect{}
    |> Effect.protocol_changeset(%{
      id: Ecto.UUID.generate(),
      agent_id: agent_id,
      idempotency_key: Ecto.UUID.generate(),
      effect_type: "tool_call",
      params: %{"tool" => "time", "args" => %{}},
      status: "pending"
    })
    |> Repo.insert!()
  end
end
