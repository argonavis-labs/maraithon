defmodule Maraithon.AgentHarness.MarkdownSkillTest do
  use ExUnit.Case, async: false

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
    refute skill.instructions =~ "kent.fenwick"
    assert skill.instructions =~ "personal or family calendar accounts"
  end

  test "follow-through skill demands executive-grade action output" do
    assert {:ok, skill} =
             MarkdownSkill.load_file("priv/agents/skills/chief_of_staff/followthrough.md")

    assert skill.id == "followthrough"
    assert skill.name == "Follow-through"
    assert skill.instructions =~ "Your first job is disqualification, not escalation"
    assert skill.instructions =~ "Do not create follow-up candidates with keyword rules"
    assert skill.instructions =~ "Return ONLY valid JSON array"
    assert skill.instructions =~ "`recommended_action`"
    assert skill.instructions =~ "`suggested_reply_points`"
    assert skill.instructions =~ "`attention_mode` to `\"act_now\"` or `\"monitor\"`"
    assert skill.instructions =~ "Generic phrases such as \"send the follow-up\" are not enough"
  end

  test "travel logistics skill requires actionable trip briefs" do
    assert {:ok, skill} =
             MarkdownSkill.load_file("priv/agents/skills/chief_of_staff/travel_logistics.md")

    assert skill.id == "travel_logistics"
    assert skill.name == "Travel Logistics"
    assert skill.instructions =~ "This is not a raw itinerary dump"
    assert skill.instructions =~ "Return ONLY valid JSON"

    assert skill.instructions =~
             "\"status\": \"ready|incomplete|changed|cancelled|no_reliable_trip|source_gap\""

    assert skill.instructions =~ "`CHECK BEFORE YOU GO`"
    assert skill.instructions =~ "`NEXT MOVE`"
    assert skill.instructions =~ "Never invent confirmation codes"
    assert skill.instructions =~ "return a `source_gap` object instead of a heuristic itinerary"
  end

  test "commitment tracker skill produces open-work review output" do
    assert {:ok, skill} =
             MarkdownSkill.load_file("priv/agents/skills/chief_of_staff/commitment_tracker.md")

    assert skill.id == "commitment_tracker"
    assert skill.name == "Commitment Tracker"
    assert skill.instructions =~ "Open work review"
    assert skill.instructions =~ "not \"Commitment Tracker\" or automation names"
    assert skill.instructions =~ "Use `you`, never `the user` or a hardcoded person name"
    assert skill.instructions =~ "\"todos\""
    assert skill.instructions =~ "\"missing_sources\""
    assert skill.instructions =~ "Do not invent clear-day language"
    refute skill.instructions =~ "error-style body"
  end

  test "product manager skill returns executive-ready ticket JSON" do
    assert {:ok, skill} =
             MarkdownSkill.load_file("priv/agents/skills/product/github_product_planner.md")

    assert skill.id == "github_product_planner"
    assert skill.name == "Product Manager Agent"
    assert skill.instructions =~ "operator's Product Manager Agent"
    assert skill.instructions =~ "Return ONLY valid JSON"
    assert skill.instructions =~ "\"tickets\""
    assert skill.instructions =~ "\"insufficiency\""
    assert skill.instructions =~ "`acceptance_criteria` must be testable"
    assert skill.instructions =~ "Do not expose internal behavior names"
    refute skill.instructions =~ "Cybrus"
    refute skill.instructions =~ "ProductManagerAgent"
  end

  test "codebase advisor skill requires actionable engineering review output" do
    assert {:ok, skill} =
             MarkdownSkill.load_file("priv/agents/skills/engineering/codebase_advisor.md")

    assert skill.id == "codebase_advisor"
    assert skill.name == "Codebase Advisor"
    assert skill.instructions =~ "engineering review brief"
    assert skill.instructions =~ "severity, evidence, proposed fix, and verification"
    assert skill.instructions =~ "no material findings"
    assert skill.instructions =~ "insufficiency note"
    assert skill.instructions =~ "Do not expose internal behavior names"
  end

  test "repo planner skill requires executable implementation plans" do
    assert {:ok, skill} =
             MarkdownSkill.load_file("priv/agents/skills/engineering/repo_planner.md")

    assert skill.id == "repo_planner"
    assert skill.name == "Repo Planner"
    assert skill.instructions =~ "engineer who will execute the work"
    assert skill.instructions =~ "first reversible milestone"
    assert skill.instructions =~ "explicit verification"
    assert skill.instructions =~ "`Insufficient Context` section"
    assert skill.instructions =~ "smallest launchable slice"
    assert skill.instructions =~ "Do not expose internal behavior names"
  end

  test "loads priv markdown skills through configured runtime priv dir" do
    project_priv_dir = Path.expand("priv")
    previous_priv_dir = System.get_env("MARAITHON_PRIV_DIR")

    on_exit(fn ->
      if previous_priv_dir do
        System.put_env("MARAITHON_PRIV_DIR", previous_priv_dir)
      else
        System.delete_env("MARAITHON_PRIV_DIR")
      end
    end)

    System.put_env("MARAITHON_PRIV_DIR", project_priv_dir)

    assert {:ok, %MarkdownSkill{id: "morning_briefing"}} =
             MarkdownSkill.load_file("priv/agents/skills/chief_of_staff/morning_briefing.md")
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
