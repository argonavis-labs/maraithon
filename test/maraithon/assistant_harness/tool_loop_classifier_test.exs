defmodule Maraithon.AssistantHarness.ToolLoopClassifierTest do
  use ExUnit.Case, async: true

  alias Maraithon.AssistantHarness.ToolLoopClassifier

  test "classifies same tool and args repeats" do
    history = [
      %{"tool" => "gmail_search", "arguments" => %{"q" => "kent"}, "result" => %{"items" => []}},
      %{"tool" => "gmail_search", "arguments" => %{"q" => "kent"}, "result" => %{"items" => []}},
      %{"tool" => "gmail_search", "arguments" => %{"q" => "kent"}, "result" => %{"items" => []}}
    ]

    assert {:loop, %{class: "same_tool_args", tool: "gmail_search", count: 3}} =
             ToolLoopClassifier.classify(history)
  end

  test "classifies polling without progress" do
    history = [
      %{"tool" => "gmail_search", "arguments" => %{"page" => 1}, "result" => %{"items" => []}},
      %{"tool" => "gmail_search", "arguments" => %{"page" => 2}, "result" => %{"items" => []}},
      %{"tool" => "gmail_search", "arguments" => %{"page" => 3}, "result" => %{"items" => []}}
    ]

    assert {:loop, %{class: "polling_no_progress", tool: "gmail_search"}} =
             ToolLoopClassifier.classify(history)
  end

  test "classifies unknown tool repeats, ping-pong, and post-compaction repeats" do
    unknown = [
      %{"tool" => "gmail_search_messages", "arguments" => %{}, "error" => "unknown_tool"},
      %{"tool" => "gmail_search_messages", "arguments" => %{}, "error" => "unknown_tool"},
      %{"tool" => "gmail_search_messages", "arguments" => %{}, "error" => "unknown_tool"}
    ]

    assert {:loop, %{class: "unknown_tool_repeat"}} = ToolLoopClassifier.classify(unknown)

    ping_pong = [
      %{"tool" => "gmail_search", "arguments" => %{"q" => "x"}, "result" => %{"ok" => true}},
      %{"tool" => "list_todos", "arguments" => %{}, "result" => %{"ok" => true}},
      %{"tool" => "gmail_search", "arguments" => %{"q" => "y"}, "result" => %{"ok" => true}},
      %{"tool" => "list_todos", "arguments" => %{}, "result" => %{"ok" => true}}
    ]

    assert {:loop, %{class: "ping_pong"}} = ToolLoopClassifier.classify(ping_pong)

    post_compaction = [
      %{
        "tool" => "review_connected_context",
        "arguments" => %{"q" => "Charlie"},
        "result" => %{"items" => [], "_truncated_keys" => 4}
      },
      %{
        "tool" => "review_connected_context",
        "arguments" => %{"q" => "Charlie"},
        "result" => %{"items" => [], "_truncated_keys" => 4}
      }
    ]

    assert {:loop, %{class: "post_compaction_repeat"}} =
             ToolLoopClassifier.classify(post_compaction)
  end
end
