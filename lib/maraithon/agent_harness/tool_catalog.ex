defmodule Maraithon.AgentHarness.ToolCatalog do
  @moduledoc """
  Describes the tool and MCP capabilities exposed to the generic agent harness.
  """

  @tool_descriptors %{
    "calendar.list" => %{
      name: "calendar.list",
      connector: "google",
      mcp_server: "google",
      action: "list_events",
      side_effect: "read"
    },
    "gmail.read" => %{
      name: "gmail.read",
      connector: "google",
      mcp_server: "google",
      action: "read_message",
      side_effect: "read"
    },
    "gmail.search" => %{
      name: "gmail.search",
      connector: "google",
      mcp_server: "google",
      action: "search_messages",
      side_effect: "read"
    },
    "llm.complete" => %{
      name: "llm.complete",
      connector: nil,
      mcp_server: nil,
      action: "model_completion",
      side_effect: "generate"
    },
    "get_open_loops" => %{
      name: "get_open_loops",
      connector: nil,
      mcp_server: "maraithon",
      action: "get_open_loops",
      side_effect: "read"
    },
    "upsert_todos" => %{
      name: "upsert_todos",
      connector: nil,
      mcp_server: "maraithon",
      action: "model_dedupe_todos",
      side_effect: "write"
    },
    "list_todos" => %{
      name: "list_todos",
      connector: nil,
      mcp_server: "maraithon",
      action: "list_todos",
      side_effect: "read"
    },
    "resolve_todo" => %{
      name: "resolve_todo",
      connector: nil,
      mcp_server: "maraithon",
      action: "resolve_todo",
      side_effect: "write"
    },
    "list_people" => %{
      name: "list_people",
      connector: nil,
      mcp_server: "maraithon",
      action: "list_people",
      side_effect: "read"
    },
    "get_person" => %{
      name: "get_person",
      connector: nil,
      mcp_server: "maraithon",
      action: "get_person",
      side_effect: "read"
    },
    "upsert_person" => %{
      name: "upsert_person",
      connector: nil,
      mcp_server: "maraithon",
      action: "upsert_person",
      side_effect: "write"
    },
    "link_person_data" => %{
      name: "link_person_data",
      connector: nil,
      mcp_server: "maraithon",
      action: "link_person_data",
      side_effect: "write"
    },
    "get_relationship_context" => %{
      name: "get_relationship_context",
      connector: nil,
      mcp_server: "maraithon",
      action: "get_relationship_context",
      side_effect: "read"
    },
    "learn_relationship_context" => %{
      name: "learn_relationship_context",
      connector: nil,
      mcp_server: "maraithon",
      action: "learn_relationship_context",
      side_effect: "write"
    },
    "list_memories" => %{
      name: "list_memories",
      connector: nil,
      mcp_server: "maraithon",
      action: "list_deep_memory",
      side_effect: "read"
    },
    "write_memory" => %{
      name: "write_memory",
      connector: nil,
      mcp_server: "maraithon",
      action: "write_deep_memory",
      side_effect: "write"
    },
    "recall_memory" => %{
      name: "recall_memory",
      connector: nil,
      mcp_server: "maraithon",
      action: "recall_deep_memory",
      side_effect: "read"
    },
    "forget_memory" => %{
      name: "forget_memory",
      connector: nil,
      mcp_server: "maraithon",
      action: "forget_deep_memory",
      side_effect: "write"
    },
    "record_memory_feedback" => %{
      name: "record_memory_feedback",
      connector: nil,
      mcp_server: "maraithon",
      action: "record_relevance_feedback",
      side_effect: "write"
    },
    "update_memory_confidence" => %{
      name: "update_memory_confidence",
      connector: nil,
      mcp_server: "maraithon",
      action: "update_memory_confidence",
      side_effect: "write"
    },
    "slack.read" => %{
      name: "slack.read",
      connector: "slack",
      mcp_server: "slack",
      action: "read_message",
      side_effect: "read"
    },
    "slack.search" => %{
      name: "slack.search",
      connector: "slack",
      mcp_server: "slack",
      action: "search_messages",
      side_effect: "read"
    },
    "telegram.send" => %{
      name: "telegram.send",
      connector: "telegram",
      mcp_server: "telegram",
      action: "send_message",
      side_effect: "write"
    }
  }

  def describe(allowlist) when is_list(allowlist) do
    allowlist
    |> Enum.map(&Map.get(@tool_descriptors, &1, external_descriptor(&1)))
  end

  def describe(_allowlist), do: []

  def known_tool?(tool_name) when is_binary(tool_name),
    do: Map.has_key?(@tool_descriptors, tool_name)

  def known_tool?(_tool_name), do: false

  defp external_descriptor(tool_name) do
    %{
      name: tool_name,
      connector: nil,
      mcp_server: nil,
      action: "external",
      side_effect: "unknown"
    }
  end
end
