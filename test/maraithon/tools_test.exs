defmodule Maraithon.ToolsTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools

  describe "execute/2" do
    test "executes time tool" do
      {:ok, result} = Tools.execute("time", %{})

      assert is_binary(result.utc)
      assert is_integer(result.unix)
    end

    test "returns error for unknown tool" do
      {:error, {:tool_policy_denied, decision}} = Tools.execute("nonexistent_tool", %{})

      assert decision["reason_code"] == "unknown_tool"
    end
  end

  describe "list/0" do
    test "returns list of available tools" do
      tools = Tools.list()

      assert is_list(tools)
      assert "time" in tools
      assert "read_file" in tools
      assert "list_files" in tools
      assert "file_tree" in tools
      assert "search_files" in tools
      assert "gmail_list_recent" in tools
      assert "gmail_search" in tools
      assert "gmail_get_message" in tools
      assert "draft_message" in tools
      assert "google_calendar_list_events" in tools
      assert "review_connected_context" in tools
      assert "list_connected_accounts" in tools
      assert "get_open_loops" in tools
      assert "get_todo" in tools
      assert "list_todos" in tools
      assert "upsert_todos" in tools
      assert "update_todo" in tools
      assert "resolve_todo" in tools
      assert "delete_todo" in tools
      assert "list_people" in tools
      assert "get_person" in tools
      assert "upsert_person" in tools
      assert "delete_person" in tools
      assert "link_person_data" in tools
      assert "merge_people" in tools
      assert "get_relationship_context" in tools
      assert "list_memories" in tools
      assert "write_memory" in tools
      assert "recall_memory" in tools
      assert "forget_memory" in tools
      assert "record_memory_feedback" in tools
      assert "update_memory_confidence" in tools
      assert "github_create_issue_comment" in tools
      assert "slack_post_message" in tools
      assert "slack_list_conversations" in tools
      assert "slack_list_messages" in tools
      assert "slack_get_thread_replies" in tools
      assert "slack_search_messages" in tools
      assert "linear_create_comment" in tools
      assert "linear_create_issue" in tools
      assert "linear_update_issue_state" in tools
      assert "notaui_list_tasks" in tools
      assert "notaui_complete_task" in tools
      assert "notaui_update_task" in tools
    end
  end

  describe "describe/1" do
    test "returns typed MCP schemas and annotations" do
      [descriptor] = Tools.describe(["upsert_todos"])

      assert descriptor.name == "upsert_todos"
      assert get_in(descriptor.input_schema, ["properties", "user_id", "type"]) == "string"
      assert get_in(descriptor.input_schema, ["properties", "todos", "type"]) == "array"
      assert "user_id" in descriptor.input_schema["required"]
      assert "todos" in descriptor.input_schema["required"]
      assert descriptor.annotations["readOnlyHint"] == false
      assert descriptor.annotations["idempotentHint"] == true
      assert descriptor.annotations["sideEffect"] == "write"
      assert descriptor.annotations["resourceTypes"] == ["todo", "open_loop"]
      assert descriptor.annotations["operationTags"] == ["create", "update", "upsert"]

      [review_descriptor] = Tools.describe(["review_connected_context"])
      assert review_descriptor.annotations["readOnlyHint"] == true
      assert review_descriptor.annotations["sideEffect"] == "read"
      assert get_in(review_descriptor.input_schema, ["properties", "query", "type"]) == "string"

      assert get_in(review_descriptor.input_schema, ["properties", "timeout_ms", "maximum"]) ==
               30_000
    end

    test "every registered tool has policy metadata" do
      Enum.each(Tools.list(), fn tool_name ->
        metadata = Tools.policy_metadata_for(tool_name)

        assert is_map(metadata)
        assert metadata.side_effect in ~w(read write destructive external_send credential system)

        if metadata.destructive? or metadata.side_effect == "external_send" do
          refute metadata.read_only?
        end
      end)
    end
  end

  describe "exists?/1" do
    test "returns true for existing tool" do
      assert Tools.exists?("time")
      assert Tools.exists?("read_file")
      assert Tools.exists?("gmail_list_recent")
      assert Tools.exists?("draft_message")
      assert Tools.exists?("google_calendar_list_events")
      assert Tools.exists?("review_connected_context")
      assert Tools.exists?("list_connected_accounts")
      assert Tools.exists?("get_open_loops")
      assert Tools.exists?("get_todo")
      assert Tools.exists?("list_todos")
      assert Tools.exists?("upsert_todos")
      assert Tools.exists?("update_todo")
      assert Tools.exists?("resolve_todo")
      assert Tools.exists?("delete_todo")
      assert Tools.exists?("list_people")
      assert Tools.exists?("get_person")
      assert Tools.exists?("upsert_person")
      assert Tools.exists?("delete_person")
      assert Tools.exists?("link_person_data")
      assert Tools.exists?("merge_people")
      assert Tools.exists?("get_relationship_context")
      assert Tools.exists?("list_memories")
      assert Tools.exists?("write_memory")
      assert Tools.exists?("recall_memory")
      assert Tools.exists?("forget_memory")
      assert Tools.exists?("record_memory_feedback")
      assert Tools.exists?("update_memory_confidence")
      assert Tools.exists?("github_create_issue_comment")
      assert Tools.exists?("slack_list_messages")
      assert Tools.exists?("notaui_list_tasks")
    end

    test "returns false for non-existing tool" do
      refute Tools.exists?("nonexistent_tool")
    end
  end
end
