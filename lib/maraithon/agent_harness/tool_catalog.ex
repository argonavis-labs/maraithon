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
