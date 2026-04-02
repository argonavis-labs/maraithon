defmodule Maraithon.AgentSubscriptionsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentSubscriptions
  alias Maraithon.Agents

  test "sync_for_agent tracks active topics and deactivates removed topics" do
    user_id = "agent-subscriptions@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{"subscribe" => ["operator:user:#{user_id}", "github:acme/repo"]}
      })

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
end
