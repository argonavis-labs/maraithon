defmodule Maraithon.AgentIsolationTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
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
             AgentIsolation.grant_binding_consent(
               agent,
               binding_consent(agent, %{
                 "tool_policy" => %{
                   "allowed_tools" => ["time"],
                   "denied_tools" => ["gmail_send_message"]
                 },
                 "routing_bindings" => %{"inbox" => "gmail:primary"},
                 "credential_refs" => %{"gmail" => "env:GMAIL_TOKEN"}
               })
             )

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

  test "metadata-only patch preserves active authority fields" do
    agent = isolation_agent("metadata-patch")

    consent =
      binding_consent(agent, %{
        "credential_refs" => %{"gmail" => "vault:gmail"},
        "connector_scope" => %{"gmail" => %{"accounts" => ["primary"]}},
        "memory_scope" => %{"project" => "alpha"},
        "tool_policy" => %{"allowed_tools" => ["time"]},
        "routing_bindings" => %{"inbox" => "gmail:primary"}
      })

    assert {:ok, active} = AgentIsolation.grant_binding_consent(agent, consent)
    assert {:ok, patched} = AgentIsolation.upsert_binding(agent, %{metadata: %{label: "renamed"}})

    assert patched.status == "active"
    assert patched.credential_refs == active.credential_refs
    assert patched.connector_scope == active.connector_scope
    assert patched.memory_scope == active.memory_scope
    assert patched.tool_policy == active.tool_policy
    assert patched.routing_bindings == active.routing_bindings
    assert patched.consent_token == active.consent_token
    assert patched.metadata == %{"label" => "renamed"}

    assert {:error, :binding_consent_required} =
             AgentIsolation.upsert_binding(agent, %{
               connector_scope: %{"gmail" => %{"accounts" => ["primary", "secondary"]}}
             })
  end

  test "paused and revoked bindings cannot be reactivated by an ordinary patch" do
    agent = isolation_agent("reactivation")
    assert {:ok, active} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))

    assert {:ok, paused} = AgentIsolation.upsert_binding(agent, %{status: "paused"})
    assert paused.status == "paused"

    assert {:ok, metadata_only} =
             AgentIsolation.upsert_binding(agent, %{metadata: %{note: "still paused"}})

    assert metadata_only.status == "paused"
    assert metadata_only.consent_token == active.consent_token

    assert {:error, :binding_consent_required} =
             AgentIsolation.upsert_binding(agent, %{status: "active"})

    assert {:ok, revoked} = AgentIsolation.upsert_binding(agent, %{status: "revoked"})
    assert revoked.status == "revoked"

    assert {:error, :binding_consent_required} =
             AgentIsolation.upsert_binding(agent, %{status: "active", metadata: %{unsafe: true}})

    assert {:ok, reconsented} =
             AgentIsolation.grant_binding_consent(
               agent,
               binding_consent(agent, %{metadata: %{source: "explicit_reconsent"}})
             )

    assert reconsented.status == "active"
    refute reconsented.consent_token == active.consent_token
    assert reconsented.consented_at != nil
    assert byte_size(reconsented.consent_digest) == 32

    assert Enum.any?(ActionLedger.list_recent(agent.user_id, limit: 20), fn action ->
             action.agent_id == agent.id and
               action.event_type == "agent_isolation.consent_granted"
           end)
  end

  test "new metadata creation is inactive and mismatched identity cannot activate it" do
    agent = isolation_agent("new-fail-closed")

    assert {:ok, inactive} =
             AgentIsolation.upsert_binding(agent, %{metadata: %{name: "metadata only"}})

    assert inactive.status == "paused"
    assert inactive.consent_token == nil

    assert {:error, :binding_consent_required} =
             AgentIsolation.grant_binding_consent(
               agent,
               binding_consent(agent, %{"actor_id" => "other@example.com"})
             )

    assert AgentIsolation.get_binding(agent.id).status == "paused"
  end

  defp isolation_agent(label) do
    user_id = "isolation-#{label}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "stopped",
        config: %{}
      })

    agent
  end
end
