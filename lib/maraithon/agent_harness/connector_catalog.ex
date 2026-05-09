defmodule Maraithon.AgentHarness.ConnectorCatalog do
  @moduledoc """
  Builds the connector and MCP view available to a package install.
  """

  alias Maraithon.AgentHarness.Manifest
  alias Maraithon.AgentHarness.ToolCatalog
  alias Maraithon.ConnectedAccounts

  def for_user(user_id, manifest) when is_binary(user_id) and is_map(manifest) do
    connected =
      user_id
      |> ConnectedAccounts.list_for_user()
      |> Enum.group_by(& &1.provider)

    required = Manifest.get(manifest, :required_connectors, %{})
    tools = Manifest.get(manifest, :tool_allowlist, [])

    %{
      connected_apps: connected_apps(connected),
      required_connectors: required,
      missing_required_connectors: missing_required_connectors(required, connected),
      tools: ToolCatalog.describe(tools),
      mcp_allowlist: Manifest.get(manifest, :mcp_allowlist, [])
    }
  end

  def for_user(_user_id, manifest) when is_map(manifest) do
    %{
      connected_apps: [],
      required_connectors: Manifest.get(manifest, :required_connectors, %{}),
      missing_required_connectors: [],
      tools: ToolCatalog.describe(Manifest.get(manifest, :tool_allowlist, [])),
      mcp_allowlist: Manifest.get(manifest, :mcp_allowlist, [])
    }
  end

  defp connected_apps(connected) do
    connected
    |> Enum.map(fn {provider, accounts} ->
      %{
        provider: provider,
        connected_accounts: length(accounts),
        account_ids: Enum.map(accounts, & &1.id)
      }
    end)
    |> Enum.sort_by(& &1.provider)
  end

  defp missing_required_connectors(required, connected) when is_map(required) do
    required
    |> Enum.reject(fn {provider, _requirements} -> Map.has_key?(connected, provider) end)
    |> Enum.map(fn {provider, requirements} ->
      %{
        provider: provider,
        requirements: requirements
      }
    end)
  end

  defp missing_required_connectors(_required, _connected), do: []
end
