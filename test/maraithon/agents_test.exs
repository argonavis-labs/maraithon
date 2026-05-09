defmodule Maraithon.AgentsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Accounts
  alias Maraithon.Projects
  alias Maraithon.Repo

  @valid_attrs %{behavior: "prompt_agent", config: %{prompt: "test"}}

  setup do
    Repo.delete_all(Agent)
    :ok
  end

  describe "list_agents/0" do
    test "returns empty list when no agents" do
      assert Agents.list_agents() == []
    end

    test "returns all agents" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)
      agents = Agents.list_agents()

      assert length(agents) == 1
      assert hd(agents).id == agent.id
    end

    test "filters agents by project" do
      user_id = "agents-projects@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      {:ok, project} = Projects.create_project(user_id, %{"name" => "Maraithon Product"})

      {:ok, attached} =
        Agents.create_agent(Map.merge(@valid_attrs, %{user_id: user_id, project_id: project.id}))

      {:ok, _global} = Agents.create_agent(Map.merge(@valid_attrs, %{user_id: user_id}))

      assert [%Agent{id: id}] = Agents.list_agents(user_id: user_id, project_id: project.id)
      assert id == attached.id
    end
  end

  describe "get_agent/1" do
    test "returns agent when exists" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)

      assert Agents.get_agent(agent.id).id == agent.id
    end

    test "returns nil when agent does not exist" do
      assert Agents.get_agent(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_agent!/1" do
    test "returns agent when exists" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)

      assert Agents.get_agent!(agent.id).id == agent.id
    end

    test "raises when agent does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Agents.get_agent!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_agent/1" do
    test "creates agent with valid attrs" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)

      assert agent.behavior == "prompt_agent"
      assert agent.config == %{prompt: "test"}
      assert agent.status == "stopped"
    end

    test "returns error with invalid behavior" do
      {:error, changeset} = Agents.create_agent(%{behavior: "nonexistent_behavior"})

      assert %{behavior: ["unknown behavior: nonexistent_behavior"]} = errors_on(changeset)
    end

    test "returns error when behavior is missing" do
      {:error, changeset} = Agents.create_agent(%{})

      assert %{behavior: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "update_agent/2" do
    test "updates agent with valid attrs" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)
      {:ok, updated} = Agents.update_agent(agent, %{status: "running"})

      assert updated.status == "running"
    end

    test "returns error with invalid status" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)
      {:error, changeset} = Agents.update_agent(agent, %{status: "invalid"})

      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "delete_agent/1" do
    test "deletes agent" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)
      {:ok, _} = Agents.delete_agent(agent)

      assert Agents.get_agent(agent.id) == nil
    end
  end

  describe "marketplace packages" do
    test "syncs a package manifest, installs it for a user, and soft-removes it" do
      slug = "test-agent-#{System.unique_integer([:positive])}"
      user_id = "marketplace@example.com"

      manifest = %{
        "slug" => slug,
        "name" => "Test Marketplace Agent",
        "summary" => "A package-backed test agent",
        "category" => "Test",
        "version" => "1.0.0",
        "changelog" => "Adds a package-backed install path.",
        "behavior" => "prompt_agent",
        "model" => "mock-v1",
        "intelligence" => "high",
        "default_config" => %{
          "behavior" => "prompt_agent",
          "prompt" => "Use the model for every semantic decision.",
          "memory_limit" => "10",
          "subscriptions" => "",
          "tools" => "llm.complete",
          "budget_llm_calls" => "10",
          "budget_tool_calls" => "20"
        }
      }

      assert {:ok, package} = Agents.sync_agent_package_manifest(manifest)
      assert package.latest_version.model == "mock-v1"
      assert package.latest_version.changelog == "Adds a package-backed install path."

      assert {:ok, agent} = Agents.install_agent_package(user_id, slug)
      assert agent.user_id == user_id
      assert agent.agent_package_id == package.id
      assert agent.agent_package_version_id == package.latest_version.id
      assert agent.config["prompt"] == "Use the model for every semantic decision."

      assert [%Agent{id: installed_id}] = Agents.list_agents(user_id: user_id)
      assert installed_id == agent.id

      assert {:ok, removed} = Agents.remove_agent_installation(agent)
      assert removed.install_status == "removed"
      assert Agents.list_agents(user_id: user_id) == []

      assert [%Agent{id: ^installed_id}] =
               Agents.list_agents(user_id: user_id, include_removed: true)
    end

    test "accepts manifest-driven packages without behavior-specific modules" do
      slug = "manifest-agent-#{System.unique_integer([:positive])}"

      manifest = %{
        "slug" => slug,
        "name" => "Manifest Agent",
        "version" => "1.0.0",
        "behavior" => "manifest_agent",
        "system_prompt" => "Use the package manifest.",
        "model" => "gpt-5.4",
        "intelligence" => "high",
        "goals" => ["Respond from the dynamic package"],
        "skill_paths" => ["priv/agents/skills/chief_of_staff/morning_briefing.md"],
        "tool_allowlist" => ["llm.complete"],
        "mcp_allowlist" => ["google"]
      }

      assert {:ok, package} = Agents.sync_agent_package_manifest(manifest)
      assert package.latest_version.behavior == "manifest_agent"

      assert package.latest_version.skill_paths == [
               "priv/agents/skills/chief_of_staff/morning_briefing.md"
             ]

      assert {:ok, agent} = Agents.install_agent_package("manifest@example.com", slug)
      assert agent.behavior == "manifest_agent"
      assert agent.config["agent_package_version_id"] == package.latest_version.id
    end

    test "accepts atom-keyed package manifests" do
      slug = "atom-manifest-agent-#{System.unique_integer([:positive])}"

      manifest = %{
        slug: slug,
        name: "Atom Manifest Agent",
        version: "1.0.0",
        behavior: "manifest_agent",
        system_prompt: "Use normalized manifest keys.",
        model: "gpt-5.4",
        intelligence: "high",
        goals: ["Run from a normalized manifest"],
        skill_paths: ["priv/agents/skills/chief_of_staff/morning_briefing.md"],
        tool_allowlist: ["llm.complete"]
      }

      assert {:ok, package} = Agents.sync_agent_package_manifest(manifest)
      assert package.slug == slug
      assert package.latest_version.model == "gpt-5.4"
      assert package.latest_version.goals == ["Run from a normalized manifest"]
    end

    test "returns structured errors for invalid package manifests" do
      assert {:error, {:invalid_agent_manifest, errors}} =
               Agents.sync_agent_package_manifest(%{
                 "name" => "Broken Agent",
                 "behavior" => "manifest_agent",
                 "model" => "   "
               })

      assert {:slug, "is required"} in errors
      assert {:model, "is required"} in errors
      assert {:intelligence, "is required"} in errors
      assert {:skill_paths, "must include at least one Markdown skill path"} in errors

      assert {:error, {:invalid_agent_manifest, skill_errors}} =
               Agents.sync_agent_package_manifest(%{
                 "slug" => "broken-skill-#{System.unique_integer([:positive])}",
                 "name" => "Broken Skill Agent",
                 "behavior" => "manifest_agent",
                 "model" => "gpt-5.4",
                 "intelligence" => "high",
                 "skill_paths" => ["priv/agents/skills/missing.md"]
               })

      assert [
               skill_paths:
                 "could not load Markdown skills: {:skill_not_found, \"priv/agents/skills/missing.md\"}"
             ] = skill_errors

      assert {:error, {:invalid_agent_manifest, [manifest: "must be a map"]}} =
               Agents.sync_agent_package_manifest(nil)
    end

    test "pauses, resumes, and upgrades installed package agents" do
      slug = "upgrade-agent-#{System.unique_integer([:positive])}"

      assert {:ok, package} =
               Agents.sync_agent_package_manifest(%{
                 "slug" => slug,
                 "name" => "Upgradeable Agent",
                 "version" => "1.0.0",
                 "behavior" => "manifest_agent",
                 "system_prompt" => "First version.",
                 "model" => "gpt-5.4",
                 "intelligence" => "high",
                 "skill_paths" => ["priv/agents/skills/chief_of_staff/morning_briefing.md"]
               })

      assert {:ok, agent} = Agents.install_agent_package("upgrade@example.com", slug)
      assert {:ok, paused} = Agents.pause_agent_installation(agent)
      assert paused.install_status == "paused"
      assert paused.status == "stopped"

      assert {:ok, resumed} = Agents.resume_agent_installation(paused)
      assert resumed.install_status == "enabled"

      assert {:ok, version_2} =
               Agents.create_agent_package_version(%{
                 agent_package_id: package.id,
                 version: "2.0.0",
                 behavior: "manifest_agent",
                 system_prompt: "Second version.",
                 model: "gpt-5.4",
                 intelligence: "high",
                 skill_paths: ["priv/agents/skills/chief_of_staff/morning_briefing.md"],
                 published_at: DateTime.utc_now()
               })

      assert {:ok, upgraded} = Agents.upgrade_agent_installation(resumed, version_2)
      assert upgraded.agent_package_version_id == version_2.id
      assert upgraded.config["agent_package_version_id"] == version_2.id
    end

    test "publishes and deprecates packages and package versions" do
      slug = "admin-agent-#{System.unique_integer([:positive])}"

      assert {:ok, package} =
               Agents.sync_agent_package_manifest(%{
                 "slug" => slug,
                 "name" => "Admin Agent",
                 "version" => "1.0.0",
                 "behavior" => "manifest_agent",
                 "system_prompt" => "Use the manifest.",
                 "model" => "gpt-5.4",
                 "intelligence" => "high",
                 "skill_paths" => ["priv/agents/skills/chief_of_staff/morning_briefing.md"],
                 "version_status" => "draft"
               })

      version = package.latest_version
      assert version.status == "draft"

      assert {:ok, deprecated_package} = Agents.deprecate_agent_package(package)
      assert deprecated_package.status == "deprecated"

      assert {:ok, published_package} = Agents.publish_agent_package(deprecated_package)
      assert published_package.status == "published"

      assert {:ok, published_version} = Agents.publish_agent_package_version(version)
      assert published_version.status == "published"
      assert published_version.published_at

      reloaded_package = Agents.get_agent_package_by_slug(slug, preload: [:latest_version])
      assert reloaded_package.latest_version_id == published_version.id

      assert {:ok, deprecated_version} = Agents.deprecate_agent_package_version(published_version)
      assert deprecated_version.status == "deprecated"
    end
  end

  describe "agent runs" do
    test "records run and step observability" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)

      assert {:ok, %AgentRun{} = run} =
               Agents.start_agent_run(agent, %{
                 trigger_type: "message",
                 trigger: %{"type" => "message"},
                 resolved_model: "gpt-5.4",
                 intelligence: "high",
                 generation_mode: "llm"
               })

      assert {:ok, step} =
               Agents.record_agent_run_step(run.id, agent.id, %{
                 step_type: "llm_call",
                 status: "requested",
                 resolved_model: "gpt-5.4",
                 intelligence: "high",
                 generation_mode: "llm"
               })

      assert {:ok, completed_step} =
               Agents.update_agent_run_step(step.id, %{
                 status: "completed",
                 finish_reason: "stop"
               })

      assert completed_step.completed_at

      assert {:ok, completed_run} =
               Agents.complete_agent_run(run.id, %{
                 finish_reason: "stop",
                 generation_mode: "llm"
               })

      assert completed_run.status == "completed"
      assert completed_run.completed_at
      assert [listed] = Agents.list_agent_runs(agent.id, preload: [:steps])
      assert listed.id == run.id
      assert [%{id: step_id}] = listed.steps
      assert step_id == step.id
    end
  end

  describe "count_by_status/1" do
    test "counts agents by status" do
      Agents.create_agent(Map.put(@valid_attrs, :status, "running"))
      Agents.create_agent(Map.put(@valid_attrs, :status, "running"))
      Agents.create_agent(Map.put(@valid_attrs, :status, "stopped"))

      assert Agents.count_by_status("running") == 2
      assert Agents.count_by_status("stopped") == 1
      assert Agents.count_by_status("degraded") == 0
    end
  end

  describe "list_resumable_agents/0" do
    test "returns agents with running or degraded status" do
      {:ok, running} = Agents.create_agent(Map.put(@valid_attrs, :status, "running"))
      {:ok, degraded} = Agents.create_agent(Map.put(@valid_attrs, :status, "degraded"))
      Agents.create_agent(Map.put(@valid_attrs, :status, "stopped"))

      resumable = Agents.list_resumable_agents()
      ids = Enum.map(resumable, & &1.id)

      assert length(resumable) == 2
      assert running.id in ids
      assert degraded.id in ids
    end
  end

  describe "mark_running/1" do
    test "updates status to running and sets started_at" do
      {:ok, agent} = Agents.create_agent(@valid_attrs)
      {:ok, running} = Agents.mark_running(agent)

      assert running.status == "running"
      assert running.started_at != nil
    end
  end

  describe "mark_stopped/1" do
    test "updates status to stopped and sets stopped_at" do
      {:ok, agent} = Agents.create_agent(Map.put(@valid_attrs, :status, "running"))
      {:ok, stopped} = Agents.mark_stopped(agent)

      assert stopped.status == "stopped"
      assert stopped.stopped_at != nil
    end
  end

  describe "mark_degraded/1" do
    test "updates status to degraded" do
      {:ok, agent} = Agents.create_agent(Map.put(@valid_attrs, :status, "running"))
      {:ok, degraded} = Agents.mark_degraded(agent)

      assert degraded.status == "degraded"
    end
  end
end
