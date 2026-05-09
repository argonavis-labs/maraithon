defmodule Maraithon.AgentHarness.RunnerTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.AgentHarness.Runner
  alias Maraithon.Memory

  test "build_llm_params injects deep memory into harness context and prompt guidance" do
    user_id = "runner-memory-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _memory} =
      Memory.write(user_id, %{
        "title" => "Ignore generic market newsletters",
        "content" => "Generic market newsletters are not relevant unless tied to Runner.",
        "kind" => "relevance_feedback",
        "polarity" => "negative",
        "importance" => 80
      })

    manifest = %{
      model: "gpt-5.4",
      intelligence: "high",
      system_prompt: "Run the packaged agent.",
      goals: ["Answer with context."],
      skills: [],
      tool_allowlist: ["llm.complete", "recall_memory", "write_memory"]
    }

    assert {:ok, params} =
             Runner.build_llm_params(manifest, %{
               user_id: user_id,
               message: "Should I surface this market newsletter?"
             })

    [system, user] = params["messages"]
    assert system["content"] =~ "Deep Memory"
    assert system["content"] =~ "recall_memory"
    assert user["content"] =~ "deep_memory"
    assert user["content"] =~ "open_loops"
    assert user["content"] =~ "Generic market newsletters"
  end
end
