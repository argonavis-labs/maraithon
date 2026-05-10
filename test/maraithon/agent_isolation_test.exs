defmodule Maraithon.AgentIsolationTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.ToolPolicy

  test "binds per-agent policy, routing, and session state" do
    user_id = "isolation-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{prompt: "test"},
        connector_grants: %{"gmail" => %{"account_ids" => ["primary"]}},
        memory_scope: %{"project" => "alpha"}
      })

    assert {:ok, binding} =
             AgentIsolation.upsert_binding(agent, %{
               "tool_policy" => %{
                 "allowed_tools" => ["time"],
                 "denied_tools" => ["gmail_send_message"]
               },
               "routing_bindings" => %{"inbox" => "gmail:primary"},
               "credential_refs" => %{"gmail" => "env:GMAIL_TOKEN"}
             })

    assert binding.identity_key == "agent:#{agent.id}"
    assert AgentIsolation.route_for(agent.id, "inbox") == "gmail:primary"

    denied_context =
      AgentIsolation.policy_context(agent.id, %{
        surface: "mcp",
        tool_name: "gmail_send_message",
        user_id: user_id
      })

    assert %{status: :deny, reason_code: "agent_tool_denied"} =
             ToolPolicy.authorize(denied_context)

    allowed_context =
      AgentIsolation.policy_context(agent.id, %{
        surface: "mcp",
        tool_name: "time",
        user_id: user_id
      })

    assert %{status: :allow} = ToolPolicy.authorize(allowed_context)

    assert {:ok, session} =
             AgentIsolation.put_session(agent, "telegram:123", %{"state" => %{"turns" => 1}})

    assert AgentIsolation.get_session(agent.id, "telegram:123").id == session.id
  end
end
