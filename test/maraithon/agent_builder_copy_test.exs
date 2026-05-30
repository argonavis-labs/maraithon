defmodule Maraithon.AgentBuilderCopyTest do
  use ExUnit.Case, async: true

  alias Maraithon.AgentBuilder

  test "behavior spec copy avoids operator jargon" do
    visible_copy =
      AgentBuilder.behavior_specs()
      |> Enum.flat_map(&visible_spec_copy/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    assert visible_copy =~ "Shared preferences that shape interruption policy"
    assert visible_copy =~ "turns requested work into implementation plans"
    assert visible_copy =~ "calendar context, People, and memory"
    refute visible_copy =~ ~r/\boperator\b/i
    refute visible_copy =~ ~r/\bCRM\b/
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
