defmodule Maraithon.Tools.ListConnectedAccounts do
  @moduledoc """
  MCP-safe connected account, connector, and tool coverage inventory.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.{Capabilities, ConnectedAccounts, Connections, Redaction, SourceFreshness}

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
        provider: provider |> Map.get(:provider) |> public_provider(),
        label: Map.get(provider, :label),
        status: status,
        status_note: safe_status_note(Map.get(provider, :status_note)),
        connected?: status in ["connected", "partial"],
        updated_at: timestamp(Map.get(provider, :updated_at)),
        account_count: length(Map.get(provider, :accounts, [])),
        accounts: Enum.map(Map.get(provider, :accounts, []), &serialize_provider_account/1),
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
  defp provider_connector_id(%{provider: "google:" <> _}), do: "google"
  defp provider_connector_id(%{provider: "calendar"}), do: "google_calendar"
  defp provider_connector_id(%{provider: "slack" <> _}), do: "slack"
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

    %{
      id: read_key(service, :id),
      label: read_key(service, :label),
      description: read_key(service, :description),
      status: read_key(service, :status),
      count: read_key(service, :count),
      connector_id: connector_id,
      tools: tools,
      operations: Capabilities.operations_for_tools(tools)
    }
    |> compact_map()
  end

  defp serialize_service(service, _include_tools?) when is_map(service) do
    service
    |> Map.take([:id, :label, :description, :status, :count])
    |> compact_map()
  end

  defp serialize_service(_service, _include_tools?), do: %{}

  defp serialize_account(%ConnectedAccount{} = account) do
    %{
      provider: public_provider(account.provider),
      account_label: account_label(account),
      status: account.status,
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
        provider: public_provider(connector.provider),
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

  defp serialize_provider_account(account) when is_map(account) do
    provider = read_key(account, :provider)

    %{
      provider: public_provider(provider),
      account_label: provider_account_label(account, provider),
      status: read_key(account, :status),
      status_note: safe_status_note(read_key(account, :status_note)),
      updated_at: timestamp(read_key(account, :updated_at)),
      details: safe_details(read_key(account, :details)),
      needs_reconnect?: read_key(account, :needs_reconnect?),
      disconnectable?: read_key(account, :disconnectable?)
    }
    |> compact_map()
  end

  defp serialize_provider_account(_account), do: %{}

  defp provider_account_label(account, provider) when is_map(account) do
    account
    |> read_key(:account)
    |> safe_label(provider)
  end

  defp safe_label(value, provider) when is_binary(value) do
    trimmed = String.trim(value)
    public_provider = public_provider(provider)

    cond do
      trimmed == "" -> default_account_label(public_provider)
      raw_provider_identifier?(trimmed, provider) -> default_account_label(public_provider)
      true -> Redaction.redact_string(trimmed)
    end
  end

  defp safe_label(_value, provider), do: provider |> public_provider() |> default_account_label()

  defp raw_provider_identifier?(value, provider) do
    normalized_provider = public_provider(provider)

    cond do
      normalized_provider == "telegram" ->
        Regex.match?(~r/^\d{5,}$/, value)

      normalized_provider == "slack" ->
        Regex.match?(~r/^[TUW][A-Z0-9]{5,}$/, value)

      normalized_provider == "google" ->
        not String.contains?(value, "@") and Regex.match?(~r/^[A-Za-z0-9._:-]{8,}$/, value)

      true ->
        false
    end
  end

  defp default_account_label("google"), do: "Google account"
  defp default_account_label("slack"), do: "Slack workspace"
  defp default_account_label("telegram"), do: "Telegram"
  defp default_account_label("github"), do: "GitHub account"
  defp default_account_label("linear"), do: "Linear workspace"
  defp default_account_label("notion"), do: "Notion workspace"
  defp default_account_label("notaui"), do: "Notaui workspace"
  defp default_account_label("desktop"), do: "Paired Mac"
  defp default_account_label(_provider), do: "Connected account"

  defp safe_status_note(nil), do: nil

  defp safe_status_note(note) when is_binary(note) do
    note = Redaction.redact_string(note)
    normalized = String.downcase(note)

    cond do
      String.contains?(normalized, "chat:write") ->
        "Reconnect Slack to restore message sending."

      String.contains?(normalized, "oauth") or String.contains?(normalized, "token") or
          String.contains?(normalized, "re-auth") ->
        "Reconnect this account to refresh access."

      true ->
        note
    end
  end

  defp safe_status_note(note), do: note |> inspect() |> safe_status_note()

  defp safe_details(details) when is_list(details) do
    details
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Redaction.redact_string/1)
    |> Enum.reject(&internal_detail?/1)
  end

  defp safe_details(_details), do: []

  defp internal_detail?(detail) when is_binary(detail) do
    normalized = String.downcase(detail)

    Enum.any?(
      [" id:", "mcp:", "oauth", "scopes:", "token", "webhook", "callback url", "environment"],
      &String.contains?(normalized, &1)
    )
  end

  defp account_label(%ConnectedAccount{provider: provider, metadata: metadata} = account) do
    metadata = metadata || %{}

    cond do
      String.starts_with?(provider, "slack:") ->
        metadata_value(metadata, "team_name") || "Slack workspace"

      String.starts_with?(provider, "google:") or provider == "google" ->
        metadata_value(metadata, "account_email") || metadata_value(metadata, "email") ||
          google_provider_suffix(provider) || email_account_id(account.external_account_id) ||
          "Google account"

      provider == "telegram" ->
        "Telegram"

      provider == "notion" ->
        metadata_value(metadata, "workspace_name") || "Notion workspace"

      provider == "notaui" ->
        metadata_value(metadata, "default_account_label") || "Notaui workspace"

      provider == "github" ->
        case metadata_value(metadata, "login") do
          login when is_binary(login) -> "@#{login}"
          _ -> "GitHub account"
        end

      provider == "linear" ->
        linear_account_label(metadata)

      true ->
        default_account_label(public_provider(provider))
    end
  end

  defp linear_account_label(metadata) do
    metadata
    |> Map.get("teams")
    |> List.wrap()
    |> Enum.find_value(fn
      %{"name" => name} when is_binary(name) and name != "" -> name
      %{name: name} when is_binary(name) and name != "" -> name
      _other -> nil
    end) || "Linear workspace"
  end

  defp metadata_value(metadata, key) when is_map(metadata) and is_binary(key) do
    value = Map.get(metadata, key) || Map.get(metadata, metadata_atom_key(key))

    case value do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> Redaction.redact_string()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp metadata_value(_metadata, _key), do: nil

  defp metadata_atom_key("account_email"), do: :account_email
  defp metadata_atom_key("default_account_label"), do: :default_account_label
  defp metadata_atom_key("email"), do: :email
  defp metadata_atom_key("login"), do: :login
  defp metadata_atom_key("team_name"), do: :team_name
  defp metadata_atom_key("username"), do: :username
  defp metadata_atom_key("workspace_name"), do: :workspace_name
  defp metadata_atom_key(key), do: key

  defp google_provider_suffix("google:" <> account), do: email_account_id(account)
  defp google_provider_suffix(_provider), do: nil

  defp email_account_id(value) when is_binary(value) do
    value = String.trim(value)

    if String.contains?(value, "@"), do: value
  end

  defp email_account_id(_value), do: nil

  defp public_provider("google:" <> _), do: "google"
  defp public_provider("slack:" <> _), do: "slack"
  defp public_provider(provider) when is_binary(provider), do: provider
  defp public_provider(nil), do: nil
  defp public_provider(provider), do: to_string(provider)

  defp read_key(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp compact_map(map) when is_map(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, %{}} -> true
      {_key, ""} -> true
      _other -> false
    end)
  end

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp timestamp(%Date{} = value), do: Date.to_iso8601(value)
  defp timestamp(value), do: value
end
