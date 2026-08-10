defmodule Maraithon.Runtime.AgentLifecycleOperationsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentSubscriptions.AgentSubscription
  alias Maraithon.Agents
  alias Maraithon.Effects.Effect
  alias Maraithon.Repo
  alias Maraithon.Runtime
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.Bootstrap
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.ScheduledJob
  alias Maraithon.Runtime.WakeCoordinator

  test "establishes one immutable marker with the stopped/readiness fence and adopts retries" do
    agent = running_consented_agent("marker-adopt")
    {:ok, lease} = AgentLeases.claim(agent.id)
    {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)

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

    assert {:ok, :released} = AgentLeases.release(agent.id, lease.owner_token)

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

  test "expired lease loss is adopted into the marker and its matching guard is cleared" do
    agent = running_consented_agent("expired-guard")
    {:ok, lease} = AgentLeases.claim(agent.id)
    {:ok, ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)

    ready
    |> Ecto.Changeset.change(lease_until: DateTime.add(ready.ready_at, 1, :microsecond))
    |> Repo.update!()

    assert {:ok, %{drain_status: :quiesced}} = Runtime.stop_agent(agent.id, "expired_owner")
    assert AgentLeases.get(agent.id) == nil
    assert AgentRestartGuards.get(agent.id) == nil
    assert AgentLifecycleOperations.get(agent.id) == nil
    assert Agents.get_agent(agent.id).status == "stopped"
  end

  test "WakeCoordinator finishes a stranded ordinary operation from its stored digest" do
    agent = running_consented_agent("wake-finalize")

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
    agent = running_consented_agent("digest-fail-closed")

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

  defp pending_effect(agent_id) do
    %Effect{}
    |> Effect.changeset(%{
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
