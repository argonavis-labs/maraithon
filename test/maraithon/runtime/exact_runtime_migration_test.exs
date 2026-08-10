Code.require_file(
  Path.expand(
    "../../../priv/repo/migrations/20260809100003_prepare_exact_agent_runtime.exs",
    __DIR__
  )
)

defmodule Maraithon.Runtime.ExactRuntimeMigrationTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents
  alias Maraithon.Repo
  alias Maraithon.Repo.Migrations.PrepareExactAgentRuntime

  test "retains only explicitly proven same-user active consent" do
    owner_id = unique_user("owner")
    other_id = unique_user("other")

    proven = agent(owner_id, "proven", "recovering")

    {:ok, proven_binding} =
      AgentIsolation.grant_binding_consent(
        proven,
        binding_consent(proven, %{metadata: %{proof: "explicit"}})
      )

    missing = agent(owner_id, "missing", "recovering")

    paused = agent(owner_id, "paused", "running")
    {:ok, paused_binding} = AgentIsolation.upsert_binding(paused, %{status: "paused"})

    revoked = agent(owner_id, "revoked", "degraded")
    {:ok, revoked_binding} = AgentIsolation.upsert_binding(revoked, %{status: "revoked"})

    mismatched = agent(owner_id, "mismatched", "running")
    mismatched_binding = insert_mismatched_binding(mismatched, other_id)

    paused_install = agent(owner_id, "paused-install", "running", "paused")

    {:ok, paused_install_binding} =
      AgentIsolation.grant_binding_consent(paused_install, binding_consent(paused_install))

    Repo.query!(PrepareExactAgentRuntime.normalize_proven_recovery_sql())
    Repo.query!(PrepareExactAgentRuntime.quarantine_unproven_runtime_sql())

    assert Agents.get_agent(proven.id, include_removed: true).status == "running"
    assert AgentIsolation.get_binding(proven.id).id == proven_binding.id
    assert AgentIsolation.get_binding(proven.id).status == "active"
    assert AgentIsolation.get_binding(proven.id).metadata == %{"proof" => "explicit"}

    missing_after = Agents.get_agent(missing.id, include_removed: true)
    assert missing_after.status == "stopped"
    assert missing_after.stopped_at != nil
    assert AgentIsolation.get_binding(missing.id) == nil

    assert Agents.get_agent(paused.id, include_removed: true).status == "stopped"
    assert AgentIsolation.get_binding(paused.id).id == paused_binding.id
    assert AgentIsolation.get_binding(paused.id).status == "paused"

    assert Agents.get_agent(revoked.id, include_removed: true).status == "stopped"
    assert AgentIsolation.get_binding(revoked.id).id == revoked_binding.id
    assert AgentIsolation.get_binding(revoked.id).status == "revoked"

    assert Agents.get_agent(mismatched.id, include_removed: true).status == "stopped"
    assert AgentIsolation.get_binding(mismatched.id).id == mismatched_binding.id
    assert AgentIsolation.get_binding(mismatched.id).user_id == other_id

    assert Agents.get_agent(paused_install.id, include_removed: true).status == "stopped"
    assert AgentIsolation.get_binding(paused_install.id).id == paused_install_binding.id
    assert AgentIsolation.get_binding(paused_install.id).status == "active"

    Enum.each([proven, missing, paused, revoked, mismatched, paused_install], fn original ->
      assert Agents.get_agent(original.id, include_removed: true).connector_grants ==
               original.connector_grants
    end)
  end

  defp unique_user(label) do
    user_id = "migration-#{label}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    user_id
  end

  defp agent(user_id, label, status, install_status \\ "enabled") do
    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: status,
        install_status: install_status,
        connector_grants: %{"proof_marker" => label},
        config: %{"name" => label}
      })

    agent
  end

  defp insert_mismatched_binding(agent, other_user_id) do
    %Binding{}
    |> Binding.changeset(%{
      agent_id: agent.id,
      user_id: other_user_id,
      identity_key: "mismatch:#{agent.id}",
      status: "active",
      connector_scope: %{"persisted" => true},
      metadata: %{"proof" => "wrong-user"},
      consent_token: Ecto.UUID.generate(),
      consent_actor_id: other_user_id,
      consented_at: DateTime.utc_now(),
      consent_digest: :crypto.hash(:sha256, "wrong-user-test-proof")
    })
    |> Repo.insert!()
  end
end
