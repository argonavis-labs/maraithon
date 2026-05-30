defmodule Maraithon.AgentArchitectureTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.AgentArchitecture
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent

  describe "list/1" do
    test "returns manifests for builder-visible agent behaviors" do
      manifests = AgentArchitecture.list()

      assert Enum.any?(manifests, &(&1.id == "prompt_agent"))
      assert Enum.any?(manifests, &(&1.id == "ai_chief_of_staff"))

      prompt_manifest = Enum.find(manifests, &(&1.id == "prompt_agent"))
      assert prompt_manifest.runtime.process_module == "Maraithon.Runtime.Agent"
      assert prompt_manifest.contract.behaviour == "Maraithon.Behaviors.Behavior"
      assert "init" in prompt_manifest.contract.callbacks
    end
  end

  describe "get/2" do
    test "includes behavior, runtime, memory, tool, and subscription components" do
      assert {:ok, manifest} =
               AgentArchitecture.get("prompt_agent",
                 config: %{
                   "tools" => ["read_file", "search_files", "missing_tool"],
                   "subscribe" => ["github:acme/repo"]
                 }
               )

      assert manifest.behavior_module == "Maraithon.Behaviors.PromptAgent"
      assert "read_file" in manifest.capabilities.tools
      assert "search_files" in manifest.capabilities.tools
      assert "missing_tool" in manifest.capabilities.tools
      assert "github:acme/repo" in manifest.capabilities.subscriptions

      assert Enum.any?(manifest.components, &(&1.kind == :runtime))
      assert Enum.any?(manifest.components, &(&1.kind == :behavior and &1.id == "prompt_agent"))
      assert Enum.any?(manifest.components, &(&1.kind == :memory and &1.id == "user_memory"))
      assert Enum.any?(manifest.components, &(&1.kind == :tool and &1.id == "read_file"))

      assert Enum.any?(
               manifest.components,
               &(&1.kind == :runtime and &1.label == "Maraithon Automation Service")
             )

      metrics = AgentArchitecture.metrics(manifest)
      assert %{label: "Actions", value: "3"} in metrics
      refute Enum.any?(metrics, &(&1.label == "Tools"))

      read_file = Enum.find(manifest.components, &(&1.kind == :tool and &1.id == "read_file"))
      assert read_file.label == "Read File"

      assert AgentArchitecture.component_detail(read_file) ==
               "Configured action available in Maraithon."

      assert Enum.any?(
               manifest.components,
               &(&1.kind == :tool and &1.id == "missing_tool" and not &1.available?)
             )
    end

    test "expands AI Chief of Staff internal skills" do
      assert {:ok, manifest} =
               AgentArchitecture.get("ai_chief_of_staff",
                 config: %{
                   "user_id" => "operator@example.com",
                   "enabled_skills" => ["followthrough", "travel_logistics"]
                 }
               )

      assert "followthrough" in manifest.capabilities.skills
      assert "travel_logistics" in manifest.capabilities.skills
      assert "briefing" in manifest.capabilities.skills

      followthrough =
        Enum.find(manifest.components, &(&1.kind == :skill and &1.id == "followthrough"))

      briefing = Enum.find(manifest.components, &(&1.kind == :skill and &1.id == "briefing"))

      assert followthrough.module == "Maraithon.ChiefOfStaff.Skills.Followthrough"
      assert followthrough.label == "Follow-through"

      assert followthrough.description ==
               "Finds commitments, unanswered threads, and replies that need action."

      assert followthrough.enabled_by_default?
      refute briefing.enabled_by_default?
    end

    test "returns an error for unknown behaviors" do
      assert {:error, :unknown_behavior} = AgentArchitecture.get("not_real")
    end
  end

  describe "for_agent/1" do
    test "includes persisted agent and project binding" do
      agent = %Agent{
        id: Ecto.UUID.generate(),
        user_id: "operator@example.com",
        behavior: "prompt_agent",
        status: "running",
        project_id: Ecto.UUID.generate(),
        config: %{
          "tools" => ["read_file"],
          "subscribe" => ["notaui:tasks"]
        }
      }

      assert {:ok, manifest} = AgentArchitecture.for_agent(agent)

      assert manifest.binding.agent_id == agent.id
      assert manifest.binding.user_id == agent.user_id
      assert manifest.binding.status == "running"
      assert manifest.binding.project_id == agent.project_id

      assert Enum.any?(
               manifest.components,
               &(&1.kind == :scope and &1.id == "project:#{agent.project_id}")
             )
    end

    test "includes manifest envelope for package-backed agents" do
      slug = "architecture-package-#{System.unique_integer([:positive])}"

      assert {:ok, package} =
               Agents.sync_agent_package_manifest(%{
                 "slug" => slug,
                 "name" => "Architecture Package",
                 "summary" => "Inspected from package metadata",
                 "category" => "Operations",
                 "version" => "1.0.0",
                 "behavior" => "manifest_agent",
                 "system_prompt" => "Operate from the manifest.",
                 "model" => "gpt-5.4",
                 "intelligence" => "high",
                 "goals" => ["Explain the package architecture"],
                 "skill_paths" => ["priv/agents/skills/chief_of_staff/morning_briefing.md"],
                 "required_connectors" => %{"google" => %{"gmail" => true}},
                 "tool_allowlist" => ["llm.complete", "gmail.search"],
                 "mcp_allowlist" => ["google"]
               })

      agent = %Agent{
        id: Ecto.UUID.generate(),
        user_id: "operator@example.com",
        behavior: "manifest_agent",
        status: "running",
        agent_package_id: package.id,
        agent_package_version_id: package.latest_version.id,
        config: %{"agent_package_version_id" => package.latest_version.id}
      }

      assert {:ok, architecture} = AgentArchitecture.for_agent(agent)

      assert architecture.id == slug
      assert architecture.manifest.model == "gpt-5.4"
      assert architecture.manifest.intelligence == "high"
      assert [%{id: "morning_briefing"}] = architecture.manifest.skills
      assert "llm.complete" in architecture.capabilities.tools
      assert "gmail.search" in architecture.capabilities.tools

      assert Enum.any?(
               architecture.components,
               &(&1.kind == :connector and &1.id == "google")
             )
    end
  end
end
