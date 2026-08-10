defmodule Maraithon.Runtime.AgentLeasesTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRuntimeLease
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

  test "claims one unready generation and fences readiness with current consent", %{
    agent: agent,
    binding: binding
  } do
    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert Ecto.UUID.cast(lease.owner_token) == {:ok, lease.owner_token}
    assert lease.owner_node == Atom.to_string(node())
    assert lease.ready_at == nil
    assert AgentLeases.owner?(agent.id, lease.owner_token)
    refute AgentLeases.ready?(agent.id, lease.owner_token)

    assert {:error, :runtime_lease_owned} =
             AgentLeases.claim(agent.id)

    assert {:ok, ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    assert ready.ready_at != nil
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

    claim = fn ->
      send(parent, {:claim_ready, self()})
      receive do: (:claim_go -> AgentLeases.claim(agent.id))
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
    assert {:error, :runtime_lease_lost} = AgentLeases.release(agent.id, stale_token)
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

    # Expiry revoked even the old token's release authority. The row remains
    # durable evidence until the restart guard records the ownership loss.
    assert {:error, :runtime_lease_expired} = AgentLeases.release(agent.id, lease.owner_token)
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
end
