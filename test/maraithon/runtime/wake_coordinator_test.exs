defmodule Maraithon.Runtime.WakeCoordinatorTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.WakeCoordinator

  test "performs bounded guard-first expired ownership reconciliation" do
    {agent, user_id} = running_agent("wake-expired")

    assert {:ok, _directive} =
             AgentDirectives.enqueue(agent.id, user_id, "message", %{}, "expired-owner")

    assert {:ok, lease} = AgentLeases.claim(agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
    assert {:ok, claimed} = AgentDirectives.claim_next(agent.id, user_id, lease.owner_token)
    expire_lease!(agent.id)

    assert {:ok, summary} =
             WakeCoordinator.reconcile_once(
               limit: 1,
               admit_recoveries: false,
               guard_opts: [backoffs_ms: [0]]
             )

    assert [{agent_id, owner_token, {:recorded, guard}, {:ok, recovered}}] = summary.ownership
    assert agent_id == agent.id
    assert owner_token == lease.owner_token
    assert guard.last_owner_token == lease.owner_token
    assert guard.needs_recovery
    assert recovered.id == claimed.id
    assert recovered.status == "pending"
    assert summary.recorded == []
    assert summary.recoveries == []
    assert AgentLeases.get(agent.id) == nil
  end

  test "keeps ordinary directive wake and idle sleep feature-dark" do
    {agent, user_id} = running_agent("wake-dark")

    assert {:ok, directive} =
             AgentDirectives.enqueue(agent.id, user_id, "message", %{"body" => "later"}, "dark")

    assert {:ok, summary} =
             WakeCoordinator.reconcile_once(limit: 10, admit_recoveries: true)

    assert summary.ownership == []
    assert summary.recorded == []
    assert summary.recoveries == []
    assert AgentLeases.get(agent.id) == nil
    assert Repo.get!(AgentDirective, directive.id).status == "pending"
  end

  defp running_agent(name) do
    user_id = "#{name}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        install_status: "enabled",
        status: "running",
        config: %{}
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    {agent, user_id}
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
