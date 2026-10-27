defmodule Maraithon.ChiefOfStaff.Skills.PromptCleanlinessTest do
  use ExUnit.Case, async: true

  alias Maraithon.AgentHarness.MarkdownSkill

  @chief_of_staff_skill_paths [
    "priv/agents/skills/chief_of_staff/morning_briefing.md",
    "priv/agents/skills/chief_of_staff/commitment_tracker.md",
    "priv/agents/skills/chief_of_staff/followthrough.md",
    "priv/agents/skills/chief_of_staff/travel_logistics.md"
  ]

  @tenant_specific_terms [
    "Kent",
    "kent@",
    "Runner",
    "runner",
    "runner.now",
    "Agora",
    "agora",
    "Glossier",
    "glossier",
    "voteagora",
    "#growthcrew",
    "Sara Franca",
    "Renat",
    "Justin Dean",
    "actc_"
  ]

  test "default Chief of Staff prompt assets do not ship tenant-specific context" do
    for path <- @chief_of_staff_skill_paths do
      prompt = File.read!(path)

      for term <- @tenant_specific_terms do
        refute prompt =~ term,
               "#{path} still contains tenant-specific prompt context: #{inspect(term)}"
      end
    end
  end

  test "prompt examples still teach action-first output shape" do
    assert {:ok, skill} =
             MarkdownSkill.load_file("priv/agents/skills/chief_of_staff/morning_briefing.md")

    assert skill.instructions =~ "Reference shape to target on packed days"
    assert skill.instructions =~ "## Needs Your Attention"
    assert skill.instructions =~ "## Today's Schedule"
    assert skill.instructions =~ "## Open Commitments"
    assert skill.instructions =~ "Today's move:"
  end
end
