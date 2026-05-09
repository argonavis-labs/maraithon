defmodule Maraithon.AgentMarketplaceTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.AgentBuilder
  alias Maraithon.AgentMarketplace
  alias Maraithon.Agents
  alias Maraithon.Accounts

  describe "builtin_manifest/1" do
    test "wraps built-in agents in the manifest harness" do
      spec = Enum.find(AgentBuilder.library_specs(), &(&1.id == "ai_chief_of_staff"))

      manifest = AgentMarketplace.builtin_manifest(spec)

      assert manifest["slug"] == "ai_chief_of_staff"
      assert manifest["behavior"] == "manifest_agent"
      assert manifest["source_behavior"] == "ai_chief_of_staff"
      assert manifest["changelog"] == "Initial manifest-backed marketplace package."
      assert manifest["default_config"]["behavior"] == "manifest_agent"
      assert manifest["default_config"]["source_behavior"] == "ai_chief_of_staff"
      assert "priv/agents/skills/chief_of_staff/morning_briefing.md" in manifest["skill_paths"]
      assert "llm.complete" in manifest["tool_allowlist"]
    end

    test "attaches markdown skill packs to non-chief built-in marketplace agents" do
      planner_spec = Enum.find(AgentBuilder.library_specs(), &(&1.id == "github_product_planner"))
      code_spec = Enum.find(AgentBuilder.library_specs(), &(&1.id == "codebase_advisor"))
      repo_spec = AgentBuilder.behavior_spec("repo_planner")

      assert AgentMarketplace.builtin_manifest(planner_spec)["skill_paths"] == [
               "priv/agents/skills/product/github_product_planner.md"
             ]

      assert AgentMarketplace.builtin_manifest(code_spec)["skill_paths"] == [
               "priv/agents/skills/engineering/codebase_advisor.md"
             ]

      assert AgentMarketplace.builtin_manifest(repo_spec)["skill_paths"] == [
               "priv/agents/skills/engineering/repo_planner.md"
             ]
    end
  end

  describe "sync_builtin_packages/0" do
    test "publishes loadable manifest packages for visible library agents" do
      assert {:ok, packages} = AgentMarketplace.sync_builtin_packages()

      slugs = Enum.map(packages, & &1.slug)

      assert "ai_chief_of_staff" in slugs
      assert "github_product_planner" in slugs
      assert "codebase_advisor" in slugs
      assert Enum.all?(packages, &(&1.latest_version.behavior == "manifest_agent"))
      assert Enum.all?(packages, &(&1.latest_version.skill_paths != []))
    end
  end

  describe "ensure_default_installations/1" do
    test "installs the default Chief of Staff package for the target user" do
      user_id = "marketplace-default-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      assert {:ok, [agent]} = AgentMarketplace.ensure_default_installations(user_id: user_id)

      assert agent.user_id == user_id
      assert agent.behavior == "manifest_agent"
      assert agent.status == "running"
      assert agent.install_status == "enabled"
      assert agent.delivery_policy == %{"telegram" => "enabled"}
      assert agent.config["source_behavior"] == "ai_chief_of_staff"
      assert agent.config["marketplace_behavior"] == "manifest_agent"
      assert agent.config["enabled_skills"] != []
      assert get_in(agent.config, ["skill_configs", "morning_briefing", "user_id"]) == user_id

      assert {:ok, [same_agent]} = AgentMarketplace.ensure_default_installations(user_id: user_id)
      assert same_agent.id == agent.id

      assert [%{installation: listed}] =
               Agents.list_marketplace_packages(user_id)
               |> Enum.filter(&(&1.package.slug == "ai_chief_of_staff"))

      assert listed.id == agent.id
    end

    test "syncs marketplace packages without installing when no target user is configured" do
      previous_primary_admin = System.get_env("PRIMARY_ADMIN_EMAIL")
      System.delete_env("PRIMARY_ADMIN_EMAIL")

      on_exit(fn ->
        case previous_primary_admin do
          nil -> System.delete_env("PRIMARY_ADMIN_EMAIL")
          value -> System.put_env("PRIMARY_ADMIN_EMAIL", value)
        end
      end)

      assert {:ok, []} = AgentMarketplace.ensure_default_installations()

      assert Agents.get_agent_package_by_slug("ai_chief_of_staff", preload: [:latest_version])
      refute Enum.any?(Agents.list_agents(include_removed: true), &is_nil(&1.user_id))
    end
  end
end
