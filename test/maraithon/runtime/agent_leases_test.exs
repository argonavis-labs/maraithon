defmodule Maraithon.Runtime.AgentLeasesTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.DatabaseClock

  setup do
    user_id = "lease-#{System.unique_integer([:positive])}@example.com"
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
    %{agent: agent, binding: binding}
  end

  test "watcherless claim is external-proof-only and still fences readiness", %{
    agent: agent,
    binding: binding
  } do
    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert Ecto.UUID.cast(lease.owner_token) == {:ok, lease.owner_token}
    assert lease.owner_node == Atom.to_string(node())
    assert lease.ready_at == nil
    assert lease.termination_capability_digest == nil
    refute Map.has_key?(lease, :termination_capability)

    persisted = AgentLeases.get(agent.id)
    assert persisted.termination_capability_digest == nil
    refute inspect(lease) =~ "termination_capability:"
    assert AgentLeases.owner?(agent.id, lease.owner_token)
    refute AgentLeases.ready?(agent.id, lease.owner_token)

    assert {:error, :runtime_lease_owned} =
             AgentLeases.claim(agent.id)

    assert {:ok, ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    assert ready.ready_at != nil
    refute Map.has_key?(ready, :termination_capability)
    assert AgentLeases.ready?(agent.id, lease.owner_token)

    binding |> Ecto.Changeset.change(status: "revoked") |> Repo.update!()
    refute AgentLeases.ready?(agent.id, lease.owner_token)
    assert AgentLeases.owner?(agent.id, lease.owner_token)

    assert {:ok, renewed} = AgentLeases.renew(agent.id, lease.owner_token)
    assert renewed.ready_at == nil
    assert renewed.draining_at != nil
    refute AgentLeases.ready?(agent.id, lease.owner_token)
  end

  test "concurrent claimers serialize to one exact generation", %{agent: agent} do
    parent = self()
    watcher_name = :"lease_claim_watcher_#{System.unique_integer([:positive])}"

    watcher =
      start_supervised!(
        {AgentWatcher, name: watcher_name, reconcile?: false, recover?: false},
        id: watcher_name
      )

    claim = fn ->
      send(parent, {:claim_ready, self()})
      receive do: (:claim_go -> AgentLeases.claim(agent.id, watcher: watcher))
    end

    first = Task.async(claim)
    second = Task.async(claim)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), first.pid)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), second.pid)

    assert_receive {:claim_ready, first_pid}
    assert_receive {:claim_ready, second_pid}
    send(first_pid, :claim_go)
    send(second_pid, :claim_go)

    results = [Task.await(first), Task.await(second)]
    assert Enum.count(results, &match?({:ok, %AgentRuntimeLease{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :runtime_lease_owned})) == 1

    {:ok, _lease} = Enum.find(results, &match?({:ok, %AgentRuntimeLease{}}, &1))

    assert_eventually(fn ->
      state = :sys.get_state(watcher)

      state.preparations == %{} and state.preparation_controller_refs == %{} and
        state.preparation_counts == %{} and
        :ets.info(state.prepared_lease_capabilities, :size) == 0
    end)
  end

  test "claim accepts capability digests only from a real AgentWatcher", %{agent: agent} do
    chosen_digest = :crypto.hash(:sha256, :crypto.strong_rand_bytes(32))
    test_pid = self()
    fake_watcher = spawn(fn -> fake_watcher_loop(chosen_digest, test_pid) end)
    on_exit(fn -> if Process.alive?(fake_watcher), do: Process.exit(fake_watcher, :kill) end)

    assert {:error, :watcher_unavailable} =
             AgentLeases.claim(agent.id, watcher: fake_watcher)

    assert_receive {:fake_watcher_discarded, ^fake_watcher}, 1_000
    assert AgentLeases.get(agent.id) == nil
  end

  test "a cross-user Binding never grants runtime authority", %{agent: agent, binding: binding} do
    other_user = "other-lease-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(other_user)
    binding |> Ecto.Changeset.change(user_id: other_user) |> Repo.update!()

    assert {:error, :agent_binding_not_active} = AgentLeases.claim(agent.id)
  end

  test "stale tokens cannot renew, drain, ready, or release a live owner", %{agent: agent} do
    assert {:ok, lease} = AgentLeases.claim(agent.id)
    stale_token = Ecto.UUID.generate()

    assert {:error, :runtime_lease_lost} = AgentLeases.renew(agent.id, stale_token)
    assert {:error, :runtime_lease_lost} = AgentLeases.mark_ready(agent.id, stale_token)
    assert {:error, :runtime_lease_lost} = AgentLeases.begin_draining(agent.id, stale_token)

    assert {:error, :termination_proof_required} =
             AgentLeases.release(agent.id, stale_token)

    assert AgentLeases.owner?(agent.id, lease.owner_token)
  end

  test "an expired lease cannot be renewed or stolen before guard reconciliation", %{
    agent: agent
  } do
    assert {:ok, lease} = AgentLeases.claim(agent.id)
    expire_lease!(agent.id)

    refute AgentLeases.owner?(agent.id, lease.owner_token)
    assert {:error, :runtime_lease_expired} = AgentLeases.renew(agent.id, lease.owner_token)

    assert {:error, :expired_lease_requires_reconciliation} =
             AgentLeases.claim(agent.id)

    # Expiry revokes release authority but is not physical-termination proof.
    # The row remains durable evidence until an exact proof path reconciles it.
    assert {:error, :termination_proof_required} =
             AgentLeases.release(agent.id, lease.owner_token)

    assert Repo.get!(AgentRuntimeLease, agent.id).owner_token == lease.owner_token
  end

  test "owner and ready fences use database time", %{agent: agent} do
    assert {:ok, lease} = AgentLeases.claim(agent.id, ttl_ms: 10_000)
    now = DatabaseClock.now!()

    assert DateTime.compare(lease.claimed_at, now) in [:lt, :eq]
    assert DateTime.compare(lease.lease_until, now) == :gt

    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)

    assert_raise ArgumentError, ~r/require.*transaction/, fn ->
      AgentLeases.fence_ready!(agent.id, lease.owner_token)
    end

    assert {:ok, :ok} =
             Repo.transaction(fn -> AgentLeases.fence_ready!(agent.id, lease.owner_token) end)

    expire_lease!(agent.id)

    assert {:error, :runtime_lease_expired} =
             Repo.transaction(fn -> AgentLeases.fence_owner!(agent.id, lease.owner_token) end)
  end

  test "claim rejects malformed identity, node, ttl, non-runnable state, and missing binding", %{
    agent: agent,
    binding: binding
  } do
    assert {:error, :invalid_runtime_lease} = AgentLeases.claim("not-a-uuid")
    assert {:error, :invalid_runtime_lease} = AgentLeases.claim(agent.id, owner_node: "bad node")
    assert {:error, :invalid_runtime_lease} = AgentLeases.claim(agent.id, ttl_ms: 0)
    assert {:error, :invalid_runtime_lease} = AgentLeases.claim(agent.id, unknown: true)

    binding |> Ecto.Changeset.change(status: "paused") |> Repo.update!()
    assert {:error, :agent_binding_not_active} = AgentLeases.claim(agent.id)

    binding |> Repo.reload!() |> Ecto.Changeset.change(status: "active") |> Repo.update!()
    {:ok, stopped} = Agents.update_agent(agent, %{status: "stopped"})
    assert {:error, :agent_not_runnable} = AgentLeases.claim(stopped.id)

    Repo.delete!(Repo.get_by!(Binding, agent_id: agent.id))
    assert {:error, :agent_binding_not_active} = AgentLeases.claim(stopped.id)
  end

  defp fake_watcher_loop(chosen_digest, test_pid) do
    receive do
      {:"$gen_call", from, {:prepare_lease_capability, _agent_id, _owner_token}} ->
        GenServer.reply(
          from,
          {:ok, chosen_digest, make_ref(), fn _supplied -> :ok end}
        )

        fake_watcher_loop(chosen_digest, test_pid)

      {:"$gen_call", from, {:discard_lease_capability, _agent_id, _owner_token}} ->
        GenServer.reply(from, :ok)
        send(test_pid, {:fake_watcher_discarded, self()})
        fake_watcher_loop(chosen_digest, test_pid)
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      receive do
      after
        5 -> assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met before timeout")

  defp expire_lease!(agent_id) do
    # Runtime intentionally cannot rewrite immutable claim time. The reviewed
    # migrator role may repair lease chronology only while the protocol is dark,
    # which is the exact fixture boundary this database-time test needs.
    Repo.query!("SET LOCAL ROLE maraithon_migrator", [], log: false)

    try do
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
      Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    end
  end
end
