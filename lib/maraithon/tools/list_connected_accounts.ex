defmodule Maraithon.Tools.ListConnectedAccounts do
  @moduledoc """
  MCP-safe connected account, connector, and tool coverage inventory.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.{Capabilities, ConnectedAccounts, Connections, SourceFreshness}

  @sensitive_key_fragments ~w(access_token refresh_token token secret authorization bearer password)

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      include_tools? = Map.get(args, "include_tools", true) != false
      include_freshness? = Map.get(args, "include_freshness", true) != false
      include_disconnected? = Map.get(args, "include_disconnected") == true

      {snapshot_status, snapshot} = connection_snapshot(user_id)

      accounts =
        user_id
        |> ConnectedAccounts.list_for_user()
        |> Enum.map(&serialize_account/1)

      connected_account_count = count_status(accounts, "connected")

      providers =
        snapshot
        |> Map.get(:providers, [])
        |> Enum.map(&serialize_provider(&1, include_tools?, include_disconnected?))
        |> Enum.reject(&is_nil/1)

      result =
        %{
          source: "maraithon_connected_accounts",
          degraded: snapshot_status == :degraded,
          connected_count: connected_account_count,
          connected_account_count: connected_account_count,
          connected_provider_count: Map.get(snapshot, :connected_count, 0),
          status_counts: status_counts(accounts),
          connected_accounts: accounts,
          providers: providers,
          built_in_resources: Capabilities.built_in_resource_coverage()
        }
        |> maybe_put(
          :source_freshness,
          include_freshness?,
          SourceFreshness.compact_for_prompt(user_id)
        )
        |> maybe_put(:tool_coverage, include_tools?, tool_coverage())

      {:ok, result}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp connection_snapshot(user_id) do
    case Connections.safe_dashboard_snapshot(user_id) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:degraded, snapshot} -> {:degraded, snapshot}
    end
  end

  defp serialize_provider(provider, include_tools?, include_disconnected?)
       when is_map(provider) do
    status = provider |> Map.get(:status) |> to_string()

    if include_disconnected? or
         status in ["connected", "partial", "needs_refresh", "missing_scope"] do
      connector_id = provider_connector_id(provider)
      tools = if include_tools?, do: provider_tools(provider, connector_id), else: []

      %{
        provider: Map.get(provider, :provider),
        label: Map.get(provider, :label),
        status: status,
        status_note: Map.get(provider, :status_note),
        connected?: status in ["connected", "partial"],
        updated_at: timestamp(Map.get(provider, :updated_at)),
        account_count: length(Map.get(provider, :accounts, [])),
        accounts: Enum.map(Map.get(provider, :accounts, []), &redact_map/1),
        services:
          Enum.map(Map.get(provider, :services, []), &serialize_service(&1, include_tools?)),
        connector_id: connector_id,
        tools: tools,
        operations: Capabilities.operations_for_tools(tools)
      }
    end
  end

  defp serialize_provider(_provider, _include_tools?, _include_disconnected?), do: nil

  defp provider_connector_id(%{provider: "google"}), do: "google"
  defp provider_connector_id(%{provider: "calendar"}), do: "google_calendar"
  defp provider_connector_id(%{provider: provider}) when is_binary(provider), do: provider
  defp provider_connector_id(_provider), do: nil

  defp provider_tools(%{provider: "google"} = provider, _connector_id) do
    provider
    |> Map.get(:services, [])
    |> Enum.flat_map(fn
      %{id: "gmail", status: status} when status in [:connected, "connected"] ->
        connector_tools("gmail")

      %{id: "calendar", status: status} when status in [:connected, "connected"] ->
        connector_tools("google_calendar")

      %{id: "contacts", status: status} when status in [:connected, "connected"] ->
        connector_tools("google_contacts")

      _service ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp provider_tools(_provider, connector_id), do: connector_tools(connector_id)

  defp connector_tools(connector_id) when is_binary(connector_id) do
    case Capabilities.connector_metadata_for(connector_id) do
      %{tool_names: tools} -> tools
      _ -> []
    end
  end

  defp connector_tools(_connector_id), do: []

  defp serialize_service(service, include_tools?) when is_map(service) do
    connector_id =
      case Map.get(service, :id) do
        "gmail" -> "gmail"
        "calendar" -> "google_calendar"
        "contacts" -> "google_contacts"
        _ -> nil
      end

    tools = if include_tools?, do: connector_tools(connector_id), else: []

    service
    |> redact_map()
    |> Map.merge(%{
      connector_id: connector_id,
      tools: tools,
      operations: Capabilities.operations_for_tools(tools)
    })
  end

  defp serialize_service(service, _include_tools?), do: redact_map(service)

  defp serialize_account(%ConnectedAccount{} = account) do
    %{
      provider: account.provider,
      external_account_id: account.external_account_id,
      status: account.status,
      scopes: account.scopes || [],
      metadata: redact_map(account.metadata || %{}),
      connected_at: timestamp(account.connected_at),
      last_refreshed_at: timestamp(account.last_refreshed_at),
      updated_at: timestamp(account.updated_at)
    }
  end

  defp tool_coverage do
    Capabilities.list_capabilities(:connector)
    |> Enum.map(fn connector ->
      %{
        connector_id: connector.id,
        display_name: connector.display_name,
        provider: connector.provider,
        oauth_scopes: connector.oauth_scopes,
        tools: connector.tool_names,
        operations: Capabilities.operations_for_tools(connector.tool_names)
      }
    end)
  end

  defp status_counts(accounts) when is_list(accounts) do
    Enum.reduce(accounts, %{}, fn account, acc ->
      status = read_status(account) || "unknown"
      Map.update(acc, status, 1, &(&1 + 1))
    end)
  end

  defp count_status(accounts, status) when is_list(accounts) and is_binary(status) do
    Enum.count(accounts, &(read_status(&1) == status))
  end

  defp read_status(%{} = account), do: Map.get(account, :status) || Map.get(account, "status")
  defp read_status(_account), do: nil

  defp maybe_put(map, _key, false, _value), do: map
  defp maybe_put(map, key, true, value), do: Map.put(map, key, value)

  defp redact_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key_string = to_string(key)

      if sensitive_key?(key_string) do
        {key, "[redacted]"}
      else
        {key, redact_value(value)}
      end
    end)
  end

  defp redact_map(other), do: other

  defp redact_value(value) when is_map(value), do: redact_map(value)
  defp redact_value(value) when is_list(value), do: Enum.map(value, &redact_value/1)
  defp redact_value(value), do: value

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp timestamp(%Date{} = value), do: Date.to_iso8601(value)
  defp timestamp(value), do: value

  defp sensitive_key?(key) do
    normalized = String.downcase(key)
    Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end
end
