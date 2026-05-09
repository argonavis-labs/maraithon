defmodule Maraithon.AssistantHarnessTest do
  use ExUnit.Case, async: true

  alias Maraithon.AssistantHarness

  test "uses the model response to choose tools instead of local keyword routing" do
    llm_complete = fn params ->
      prompt = get_in(params, ["messages", Access.at(1), "content"])

      assert prompt =~ "What are the emails to triage today?"
      assert prompt =~ "Decision contract:"
      assert prompt =~ "Do not rely on keyword heuristics"
      assert prompt =~ "Available tools JSON"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{"tool" => "get_open_work_summary", "arguments" => %{"limit" => 5}}
             ],
             "summary" => "Model decided source health is needed first."
           })
       }}
    end

    assert {:ok, response} =
             AssistantHarness.next_step(payload("What are the emails to triage today?"),
               llm_complete: llm_complete
             )

    assert response["status"] == "tool_calls"

    assert response["tool_calls"] == [
             %{"tool" => "get_open_work_summary", "arguments" => %{"limit" => 5}}
           ]
  end

  test "rejects invalid model output instead of using a semantic fallback" do
    llm_complete = fn _params -> {:ok, %{content: "not json"}} end

    assert {:error, :assistant_harness_invalid_json} =
             AssistantHarness.next_step(payload("What should I review?"),
               llm_complete: llm_complete
             )
  end

  test "rejects model-selected tools outside the available tool contract" do
    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{"tool" => "unknown_tool", "arguments" => %{}}
             ],
             "summary" => "Bad tool."
           })
       }}
    end

    assert {:error, {:assistant_harness_unknown_tool, "unknown_tool"}} =
             AssistantHarness.next_step(payload("Do something"), llm_complete: llm_complete)
  end

  test "uses the model response for proactive send versus hold decisions" do
    llm_complete = fn params ->
      prompt = get_in(params, ["messages", Access.at(1), "content"])

      assert prompt =~ "Proactive decision contract:"
      assert prompt =~ "Recent proactive push receipts JSON"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decision" => "send_now",
             "assistant_message" => "Rippling still needs an eligibility reply today.",
             "message_class" => "assistant_push",
             "urgency" => 0.91,
             "interrupt_now" => true,
             "dedupe_key" => "proactive:rippling:2026-05-09",
             "todo_ids" => ["todo-1"],
             "summary" => "A high-priority open loop is timely."
           })
       }}
    end

    assert {:ok, plan} =
             AssistantHarness.proactive_plan(
               %{
                 trigger: %{"type" => "scheduled_check_in"},
                 context: %{open_loops: %{totals: %{open_todos: 1}}},
                 recent_pushes: []
               },
               llm_complete: llm_complete
             )

    assert plan["decision"] == "send_now"
    assert plan["assistant_message"] =~ "Rippling"
    assert plan["urgency"] == 0.91
    assert plan["todo_ids"] == ["todo-1"]
  end

  test "rejects proactive send decisions without a message" do
    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decision" => "send_now",
             "assistant_message" => "",
             "message_class" => "assistant_push",
             "summary" => "Bad proactive payload."
           })
       }}
    end

    assert {:error, :assistant_harness_empty_message} =
             AssistantHarness.proactive_plan(%{context: %{}}, llm_complete: llm_complete)
  end

  defp payload(message) do
    %{
      context: %{
        "recent_turns" => [
          %{"role" => "assistant", "text" => "Earlier reply"},
          %{"role" => "user", "text" => message}
        ]
      },
      tools: [%{"name" => "get_open_work_summary"}, %{"name" => "list_todos"}],
      tool_history: []
    }
  end
end
