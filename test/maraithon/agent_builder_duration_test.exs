defmodule Maraithon.AgentBuilderDurationTest do
  use ExUnit.Case, async: true

  alias Maraithon.AgentBuilder

  test "repository automation defaults do not expose server-local paths" do
    for behavior <- ["codebase_advisor", "repo_planner"] do
      launch = AgentBuilder.launch_params_for_behavior(behavior)

      assert launch["codebase_path"] == ""
      assert launch["output_path"] == ""
      refute inspect(launch) =~ File.cwd!()
    end
  end

  test "agent builder accepts human-readable wakeup cadences" do
    launch =
      "watchdog_summarizer"
      |> AgentBuilder.launch_params_for_behavior()
      |> Map.merge(%{
        "builder_mode" => "advanced",
        "name" => "Status Watch",
        "wakeup_interval_ms" => "30m"
      })

    assert {:ok, start_params} = AgentBuilder.build_start_params(launch, "exec@example.com")
    assert get_in(start_params, ["config", "wakeup_interval_ms"]) == 1_800_000
  end

  test "agent builder still accepts explicit millisecond cadences" do
    launch =
      "github_product_planner"
      |> AgentBuilder.launch_params_for_behavior()
      |> Map.merge(%{
        "builder_mode" => "advanced",
        "repo_full_name" => "maraithon/app",
        "wakeup_interval_ms" => "86400000"
      })

    assert {:ok, start_params} = AgentBuilder.build_start_params(launch, "exec@example.com")
    assert get_in(start_params, ["config", "wakeup_interval_ms"]) == 86_400_000
  end
end
