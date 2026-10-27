defmodule Maraithon.AgentSubscriptionsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentSubscriptions
  alias Maraithon.Agents

  test "sync_for_agent tracks active topics and deactivates removed topics" do
    user_id = "agent-subscriptions@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        install_status: "enabled",
        config: %{"subscribe" => ["operator:user:#{user_id}", "github:acme/repo"]}
      })

    assert AgentSubscriptions.list_topics_for_agent(agent.id) == []
    assert {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    assert {:ok, subscriptions} = AgentSubscriptions.sync_for_agent(agent)

    assert Enum.map(subscriptions, &{&1.topic, &1.status}) == [
             {"github:acme/repo", "active"},
             {"operator:user:#{user_id}", "active"}
           ]

    {:ok, updated_agent} =
      Agents.update_agent(agent, %{
        config: %{"subscribe" => ["github:acme/repo", "operator:project:roadmap"]}
      })

    assert {:ok, updated_subscriptions} = AgentSubscriptions.sync_for_agent(updated_agent)

    assert AgentSubscriptions.list_topics_for_agent(updated_agent.id) == [
             "github:acme/repo",
             "operator:project:roadmap"
           ]

    assert Enum.map(updated_subscriptions, &{&1.topic, &1.status}) == [
             {"github:acme/repo", "active"},
             {"operator:project:roadmap", "active"},
             {"operator:user:#{user_id}", "inactive"}
           ]
  end

  test "stopped and setup-required agents retain subscription config without active delivery" do
    user_id = "agent-subscriptions-dark@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "stopped",
        install_status: "setup_required",
        config: %{"subscribe" => ["operator:user:#{user_id}"]}
      })

    assert AgentSubscriptions.list_topics_for_agent(agent.id) == []
    assert {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    assert {:ok, []} = AgentSubscriptions.sync_for_agent(agent)
    assert AgentSubscriptions.list_topics_for_agent(agent.id) == []
  end

  test "a failed start intent atomically fences active delivery" do
    user_id = "agent-subscriptions-start-failure@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        install_status: "enabled",
        config: %{"subscribe" => ["operator:user:#{user_id}"]}
      })

    assert {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    assert AgentSubscriptions.list_topics_for_agent(agent.id) == ["operator:user:#{user_id}"]

    assert {:ok, stopped} = Agents.fail_agent_start_intent(agent.id)
    assert stopped.status == "stopped"
    assert AgentSubscriptions.list_topics_for_agent(agent.id) == []
  end
end
