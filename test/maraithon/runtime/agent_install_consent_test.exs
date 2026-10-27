defmodule Maraithon.Runtime.AgentInstallConsentTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentMarketplace
  alias Maraithon.Runtime

  setup do
    assert {:ok, _packages} = AgentMarketplace.sync_builtin_packages()
    :ok
  end

  test "package discovery without consent stays dark even when all config maps default empty" do
    user_id = unique_user("package-dark")

    assert {:ok, agent} = Runtime.install_agent_package(user_id, "codebase_advisor")
    assert agent.install_status == "setup_required"
    assert agent.status == "stopped"
    assert AgentIsolation.get_binding(agent.id) == nil
  end

  test "explicit package consent activates atomically and paused authority requires reconsent" do
    user_id = unique_user("package-consent")
    first_consent = consent(user_id, "first")

    assert {:ok, agent} =
             Runtime.install_agent_package(user_id, "codebase_advisor",
               binding_consent: first_consent
             )

    assert agent.install_status == "enabled"
    assert agent.status == "running"

    active = AgentIsolation.get_binding(agent.id)
    assert active.status == "active"
    assert active.user_id == user_id
    assert active.connector_scope == %{"github" => %{"repositories" => ["selected"]}}
    assert active.tool_policy == %{"allowed_tools" => ["repo.read"]}
    assert active.consent_token != nil

    assert {:ok, paused} =
             eventually_finalize(fn -> Runtime.pause_agent_installation(agent.id) end)

    assert paused.install_status == "paused"
    assert paused.status == "stopped"
    assert AgentIsolation.get_binding(agent.id).status == "paused"

    assert {:error, :binding_consent_required} = Runtime.resume_agent_installation(agent.id)
    assert AgentIsolation.get_binding(agent.id).status == "paused"

    assert {:ok, resumed} =
             Runtime.resume_agent_installation(agent.id, consent(user_id, "reconsent"))

    assert resumed.install_status == "enabled"
    assert resumed.status == "running"

    reconsented = AgentIsolation.get_binding(agent.id)
    assert reconsented.status == "active"
    refute reconsented.consent_token == active.consent_token

    assert {:ok, %{drain_status: :quiesced}} = eventually_stop(agent.id)
  end

  defp eventually_stop(agent_id, attempts \\ 100)

  defp eventually_stop(agent_id, 0), do: Runtime.stop_agent(agent_id)

  defp eventually_stop(agent_id, attempts) do
    case Runtime.stop_agent(agent_id) do
      {:ok, %{drain_status: :reconciliation_pending}} ->
        Process.sleep(20)
        eventually_stop(agent_id, attempts - 1)

      result ->
        result
    end
  end

  defp eventually_finalize(fun, attempts \\ 100)

  defp eventually_finalize(fun, 0), do: fun.()

  defp eventually_finalize(fun, attempts) do
    case fun.() do
      {:error, :agent_drain_pending} ->
        Process.sleep(20)
        eventually_finalize(fun, attempts - 1)

      result ->
        result
    end
  end

  defp unique_user(label) do
    user_id = "#{label}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    user_id
  end

  defp consent(user_id, label) do
    %{
      "actor_id" => user_id,
      "user_id" => user_id,
      "identity_key" => "package:#{label}:#{user_id}",
      "credential_refs" => %{"github" => "connected-account:#{user_id}:github"},
      "connector_scope" => %{"github" => %{"repositories" => ["selected"]}},
      "memory_scope" => %{"workspace" => "default"},
      "tool_policy" => %{"allowed_tools" => ["repo.read"]},
      "routing_bindings" => %{},
      "metadata" => %{"source" => "test_explicit_consent"}
    }
  end
end
