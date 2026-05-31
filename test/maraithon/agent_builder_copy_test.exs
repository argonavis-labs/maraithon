defmodule Maraithon.AgentBuilderCopyTest do
  use ExUnit.Case, async: true

  alias Maraithon.AgentBuilder

  test "behavior spec copy avoids operator jargon" do
    visible_copy =
      AgentBuilder.behavior_specs()
      |> Enum.flat_map(&visible_spec_copy/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    assert visible_copy =~ "Shared preferences that shape notification policy"
    assert visible_copy =~ "turns requested work into implementation plans"
    assert visible_copy =~ "calendar context, People, and memory"
    assert visible_copy =~ "Daily deduped commitment work items"
    refute visible_copy =~ ~r/\boperator\b/i
    refute visible_copy =~ ~r/\bCRM\b/
    refute visible_copy =~ "commitment todos"
    refute visible_copy =~ "interruption policy"
    refute visible_copy =~ "scored for"
    refute visible_copy =~ "confidence threshold"
    refute visible_copy =~ "min_confidence"
    refute visible_copy =~ "deep crawl"
    refute visible_copy =~ "wakeup cadence"
    refute visible_copy =~ "scan volume"
    refute visible_copy =~ "inbox scan"
    refute visible_copy =~ "scan surface"
    refute visible_copy =~ ~r/\bwakeup\b/i
    refute visible_copy =~ ~r/\bspend\b/i
  end

  test "coverage profile copy stays outcome-facing" do
    visible_copy =
      AgentBuilder.cost_profile_options()
      |> Enum.flat_map(&[&1.label, &1.description])
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    assert visible_copy =~ "Quiet mode"
    assert visible_copy =~ "Good coverage"
    assert visible_copy =~ "Broader review"
    refute visible_copy =~ ~r/\bspend\b/i
    refute visible_copy =~ ~r/\bscans?\b/i
  end

  defp visible_spec_copy(spec) do
    [
      Map.get(spec, :label),
      Map.get(spec, :category),
      Map.get(spec, :summary),
      Map.get(spec, :inputs, []),
      Map.get(spec, :outputs, []),
      Map.get(spec, :suggestions, []),
      requirement_copy(Map.get(spec, :requirements, []))
    ]
    |> List.flatten()
  end

  defp requirement_copy(requirements) do
    Enum.flat_map(requirements, fn requirement ->
      [Map.get(requirement, :label), Map.get(requirement, :description)]
    end)
  end
end
