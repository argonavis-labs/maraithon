defmodule Maraithon.AgentHarness.MarkdownSkillTest do
  use ExUnit.Case, async: true

  alias Maraithon.AgentHarness.Manifest
  alias Maraithon.AgentHarness.MarkdownSkill
  alias Maraithon.AgentHarness.ToolCatalog
  alias Maraithon.Agents.AgentPackageVersion

  test "loads markdown skills from JSON frontmatter" do
    assert {:ok, skill} =
             MarkdownSkill.load_file("priv/agents/skills/chief_of_staff/morning_briefing.md")

    assert skill.id == "morning_briefing"
    assert skill.name == "Morning Briefing"
    assert "llm.complete" in skill.tools
    assert skill.instructions =~ "Do not list raw marketing email"
  end

  test "rejects malformed or incomplete markdown skill files" do
    tmp_dir = Path.join(System.tmp_dir!(), "maraithon-skill-test-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    missing_frontmatter_path = Path.join(tmp_dir, "missing-frontmatter.md")
    File.write!(missing_frontmatter_path, "# No frontmatter")

    missing_id_path = Path.join(tmp_dir, "missing-id.md")

    File.write!(missing_id_path, """
    ---
    {"name":"Incomplete Skill"}
    ---
    Use the model.
    """)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    assert {:error, {:missing_skill_frontmatter, ^missing_frontmatter_path}} =
             MarkdownSkill.load_file(missing_frontmatter_path)

    assert {:error, {:missing_skill_metadata, ^missing_id_path, "id"}} =
             MarkdownSkill.load_file(missing_id_path)
  end

  test "builds an executable manifest and requires model intelligence" do
    version = %AgentPackageVersion{
      id: Ecto.UUID.generate(),
      behavior: "ai_chief_of_staff",
      model: "gpt-5.4",
      intelligence: "high",
      system_prompt: "Act as a Chief of Staff.",
      goals: ["Return a condensed brief"],
      skill_paths: ["priv/agents/skills/chief_of_staff/morning_briefing.md"],
      tool_allowlist: ["llm.complete"]
    }

    assert {:ok, manifest} = Manifest.build(version)
    assert manifest.model == "gpt-5.4"
    assert manifest.intelligence == "high"
    assert [%MarkdownSkill{id: "morning_briefing"}] = manifest.skills
  end

  test "manifest build fails visibly when a referenced markdown skill cannot load" do
    version = %AgentPackageVersion{
      id: Ecto.UUID.generate(),
      behavior: "manifest_agent",
      model: "gpt-5.4",
      intelligence: "high",
      system_prompt: "Use the model.",
      skill_paths: ["priv/agents/skills/missing.md"]
    }

    assert {:error, {:skill_not_found, "priv/agents/skills/missing.md"}} =
             Manifest.build(version)
  end

  test "describes tool side effects and connector MCP bindings" do
    assert [
             %{
               name: "telegram.send",
               connector: "telegram",
               mcp_server: "telegram",
               action: "send_message",
               side_effect: "write"
             },
             %{
               name: "unknown.tool",
               connector: nil,
               mcp_server: nil,
               action: "external",
               side_effect: "unknown"
             }
           ] = ToolCatalog.describe(["telegram.send", "unknown.tool"])
  end
end
