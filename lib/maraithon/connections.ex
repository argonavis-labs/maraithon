defmodule Maraithon.Connections do
  @moduledoc """
  Admin-facing connection inventory for integrations.
  """

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Companion.Devices
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Telegram
  alias Maraithon.OAuth
  alias Maraithon.OAuth.{GitHub, Google, Linear, Notaui, Notion, Slack, Token}
  alias MaraithonWeb.LocalTime
  alias MaraithonWeb.TelegramLink

  @google_services [
    %{
      id: "gmail",
      label: "Gmail",
      description: "Watch inbox changes and thread context."
    },
    %{
      id: "calendar",
      label: "Google Calendar",
      description: "Track upcoming events and schedule changes."
    },
    %{
      id: "contacts",
      label: "Google Contacts",
      description: "Read your People/Contacts graph for context."
    }
  ]

  @desktop_services [
    %{
      id: "imessage",
      stat_key: :messages_count,
      label: "iMessage",
      description: "Conversation context from Messages on the paired Mac."
    },
    %{
      id: "notes",
      stat_key: :notes_count,
      label: "Apple Notes",
      description: "Private notes Maraithon can recall when asked."
    },
    %{
      id: "voice_memos",
      stat_key: :voice_memos_count,
      label: "Voice Memos",
      description: "Voice memo metadata and transcripts when available."
    },
    %{
      id: "calendar",
      stat_key: :calendar_events_count,
      label: "Apple Calendar",
      description: "Calendar events from the paired Mac."
    },
    %{
      id: "reminders",
      stat_key: :reminders_count,
      label: "Reminders",
      description: "Local reminders for personal follow-through."
    },
    %{
      id: "files",
      stat_key: :files_count,
      label: "Files",
      description: "Selected file context from the desktop companion."
    },
    %{
      id: "browser",
      stat_key: :browser_visits_count,
      label: "Browser History",
      description: "Browser history context when the user enables it."
    }
  ]

  @doc """
  Returns the default control-center user id used for OAuth grants.
  """
  def default_user_id do
    Application.get_env(:maraithon, :admin_control, [])
    |> Keyword.get(:default_user_id, "operator")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "operator"
      value -> value
    end
  end

  @doc """
  Returns a safe snapshot of connectable integrations for the given user.
  """
  def safe_dashboard_snapshot(user_id, opts \\ []) when is_binary(user_id) do
    return_to = Keyword.get(opts, :return_to, "/")

    fetcher =
      Keyword.get(opts, :fetcher, fn -> dashboard_snapshot(user_id, return_to: return_to) end)

    case safe_fetch(fetcher) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, reason} ->
        {:degraded, fallback_snapshot(user_id, return_to, reason)}
    end
  end

  @doc """
  Returns the connection dashboard snapshot for the given user.
  """
  def dashboard_snapshot(user_id, opts \\ []) when is_binary(user_id) do
    return_to = Keyword.get(opts, :return_to, "/")
    connected_accounts = ConnectedAccounts.list_for_user(user_id)

    tokens =
      OAuth.list_user_tokens(user_id)
      |> Enum.sort_by(&provider_sort_key/1)

    account_by_provider = Map.new(connected_accounts, &{&1.provider, &1})
    token_by_provider = Map.new(tokens, &{&1.provider, &1})
    google_tokens = Enum.filter(tokens, &google_provider?(&1.provider))
    slack_tokens = Enum.filter(tokens, &slack_provider?(&1.provider))
    telegram_account = ConnectedAccounts.get(user_id, "telegram")
    timezone_info = LocalTime.timezone_info_for_user(user_id)

    telegram_connected? = connected_account?(telegram_account)

    providers =
      [
        telegram_card(user_id, telegram_account, return_to, timezone_info),
        desktop_card(user_id, return_to, timezone_info),
        google_card(user_id, google_tokens, account_by_provider, return_to, timezone_info),
        github_card(
          user_id,
          token_by_provider["github"],
          account_by_provider["github"],
          return_to,
          timezone_info
        ),
        slack_card(user_id, slack_tokens, account_by_provider, return_to, timezone_info),
        linear_card(
          user_id,
          token_by_provider["linear"],
          account_by_provider["linear"],
          return_to,
          timezone_info
        ),
        notion_card(
          user_id,
          token_by_provider["notion"],
          account_by_provider["notion"],
          return_to,
          timezone_info
        ),
        notaui_card(
          user_id,
          token_by_provider["notaui"],
          account_by_provider["notaui"],
          return_to,
          timezone_info
        )
      ]
      |> Enum.map(&enforce_telegram_first(&1, telegram_connected?))

    %{
      user_id: user_id,
      providers: providers,
      raw_tokens: Enum.map(tokens, &serialize_token/1),
      connected_count: Enum.count(providers, &(&1.status in [:connected, :partial])),
      telegram_connected?: telegram_connected?,
      degraded: false,
      errors: []
    }
  end

  @doc """
  Projects package connector requirements into user-facing readiness rows.
  """
  def connector_readiness(user_id, required_connectors, opts \\ [])

  def connector_readiness(user_id, required_connectors, opts)
      when is_binary(user_id) and is_map(required_connectors) do
    return_to = Keyword.get(opts, :return_to, "/connectors")
    snapshot = dashboard_snapshot(user_id, return_to: return_to)
    provider_by_id = Map.new(snapshot.providers, &{&1.provider, &1})

    required_connectors
    |> normalize_required_connectors()
    |> Enum.map(&readiness_item(&1, provider_by_id))
    |> Enum.reject(&is_nil/1)
  end

  def connector_readiness(_user_id, _required_connectors, _opts), do: []

  @doc """
  Disconnects a provider grant for the given control-center user.
  """
  def disconnect(user_id, "google") when is_binary(user_id) do
    google_providers =
      OAuth.list_user_tokens(user_id)
      |> Enum.map(& &1.provider)
      |> Enum.filter(&google_provider?/1)
      |> Enum.uniq()

    case google_providers do
      [] ->
        {:error, :no_token}

      providers ->
        revoke_many(user_id, providers)
    end
  end

  def disconnect(user_id, "google:" <> _ = provider) when is_binary(user_id) do
    OAuth.revoke(user_id, provider)
  end

  def disconnect(user_id, "slack") when is_binary(user_id) do
    slack_providers =
      OAuth.list_user_tokens(user_id)
      |> Enum.map(& &1.provider)
      |> Enum.filter(&slack_provider?/1)
      |> Enum.uniq()

    case slack_providers do
      [] ->
        {:error, :no_token}

      providers ->
        revoke_many(user_id, providers)
    end
  end

  def disconnect(user_id, "slack:" <> _ = provider) when is_binary(user_id) do
    slack_providers =
      OAuth.list_user_tokens(user_id)
      |> Enum.map(& &1.provider)
      |> Enum.filter(&slack_same_workspace_provider?(&1, provider))
      |> Enum.uniq()

    case slack_providers do
      [] ->
        {:error, :no_token}

      providers ->
        revoke_many(user_id, providers)
    end
  end

  def disconnect(user_id, "telegram") when is_binary(user_id) do
    ConnectedAccounts.mark_disconnected(user_id, "telegram", notify?: false)
  end

  def disconnect(user_id, provider)
      when is_binary(user_id) and is_binary(provider) and
             provider in ["github", "linear", "notaui", "notion"] do
    OAuth.revoke(user_id, provider)
  end

  def disconnect(_user_id, _provider), do: {:error, :unsupported_provider}

  defp revoke_many(user_id, providers) when is_binary(user_id) and is_list(providers) do
    errors =
      Enum.reduce(providers, [], fn provider, acc ->
        case OAuth.revoke(user_id, provider) do
          {:ok, _deleted} -> acc
          {:error, :no_token} -> acc
          {:error, reason} -> [{provider, reason} | acc]
        end
      end)

    case Enum.reverse(errors) do
      [] -> {:ok, %{revoked: length(providers)}}
      failures -> {:error, {:partial_disconnect, failures}}
    end
  end

  defp fallback_snapshot(user_id, return_to, reason) do
    timezone_info = LocalTime.default_timezone_info()

    providers =
      [
        telegram_card(user_id, nil, return_to, timezone_info),
        desktop_unavailable_card(),
        google_card(user_id, [], %{}, return_to, timezone_info),
        github_card(user_id, nil, nil, return_to, timezone_info),
        slack_card(user_id, [], %{}, return_to, timezone_info),
        linear_card(user_id, nil, nil, return_to, timezone_info),
        notion_card(user_id, nil, nil, return_to, timezone_info),
        notaui_card(user_id, nil, nil, return_to, timezone_info)
      ]
      |> Enum.map(&enforce_telegram_first(&1, false))
      |> Enum.map(&mark_unavailable/1)

    %{
      user_id: user_id,
      providers: providers,
      raw_tokens: [],
      connected_count: 0,
      telegram_connected?: false,
      degraded: true,
      errors: [
        %{
          message: "Maraithon could not load connected app status.",
          details: connection_inventory_error_detail(reason)
        }
      ]
    }
  end

  defp connection_inventory_error_detail(_reason),
    do:
      "Refresh this page in a moment before changing connections. Maraithon will keep checking app status."

  defp google_card(user_id, tokens, account_by_provider, return_to, timezone_info)
       when is_list(tokens) and is_map(account_by_provider) do
    configured? = Google.configured?()

    account_entries =
      google_account_entries(user_id, tokens, account_by_provider, return_to, timezone_info)

    reauth_required? = Enum.any?(account_entries, &(&1.status == :needs_refresh))

    services =
      Enum.map(@google_services, fn service ->
        required_scopes = Google.scopes_for([service.id])

        connected? =
          Enum.any?(tokens, fn token ->
            google_service_connected?(token, required_scopes) and
              token_account_status(token, account_by_provider) != :needs_refresh
          end)

        %{
          id: service.id,
          label: service.label,
          description: service.description,
          status: google_service_status(configured?, tokens, connected?),
          connect_url: auth_url("/auth/google", user_id, return_to, scopes: service.id)
        }
      end)

    status =
      cond do
        not configured? -> :not_configured
        tokens == [] -> :disconnected
        reauth_required? -> :needs_refresh
        Enum.all?(services, &(&1.status == :connected)) -> :connected
        true -> :partial
      end

    %{
      id: "google",
      provider: "google",
      label: "Google Workspace",
      description: "Gmail, Calendar, and Contacts access for Maraithon.",
      status: status,
      configured?: configured?,
      updated_at: latest_updated_at(tokens),
      disconnectable?: tokens != [],
      connect_url:
        auth_url("/auth/google", user_id, return_to, scopes: "gmail,calendar,contacts"),
      disconnect_label: "Disconnect Google",
      refresh_token_status: refresh_token_status(tokens, account_entries),
      details: google_details(tokens),
      services: services,
      accounts: account_entries
    }
    |> enrich_provider_setup()
  end

  defp github_card(user_id, token, account, return_to, timezone_info) do
    configured? = GitHub.configured?()

    account_entry =
      single_oauth_account_entry(
        user_id,
        token,
        account,
        return_to,
        "/auth/github",
        &github_account_label/1
      )

    %{
      id: "github",
      provider: "github",
      label: "GitHub",
      description:
        "Connect repos and organizations so Maraithon can inspect issues and comment when you approve it.",
      status: provider_status(configured?, token, account),
      configured?: configured?,
      updated_at: token && token.updated_at,
      disconnectable?: not is_nil(token),
      connect_url: auth_url("/auth/github", user_id, return_to),
      disconnect_label: "Disconnect GitHub",
      refresh_token_status: refresh_token_status(token, account_entry),
      details:
        provider_details(
          token,
          [
            metadata_value(token, ["login"]) && "@#{metadata_value(token, ["login"])}",
            metadata_value(token, ["email"]),
            permission_summary(token_scopes(token), "GitHub")
          ],
          timezone_info
        ),
      services: [],
      accounts: maybe_single_account_entry(account_entry)
    }
    |> enrich_provider_setup()
  end

  defp desktop_card(user_id, _return_to, timezone_info) when is_binary(user_id) do
    device_entries =
      user_id
      |> Devices.list_for_user()
      |> Devices.enrich_with_stats()

    active_entries = Enum.reject(device_entries, fn {device, _stats} -> device.revoked_at end)
    totals = desktop_totals(active_entries)
    total_synced = desktop_total_count(totals)

    status =
      cond do
        active_entries == [] -> :disconnected
        total_synced == 0 -> :partial
        true -> :connected
      end

    %{
      id: "desktop",
      provider: "desktop",
      label: "Maraithon Mac companion",
      description:
        "Securely make iMessage, Apple Notes, reminders, calendar, files, browser history, and voice memos available to Maraithon.",
      status: status,
      configured?: true,
      updated_at: latest_device_seen_at(active_entries),
      disconnectable?: false,
      connect_url: "/connectors/desktop",
      disconnect_label: "Manage Mac companion",
      refresh_token_status: :not_applicable,
      details: desktop_details(active_entries, totals, timezone_info),
      services: desktop_services(totals),
      accounts: desktop_device_accounts(device_entries)
    }
    |> enrich_provider_setup()
  end

  defp desktop_unavailable_card do
    totals = desktop_totals([])

    %{
      id: "desktop",
      provider: "desktop",
      label: "Maraithon Mac companion",
      description:
        "Securely make iMessage, Apple Notes, reminders, calendar, files, browser history, and voice memos available to Maraithon.",
      status: :unknown,
      configured?: true,
      updated_at: nil,
      disconnectable?: false,
      connect_url: "/connectors/desktop",
      disconnect_label: "Manage Mac companion",
      refresh_token_status: :unknown,
      details: desktop_details([], totals, LocalTime.default_timezone_info()),
      services: desktop_services(totals),
      accounts: []
    }
    |> enrich_provider_setup()
  end

  defp slack_card(user_id, tokens, account_by_provider, return_to, timezone_info)
       when is_list(tokens) and is_map(account_by_provider) do
    configured? = Slack.configured?()
    bot_token = slack_bot_token(tokens)
    user_tokens = slack_user_tokens(tokens)
    first_user_token = List.first(user_tokens)
    bot_scopes = token_scope_set(bot_token)
    account_entries = slack_account_entries(user_id, tokens, account_by_provider, return_to)
    reauth_required? = Enum.any?(account_entries, &(&1.status == :needs_refresh))

    workspace_names =
      tokens
      |> Enum.map(fn token -> metadata_value(token, ["team_name"]) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    status =
      cond do
        not configured? -> :not_configured
        is_nil(bot_token) -> :disconnected
        reauth_required? -> :needs_refresh
        user_tokens == [] -> :partial
        true -> :connected
      end

    details =
      provider_details(
        bot_token,
        [
          if(workspace_names != [], do: "Workspaces: #{Enum.join(workspace_names, ", ")}"),
          if(MapSet.size(bot_scopes) > 0, do: "Channel access connected"),
          if(user_tokens != [], do: "DMs and approved replies are enabled."),
          if(user_tokens == [],
            do: "Reconnect Slack to enable DMs and approved replies."
          )
        ],
        timezone_info
      )

    services = [
      %{
        id: "channels",
        label: "Channels",
        description: "Track commitments and unresolved action loops in channel conversations.",
        status:
          slack_service_status(
            configured?,
            bot_token,
            bot_token && Map.get(account_by_provider, bot_token.provider)
          )
      },
      %{
        id: "dms",
        label: "Personal DMs",
        description:
          "Read DM and MPIM context to catch unanswered replies and private commitments.",
        status:
          slack_service_status(
            configured?,
            first_user_token,
            first_user_token && Map.get(account_by_provider, first_user_token.provider)
          )
      }
    ]

    %{
      id: "slack",
      provider: "slack",
      label: "Slack",
      description:
        "Install Maraithon in Slack to watch commitments and send replies when you approve them.",
      status: status,
      configured?: configured?,
      updated_at: latest_updated_at(tokens),
      disconnectable?: tokens != [],
      connect_url: auth_url("/auth/slack", user_id, return_to),
      disconnect_label: "Disconnect Slack",
      refresh_token_status: refresh_token_status(tokens, account_entries),
      details: details,
      services: services,
      accounts: account_entries
    }
    |> enrich_provider_setup()
  end

  defp linear_card(user_id, token, account, return_to, timezone_info) do
    configured? = Linear.configured?()

    account_entry =
      single_oauth_account_entry(
        user_id,
        token,
        account,
        return_to,
        "/auth/linear",
        &linear_account_label/1
      )

    team_names =
      token
      |> metadata_value(["teams"])
      |> normalize_list()
      |> Enum.map(fn
        %{"key" => key, "name" => name} when is_binary(key) and is_binary(name) ->
          "#{name} (#{key})"

        %{"key" => key} when is_binary(key) ->
          key

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    %{
      id: "linear",
      provider: "linear",
      label: "Linear",
      description: "Connect your Linear workspace for issue review and issue/comment actions.",
      status: provider_status(configured?, token, account),
      configured?: configured?,
      updated_at: token && token.updated_at,
      disconnectable?: not is_nil(token),
      connect_url: auth_url("/auth/linear", user_id, return_to),
      disconnect_label: "Disconnect Linear",
      refresh_token_status: refresh_token_status(token, account_entry),
      details:
        provider_details(
          token,
          [
            if(team_names != [], do: "Teams: #{Enum.join(team_names, ", ")}"),
            permission_summary(token_scopes(token), "Linear")
          ],
          timezone_info
        ),
      services: [],
      accounts: maybe_single_account_entry(account_entry)
    }
    |> enrich_provider_setup()
  end

  defp telegram_card(user_id, account, return_to, timezone_info) do
    configured? = Telegram.configured?()
    metadata = if account, do: account.metadata || %{}, else: %{}
    username = metadata["username"]

    status =
      cond do
        not configured? -> :not_configured
        account && account.status == "connected" -> :connected
        true -> :disconnected
      end

    %{
      id: "telegram",
      provider: "telegram",
      label: "Telegram Bot",
      description: "Receive urgent Maraithon insights with inline helpful/not-helpful feedback.",
      status: status,
      configured?: configured?,
      updated_at: account && account.updated_at,
      disconnectable?: account && account.status == "connected",
      connect_url:
        TelegramLink.deep_link(user_id) || auth_url("/connectors/telegram", user_id, return_to),
      disconnect_label: "Disconnect Telegram",
      refresh_token_status: :not_applicable,
      details:
        if account && account.status == "connected" do
          [
            telegram_chat_detail(username),
            "Last updated #{format_datetime(account.updated_at, timezone_info)}"
          ]
          |> Enum.reject(&is_nil/1)
        else
          telegram_unlinked_details(user_id)
        end,
      services: []
    }
    |> enrich_provider_setup()
  end

  defp desktop_totals(device_entries) do
    empty_totals = Enum.into(@desktop_services, %{}, &{&1.stat_key, 0})

    Enum.reduce(device_entries, empty_totals, fn {_device, stats}, totals ->
      Enum.reduce(@desktop_services, totals, fn service, acc ->
        Map.update!(acc, service.stat_key, &(&1 + Map.get(stats, service.stat_key, 0)))
      end)
    end)
  end

  defp desktop_total_count(totals) when is_map(totals) do
    totals
    |> Map.values()
    |> Enum.sum()
  end

  defp desktop_details([], _totals, _timezone_info) do
    [
      "Pair a Mac to make local context available to your assistant.",
      "Install the Maraithon Mac companion app to include iMessage, Apple Notes, files, reminders, calendar events, browser history, and voice memos securely."
    ]
  end

  defp desktop_details(active_entries, totals, timezone_info) do
    device_count = length(active_entries)
    last_seen = latest_device_seen_at(active_entries)
    source_summary = desktop_source_summary(totals)

    [
      "#{device_count} #{pluralize("Mac", device_count)} paired",
      source_summary,
      if(last_seen, do: "Last seen #{format_datetime(last_seen, timezone_info)}")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp desktop_services(totals) do
    Enum.map(@desktop_services, fn service ->
      count = Map.get(totals, service.stat_key, 0)

      %{
        id: service.id,
        label: service.label,
        description: desktop_service_description(service, count),
        status: if(count > 0, do: :connected, else: :disconnected),
        count: count
      }
    end)
  end

  defp desktop_service_description(service, 0), do: service.description

  defp desktop_service_description(service, count) do
    "#{service.description} #{desktop_count_label(service.stat_key, count)} available to your assistant."
  end

  defp desktop_device_accounts(device_entries) do
    device_entries
    |> Enum.map(fn {device, stats} ->
      revoked? = not is_nil(device.revoked_at)
      synced_count = desktop_total_count(stats)

      %{
        provider: "desktop:#{device.id}",
        account: desktop_device_name(device),
        updated_at: device.last_seen_at || device.updated_at || device.inserted_at,
        status: if(revoked?, do: :disconnected, else: :connected),
        status_note: if(revoked?, do: "Device is revoked.", else: "Healthy"),
        details: desktop_device_details(stats, revoked?, synced_count),
        reconnect_url: nil,
        needs_reconnect?: false,
        disconnectable?: false
      }
    end)
    |> Enum.sort_by(&timestamp_sort_value(&1.updated_at), :desc)
  end

  defp desktop_device_name(device) do
    normalize_text(device.device_name) || "Paired Mac"
  end

  defp desktop_device_details(_stats, true, _synced_count) do
    ["Local data remains available until the device record is deleted."]
  end

  defp desktop_device_details(_stats, _revoked?, 0) do
    ["Paired and waiting for its first context check."]
  end

  defp desktop_device_details(stats, _revoked?, _synced_count) do
    stats
    |> desktop_source_labels()
    |> Enum.take(4)
  end

  defp desktop_source_summary(totals) do
    case desktop_source_labels(totals) do
      [] -> "Waiting for local sources to finish their first context check."
      labels -> "Context available: #{Enum.join(labels, ", ")}."
    end
  end

  defp desktop_source_labels(stats) when is_map(stats) do
    @desktop_services
    |> Enum.map(fn service ->
      count = Map.get(stats, service.stat_key, 0)
      if count > 0, do: desktop_count_label(service.stat_key, count)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp desktop_count_label(:messages_count, count), do: count_label(count, "iMessage")
  defp desktop_count_label(:notes_count, count), do: count_label(count, "Apple Note")
  defp desktop_count_label(:voice_memos_count, count), do: count_label(count, "voice memo")

  defp desktop_count_label(:calendar_events_count, count),
    do: count_label(count, "calendar event")

  defp desktop_count_label(:reminders_count, count), do: count_label(count, "reminder")
  defp desktop_count_label(:files_count, count), do: count_label(count, "file")
  defp desktop_count_label(:browser_visits_count, count), do: count_label(count, "browser visit")

  defp count_label(1, label), do: "1 #{label}"
  defp count_label(count, label), do: "#{count} #{pluralize(label, count)}"

  defp pluralize(label, 1), do: label
  defp pluralize("Apple Note", _count), do: "Apple Notes"
  defp pluralize("iMessage", _count), do: "iMessages"
  defp pluralize(label, _count), do: "#{label}s"

  defp latest_device_seen_at(device_entries) do
    device_entries
    |> Enum.map(fn {device, _stats} ->
      device.last_seen_at || device.updated_at || device.inserted_at
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&timestamp_sort_value/1, fn -> nil end)
  end

  defp readiness_item(
         %{"provider" => provider, "service" => service, "label" => label},
         providers
       )
       when is_binary(provider) do
    provider_card = Map.get(providers, provider)
    service_card = find_provider_service(provider_card, service)
    status = readiness_status(provider_card, service_card, service)
    connected? = status in [:connected, :partial]

    %{
      provider: provider,
      service: service,
      label: readiness_display_label(provider, service, label, service_card),
      status: status,
      connected?: connected?,
      connect_path: readiness_connect_path(provider_card, service_card),
      details: readiness_details(provider_card, service_card, service)
    }
  end

  defp readiness_item(_requirement, _providers), do: nil

  defp readiness_status(nil, _service_card, _service), do: :disconnected
  defp readiness_status(provider_card, nil, nil), do: provider_card.status
  defp readiness_status(_provider_card, nil, _service), do: :disconnected
  defp readiness_status(_provider_card, service_card, _service), do: service_card.status

  defp readiness_connect_path(_provider_card, %{connect_url: connect_url})
       when is_binary(connect_url),
       do: connect_url

  defp readiness_connect_path(%{connect_url: connect_url}, _service_card)
       when is_binary(connect_url),
       do: connect_url

  defp readiness_connect_path(%{provider: provider}, _service_card) when is_binary(provider),
    do: "/connectors/#{provider}"

  defp readiness_connect_path(_provider_card, _service_card), do: "/connectors"

  defp readiness_details(_provider_card, _service_card, nil), do: nil

  defp readiness_details(_provider_card, nil, _service), do: "Connect this Google service."

  defp readiness_details(_provider_card, service_card, _service) do
    service_card[:description]
  end

  defp find_provider_service(_provider_card, nil), do: nil
  defp find_provider_service(nil, _service), do: nil

  defp find_provider_service(provider_card, service) when is_binary(service) do
    provider_card
    |> Map.get(:services, [])
    |> Enum.find(&(&1.id == service))
  end

  defp readiness_label("google", "gmail"), do: "Gmail"
  defp readiness_label("google", "calendar"), do: "Google Calendar"
  defp readiness_label("telegram", _service), do: "Telegram"
  defp readiness_label(provider, nil), do: humanize_provider(provider)

  defp readiness_label(provider, service),
    do: "#{humanize_provider(provider)} #{humanize_provider(service)}"

  defp readiness_display_label("google", "gmail", _label, _service_card), do: "Gmail"

  defp readiness_display_label("google", "calendar", _label, _service_card),
    do: "Google Calendar"

  defp readiness_display_label("google", service, _label, %{label: label})
       when is_binary(service) and is_binary(label) and label != "",
       do: label

  defp readiness_display_label("google", service, _label, _service_card),
    do: readiness_label("google", service)

  defp readiness_display_label(_provider, _service, label, _service_card)
       when is_binary(label) and label != "",
       do: label

  defp readiness_display_label(provider, service, _label, _service_card),
    do: readiness_label(provider, service)

  defp humanize_provider(value) when is_binary(value) do
    value
    |> String.replace(["_", "-"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_provider(value), do: to_string(value)

  defp normalize_required_connectors(required_connectors) when is_map(required_connectors) do
    required_connectors
    |> Enum.flat_map(fn {provider, requirements} ->
      normalize_provider_requirements(to_string(provider), requirements)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_required_connectors(_required_connectors), do: []

  defp normalize_provider_requirements(provider, requirements) when is_list(requirements) do
    Enum.map(requirements, fn
      %{"service" => service, "label" => label} ->
        %{"provider" => provider, "service" => normalize_service(service), "label" => label}

      %{service: service, label: label} ->
        %{"provider" => provider, "service" => normalize_service(service), "label" => label}

      _ ->
        nil
    end)
  end

  defp normalize_provider_requirements(provider, requirements) when is_map(requirements) do
    Enum.flat_map(requirements, fn
      {"provider", true} ->
        [%{"provider" => provider, "service" => nil, "label" => nil}]

      {service, true} ->
        [%{"provider" => provider, "service" => normalize_service(service), "label" => nil}]

      {service, %{"label" => label}} ->
        [%{"provider" => provider, "service" => normalize_service(service), "label" => label}]

      _other ->
        []
    end)
  end

  defp normalize_provider_requirements(provider, true),
    do: [%{"provider" => provider, "service" => nil, "label" => nil}]

  defp normalize_provider_requirements(_provider, _requirements), do: []

  defp normalize_service(nil), do: nil
  defp normalize_service(""), do: nil
  defp normalize_service(service), do: to_string(service)

  defp telegram_unlinked_details(user_id) do
    case TelegramLink.bot_username() do
      nil -> ["Not linked yet. Send /start #{user_id} to your bot chat."]
      username -> ["Not linked yet. Open @#{username} or send /start #{user_id} to the bot."]
    end
  end

  defp notion_card(user_id, token, account, return_to, timezone_info) do
    configured? = Notion.configured?()

    account_entry =
      single_oauth_account_entry(
        user_id,
        token,
        account,
        return_to,
        "/auth/notion",
        &notion_account_label/1
      )

    %{
      id: "notion",
      provider: "notion",
      label: "Notion",
      description:
        "Connect your Notion workspace so Maraithon can use it as context for future work.",
      status: provider_status(configured?, token, account),
      configured?: configured?,
      updated_at: token && token.updated_at,
      disconnectable?: not is_nil(token),
      connect_url: auth_url("/auth/notion", user_id, return_to),
      disconnect_label: "Disconnect Notion",
      refresh_token_status: refresh_token_status(token, account_entry),
      details:
        provider_details(
          token,
          [
            metadata_value(token, ["workspace_name"])
          ],
          timezone_info
        ),
      services: [],
      accounts: maybe_single_account_entry(account_entry)
    }
    |> enrich_provider_setup()
  end

  defp notaui_card(user_id, token, account, return_to, timezone_info) do
    configured? = Notaui.configured?()

    account_entry =
      single_oauth_account_entry(
        user_id,
        token,
        account,
        return_to,
        "/auth/notaui",
        &notaui_account_label/1
      )

    %{
      id: "notaui",
      provider: "notaui",
      label: "Notaui",
      description: "Connect your Notaui workspace so Maraithon can read and update tasks.",
      status: provider_status(configured?, token, account),
      configured?: configured?,
      updated_at: token && token.updated_at,
      disconnectable?: not is_nil(token),
      connect_url: auth_url("/auth/notaui", user_id, return_to),
      disconnect_label: "Disconnect Notaui",
      refresh_token_status: refresh_token_status(token, account_entry),
      details: provider_details(token, notaui_details(token, account), timezone_info),
      services: [],
      accounts: maybe_single_account_entry(account_entry)
    }
    |> enrich_provider_setup()
  end

  defp auth_url(path, user_id, return_to, extra_params \\ []) do
    params =
      [{"user_id", user_id}, {"return_to", return_to}]
      |> Kernel.++(Enum.map(extra_params, fn {key, value} -> {Atom.to_string(key), value} end))
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)

    "#{path}?#{URI.encode_query(params)}"
  end

  defp google_service_connected?(nil, _required_scopes), do: false

  defp google_service_connected?(token, required_scopes) do
    MapSet.subset?(MapSet.new(required_scopes), token_scope_set(token))
  end

  defp google_service_status(false, _tokens, _connected?), do: :not_configured
  defp google_service_status(true, [], _connected?), do: :disconnected
  defp google_service_status(true, _tokens, true), do: :connected
  defp google_service_status(true, _tokens, false), do: :missing_scope

  defp provider_status(false, _token, _account), do: :not_configured
  defp provider_status(true, nil, _account), do: :disconnected

  defp provider_status(true, _token, account) do
    if reauth_required_account?(account), do: :needs_refresh, else: :connected
  end

  defp connected_account?(%ConnectedAccount{status: "connected"}), do: true
  defp connected_account?(_account), do: false

  defp enforce_telegram_first(%{provider: "telegram"} = provider, _telegram_connected?) do
    provider
    |> Map.put(:requires_telegram?, false)
    |> Map.put(:connect_blocked?, false)
    |> Map.put(:connect_block_reason, nil)
  end

  defp enforce_telegram_first(%{provider: "desktop"} = provider, _telegram_connected?) do
    provider
    |> Map.put(:requires_telegram?, false)
    |> Map.put(:connect_blocked?, false)
    |> Map.put(:connect_block_reason, nil)
  end

  defp enforce_telegram_first(provider, true) do
    provider
    |> Map.put(:requires_telegram?, true)
    |> Map.put(:connect_blocked?, false)
    |> Map.put(:connect_block_reason, nil)
  end

  defp enforce_telegram_first(provider, false) do
    provider
    |> Map.put(:requires_telegram?, true)
    |> Map.put(:connect_blocked?, true)
    |> Map.put(:connect_block_reason, "Connect Telegram first")
  end

  defp google_details([]), do: ["Not connected yet."]

  defp google_details(tokens) when is_list(tokens) do
    ["#{length(tokens)} Google #{account_word(length(tokens))} linked"]
  end

  defp provider_details(nil, _items, _timezone_info), do: ["Not connected yet."]

  defp provider_details(token, items, timezone_info) do
    connected_at = "Last updated #{format_datetime(token.updated_at, timezone_info)}"

    [connected_at | items]
    |> Enum.reject(&is_nil/1)
  end

  defp telegram_chat_detail(username) when is_binary(username) and username != "",
    do: "Delivery linked to @#{username}"

  defp telegram_chat_detail(_username), do: "Telegram delivery linked"

  defp serialize_token(%Token{} = token) do
    %{
      provider: token.provider,
      updated_at: token.updated_at,
      expires_at: token.expires_at,
      scopes: token.scopes,
      metadata: token.metadata
    }
  end

  defp token_scopes(nil), do: []
  defp token_scopes(%Token{scopes: scopes}) when is_list(scopes), do: scopes
  defp token_scopes(_token), do: []

  defp token_scope_set(token) do
    token
    |> token_scopes()
    |> MapSet.new()
  end

  defp metadata_value(nil, _path), do: nil

  defp metadata_value(%Token{metadata: metadata}, path) when is_list(path) do
    get_in(metadata, path) || get_in(metadata, Enum.map(path, &string_or_existing_atom/1))
  rescue
    ArgumentError -> nil
  end

  defp string_or_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(_value), do: []

  defp google_account_entries(user_id, tokens, account_by_provider, return_to, timezone_info)
       when is_binary(user_id) and is_list(tokens) and is_map(account_by_provider) do
    reconnect_url =
      auth_url("/auth/google", user_id, return_to, scopes: "gmail,calendar,contacts")

    tokens
    |> Enum.filter(&google_provider?(&1.provider))
    |> Enum.map(fn token ->
      status = token_account_status(token, account_by_provider)

      %{
        provider: token.provider,
        account: google_account_label(token),
        updated_at: token_or_account_updated_at(token, account_by_provider),
        status: status,
        status_note: token_account_status_note(token, account_by_provider),
        refresh_token_status: refresh_token_status([token], [%{status: status}]),
        expires_at: token.expires_at,
        details: google_account_details(token, timezone_info),
        reconnect_url: reconnect_url,
        needs_reconnect?: status == :needs_refresh
      }
    end)
    |> Enum.sort_by(&timestamp_sort_value(&1.updated_at), :desc)
  end

  defp google_account_label(%Token{} = token) do
    normalize_text(metadata_value(token, ["account_email"])) ||
      normalize_text(metadata_value(token, ["email"])) ||
      google_provider_suffix(token.provider) ||
      "Google account"
  end

  defp google_account_label(_token), do: "Google account"

  defp google_account_details(%Token{} = token, timezone_info) do
    scopes = token_scopes(token)
    enabled_services = google_enabled_service_labels(token)

    [
      if(enabled_services != [], do: "Enabled: #{Enum.join(enabled_services, ", ")}"),
      if(scopes != [], do: "#{length(scopes)} Google #{permission_word(length(scopes))} granted"),
      if(token.expires_at,
        do: "Access expires #{format_datetime(token.expires_at, timezone_info)}"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp google_account_details(_token, _timezone_info), do: []

  defp google_enabled_service_labels(%Token{} = token) do
    @google_services
    |> Enum.filter(fn service ->
      google_service_connected?(token, Google.scopes_for([service.id]))
    end)
    |> Enum.map(& &1.label)
  end

  defp google_provider_suffix("google"), do: nil

  defp google_provider_suffix(provider) when is_binary(provider) do
    case String.split(provider, ":", parts: 2) do
      ["google", suffix] ->
        normalize_text(suffix)

      _ ->
        nil
    end
  end

  defp google_provider_suffix(_provider), do: nil

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_value), do: nil

  defp normalize_metadata_map(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata_map(_metadata), do: %{}

  defp fetch_map_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp fetch_map_value(_map, _key), do: nil

  defp google_provider?("google"), do: true

  defp google_provider?(provider) when is_binary(provider) do
    String.starts_with?(provider, "google:")
  end

  defp google_provider?(_provider), do: false

  defp slack_provider?(provider) when is_binary(provider) do
    String.starts_with?(provider, "slack:")
  end

  defp slack_provider?(_provider), do: false

  defp slack_bot_token(tokens) when is_list(tokens) do
    Enum.find(tokens, &slack_bot_provider?(&1.provider))
  end

  defp slack_user_tokens(tokens) when is_list(tokens) do
    Enum.filter(tokens, &slack_user_provider?(&1.provider))
  end

  defp slack_bot_provider?(provider) when is_binary(provider) do
    Regex.match?(~r/^slack:[^:]+$/, provider)
  end

  defp slack_bot_provider?(_provider), do: false

  defp slack_user_provider?(provider) when is_binary(provider) do
    Regex.match?(~r/^slack:[^:]+:user:[^:]+$/, provider)
  end

  defp slack_user_provider?(_provider), do: false

  defp slack_same_workspace_provider?(candidate_provider, provider)
       when is_binary(candidate_provider) and is_binary(provider) do
    team_id = slack_team_id_from_provider(provider)

    not is_nil(team_id) and slack_team_id_from_provider(candidate_provider) == team_id
  end

  defp slack_same_workspace_provider?(_candidate_provider, _provider), do: false

  defp slack_team_id(%Token{} = token) do
    normalize_text(metadata_value(token, ["team_id"])) ||
      slack_team_id_from_provider(token.provider)
  end

  defp slack_team_id(_token), do: nil

  defp slack_team_id_from_provider(provider) when is_binary(provider) do
    case String.split(provider, ":") do
      ["slack", team_id] -> normalize_text(team_id)
      ["slack", team_id, "user", _user_id] -> normalize_text(team_id)
      _ -> nil
    end
  end

  defp slack_team_id_from_provider(_provider), do: nil

  defp slack_account_entries(user_id, tokens, account_by_provider, return_to)
       when is_binary(user_id) and is_list(tokens) and is_map(account_by_provider) do
    reconnect_url = auth_url("/auth/slack", user_id, return_to)

    tokens
    |> Enum.filter(&slack_provider?(&1.provider))
    |> Enum.group_by(&slack_team_id/1)
    |> Enum.reject(fn {team_id, _tokens} -> is_nil(team_id) end)
    |> Enum.map(fn {team_id, workspace_tokens} ->
      slack_workspace_account_entry(team_id, workspace_tokens, account_by_provider, reconnect_url)
    end)
    |> Enum.sort_by(&timestamp_sort_value(&1.updated_at), :desc)
  end

  defp slack_workspace_account_entry(team_id, tokens, account_by_provider, reconnect_url)
       when is_binary(team_id) and is_list(tokens) do
    bot_token = slack_bot_token(tokens)
    user_tokens = slack_user_tokens(tokens)
    primary_token = bot_token || List.first(user_tokens)
    token_statuses = Enum.map(tokens, &token_account_status(&1, account_by_provider))
    status = slack_workspace_status(bot_token, user_tokens, token_statuses)

    %{
      provider: slack_workspace_provider(team_id, primary_token),
      account: slack_workspace_label(primary_token, team_id),
      updated_at: latest_token_or_account_updated_at(tokens, account_by_provider),
      status: status,
      status_note: slack_workspace_status_note(status, bot_token, user_tokens, token_statuses),
      refresh_token_status:
        refresh_token_status(tokens, Enum.map(token_statuses, &%{status: &1})),
      details: slack_workspace_details(bot_token, user_tokens),
      reconnect_url: reconnect_url,
      needs_reconnect?: status in [:needs_refresh, :partial, :missing_scope]
    }
  end

  defp slack_workspace_provider(team_id, %Token{provider: provider})
       when is_binary(provider) do
    if slack_bot_provider?(provider), do: provider, else: "slack:#{team_id}"
  end

  defp slack_workspace_provider(team_id, _token), do: "slack:#{team_id}"

  defp slack_workspace_label(%Token{} = token, team_id) do
    normalize_text(metadata_value(token, ["team_name"])) ||
      normalize_text(team_id) ||
      "Slack workspace"
  end

  defp slack_workspace_label(_token, team_id),
    do: normalize_text(team_id) || "Slack workspace"

  defp slack_workspace_status(bot_token, user_tokens, token_statuses) do
    cond do
      :needs_refresh in token_statuses ->
        :needs_refresh

      is_nil(bot_token) ->
        :partial

      user_tokens == [] ->
        :partial

      Enum.any?(user_tokens, &token_has_scope?(&1, "chat:write")) ->
        :connected

      true ->
        :missing_scope
    end
  end

  defp slack_workspace_status_note(:needs_refresh, _bot_token, _user_tokens, token_statuses) do
    if Enum.any?(token_statuses, &(&1 == :needs_refresh)) do
      "Reconnect Slack so Maraithon can keep reading and posting there."
    else
      "Reconnect Slack to refresh access."
    end
  end

  defp slack_workspace_status_note(:partial, nil, _user_tokens, _token_statuses),
    do: "Reconnect Slack so Maraithon can receive channel activity."

  defp slack_workspace_status_note(:partial, _bot_token, [], _token_statuses),
    do: "Reconnect Slack so Maraithon can read DMs and send replies when you approve them."

  defp slack_workspace_status_note(:missing_scope, _bot_token, _user_tokens, _token_statuses),
    do: "Reconnect Slack so Maraithon can send replies when you approve them."

  defp slack_workspace_status_note(_status, _bot_token, _user_tokens, _token_statuses),
    do: "Healthy"

  defp slack_workspace_details(bot_token, user_tokens) do
    [
      if(bot_token, do: "Channel events and mentions enabled"),
      slack_user_grant_detail(user_tokens)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp slack_user_grant_detail([]), do: nil

  defp slack_user_grant_detail(user_tokens) do
    if Enum.any?(user_tokens, &token_has_scope?(&1, "chat:write")) do
      "DMs, private context, and posting as you enabled"
    else
      "DMs and private context enabled"
    end
  end

  defp token_has_scope?(%Token{} = token, scope) when is_binary(scope) do
    token
    |> token_scopes()
    |> Enum.any?(&(&1 == scope))
  end

  defp token_has_scope?(_token, _scope), do: false

  defp slack_service_status(false, _token, _account), do: :not_configured
  defp slack_service_status(true, nil, _account), do: :disconnected

  defp slack_service_status(true, _token, account) do
    if reauth_required_account?(account), do: :needs_refresh, else: :connected
  end

  defp single_oauth_account_entry(
         user_id,
         %Token{} = token,
         account,
         return_to,
         connect_path,
         label_fun
       )
       when is_binary(user_id) and is_binary(return_to) and is_binary(connect_path) and
              is_function(label_fun, 1) do
    account_by_provider = %{token.provider => account}
    status = token_account_status(token, account_by_provider)

    %{
      provider: token.provider,
      account: label_fun.(token),
      updated_at: token_or_account_updated_at(token, account_by_provider),
      status: status,
      status_note: token_account_status_note(token, account_by_provider),
      reconnect_url: auth_url(connect_path, user_id, return_to),
      needs_reconnect?: status == :needs_refresh
    }
  end

  defp single_oauth_account_entry(
         _user_id,
         _token,
         _account,
         _return_to,
         _connect_path,
         _label_fun
       ),
       do: nil

  defp maybe_single_account_entry(nil), do: []
  defp maybe_single_account_entry(entry), do: [entry]

  defp token_account_status(%Token{} = token, account_by_provider)
       when is_map(account_by_provider) do
    account = Map.get(account_by_provider, token.provider)

    cond do
      reauth_required_account?(account) -> :needs_refresh
      token_expired_without_refresh?(token) -> :needs_refresh
      true -> :connected
    end
  end

  defp token_account_status(_token, _account_by_provider), do: :disconnected

  defp token_account_status_note(%Token{} = token, account_by_provider)
       when is_map(account_by_provider) do
    account = Map.get(account_by_provider, token.provider)
    reason = account_error_reason(account)

    cond do
      reauth_required_account?(account) and reason == "oauth_missing_refresh_token" ->
        reconnect_account_status_note()

      reauth_required_account?(account) ->
        reconnect_account_status_note()

      token_expired_without_refresh?(token) ->
        reconnect_account_status_note()

      true ->
        "Healthy"
    end
  end

  defp token_account_status_note(_token, _account_by_provider), do: "Healthy"

  defp reconnect_account_status_note,
    do: "Reconnect this account so Maraithon can keep this context current."

  defp token_or_account_updated_at(%Token{} = token, account_by_provider)
       when is_map(account_by_provider) do
    account = Map.get(account_by_provider, token.provider)
    account_updated_at = account && account.updated_at

    [token.updated_at, account_updated_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&timestamp_sort_value/1, fn -> nil end)
  end

  defp token_or_account_updated_at(%Token{} = token, _account_by_provider), do: token.updated_at
  defp token_or_account_updated_at(_token, _account_by_provider), do: nil

  defp latest_token_or_account_updated_at(tokens, account_by_provider)
       when is_list(tokens) and is_map(account_by_provider) do
    tokens
    |> Enum.map(&token_or_account_updated_at(&1, account_by_provider))
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&timestamp_sort_value/1, fn -> nil end)
  end

  defp reauth_required_account?(%ConnectedAccount{status: "error"} = account) do
    account_error_reason(account) in ["oauth_reauth_required", "oauth_missing_refresh_token"]
  end

  defp reauth_required_account?(_account), do: false

  defp account_error_reason(nil), do: nil

  defp account_error_reason(%ConnectedAccount{metadata: metadata}) do
    metadata
    |> normalize_metadata_map()
    |> fetch_map_value("last_error")
    |> case do
      value when is_map(value) -> fetch_map_value(value, "reason")
      _ -> nil
    end
    |> normalize_text()
  end

  defp token_expired_without_refresh?(%Token{expires_at: nil}), do: false

  defp token_expired_without_refresh?(%Token{
         expires_at: expires_at,
         refresh_token: refresh_token
       })
       when not is_nil(expires_at) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt and not present?(refresh_token)
  rescue
    ArgumentError -> false
  end

  defp token_expired_without_refresh?(_token), do: false

  defp refresh_token_status(tokens, account_entries) when is_list(tokens) do
    cond do
      tokens == [] ->
        :missing

      Enum.any?(account_entries, &(&1.status == :needs_refresh)) ->
        :inactive

      Enum.any?(tokens, &token_expired_without_refresh?/1) ->
        :inactive

      Enum.any?(tokens, &(present?(&1.refresh_token) and not token_expired_without_refresh?(&1))) ->
        :active

      Enum.all?(tokens, &is_nil(&1.expires_at)) ->
        :not_required

      true ->
        :missing
    end
  end

  defp refresh_token_status(%Token{} = token, nil),
    do: refresh_token_status([token], [])

  defp refresh_token_status(%Token{} = token, account_entry),
    do: refresh_token_status([token], [account_entry])

  defp refresh_token_status(_token, _account_entry), do: :missing

  defp github_account_label(%Token{} = token) do
    login =
      token
      |> metadata_value(["login"])
      |> normalize_text()

    email =
      token
      |> metadata_value(["email"])
      |> normalize_text()

    cond do
      present?(login) and present?(email) -> "@#{login} (#{email})"
      present?(login) -> "@#{login}"
      present?(email) -> email
      true -> "GitHub account"
    end
  end

  defp github_account_label(_token), do: "GitHub account"

  defp linear_account_label(%Token{} = token) do
    first_team_name =
      token
      |> metadata_value(["teams"])
      |> normalize_list()
      |> Enum.find_value(fn
        %{"name" => name} when is_binary(name) and name != "" -> name
        _ -> nil
      end)

    normalize_text(first_team_name) || "Linear workspace"
  end

  defp linear_account_label(_token), do: "Linear workspace"

  defp notion_account_label(%Token{} = token) do
    normalize_text(metadata_value(token, ["workspace_name"])) || "Notion workspace"
  end

  defp notion_account_label(_token), do: "Notion workspace"

  defp notaui_account_label(%Token{} = token) do
    normalize_text(metadata_value(token, ["default_account_label"])) ||
      normalize_text(metadata_value(token, ["default_account_id"])) ||
      normalize_text(metadata_value(token, ["subject"])) ||
      "Notaui workspace"
  end

  defp notaui_account_label(_token), do: "Notaui workspace"

  defp notaui_details(token, account) do
    [
      notaui_default_account_detail(token, account),
      notaui_account_count_detail(token, account),
      notaui_discovery_detail(token, account),
      notaui_sync_endpoint_detail(token, account),
      permission_summary(token_scopes(token), "Notaui")
    ]
  end

  defp notaui_default_account_detail(token, account) do
    default_label =
      provider_snapshot_value(account, token, "default_account_label") ||
        provider_snapshot_value(account, token, "default_account_id")

    if present?(default_label), do: "Default account: #{default_label}"
  end

  defp notaui_account_count_detail(token, account) do
    case provider_snapshot_value(account, token, "account_count") |> normalize_integer() do
      count when is_integer(count) and count > 0 ->
        "Found #{count} Notaui #{pluralize("account", count)} Maraithon can use."

      0 ->
        "Notaui connected, but it did not return any accounts Maraithon can use. Reconnect Notaui if accounts are missing."

      _ ->
        nil
    end
  end

  defp notaui_discovery_detail(token, account) do
    if provider_snapshot_value(account, token, "discovery_error") do
      "Account discovery could not be completed. Reconnect Notaui if account access looks incomplete."
    end
  end

  defp notaui_sync_endpoint_detail(token, account) do
    if present?(provider_snapshot_value(account, token, "mcp_url")) do
      "Task sync endpoint connected"
    end
  end

  defp permission_summary([], _provider), do: nil

  defp permission_summary(scopes, provider) when is_list(scopes) and is_binary(provider) do
    "#{length(scopes)} #{provider} #{permission_word(length(scopes))} granted"
  end

  defp permission_summary(_scopes, _provider), do: nil

  defp provider_snapshot_value(account, token, key) when is_binary(key) do
    account_metadata_value(account, key) || metadata_value(token, [key])
  end

  defp account_metadata_value(%ConnectedAccount{metadata: metadata}, key) when is_binary(key) do
    metadata
    |> normalize_metadata_map()
    |> fetch_map_value(key)
  end

  defp account_metadata_value(_account, _key), do: nil

  defp latest_updated_at([]), do: nil

  defp latest_updated_at(tokens) when is_list(tokens) do
    tokens
    |> Enum.map(& &1.updated_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&timestamp_sort_value/1, fn -> nil end)
  end

  defp timestamp_sort_value(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp timestamp_sort_value(%NaiveDateTime{} = value) do
    case DateTime.from_naive(value, "Etc/UTC") do
      {:ok, datetime} -> DateTime.to_unix(datetime, :microsecond)
      {:error, _reason} -> 0
    end
  end

  defp timestamp_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      {:error, _reason} -> 0
    end
  end

  defp timestamp_sort_value(_value), do: 0

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp account_word(1), do: "account"
  defp account_word(_count), do: "accounts"

  defp permission_word(1), do: "permission"
  defp permission_word(_count), do: "permissions"

  defp provider_sort_key(%Token{provider: provider}) do
    cond do
      google_provider?(provider) -> 0
      provider == "github" -> 1
      slack_provider?(provider) -> 2
      provider == "linear" -> 3
      provider == "notion" -> 4
      provider == "notaui" -> 5
      true -> 99
    end
  end

  defp mark_unavailable(provider) do
    provider
    |> Map.put(:status, :unknown)
    |> Map.put(:refresh_token_status, :unknown)
    |> Map.update!(:details, fn details ->
      [
        "App status could not be checked. Refresh this page before changing this connection."
        | details
      ]
    end)
    |> Map.update!(:services, fn services ->
      Enum.map(services, &Map.put(&1, :status, :unknown))
    end)
    |> Map.update(:accounts, [], fn accounts ->
      Enum.map(accounts, &Map.put(&1, :status, :unknown))
    end)
  end

  defp enrich_provider_setup(provider) do
    setup = provider_setup(provider.provider)
    required_envs = Enum.filter(setup.env_requirements, & &1.required?)

    setup_status =
      cond do
        required_envs == [] -> :configured
        Enum.all?(required_envs, & &1.present?) -> :configured
        true -> :incomplete
      end

    Map.merge(provider, %{
      logo: setup.logo,
      permissions: setup.permissions,
      callback_urls: setup.callback_urls,
      env_requirements: setup.env_requirements,
      setup_notes: setup.setup_notes,
      setup_status: setup_status
    })
  end

  defp provider_setup("google") do
    oauth_callback = callback_url("/auth/google/callback")
    calendar_webhook = callback_url("/webhooks/google/calendar")
    gmail_webhook = callback_url("/webhooks/google/gmail")

    %{
      logo: :google,
      permissions: [
        "Gmail read-only mailbox access",
        "Google Calendar read-only event access",
        "Google Contacts read-only People API access"
      ],
      callback_urls: [
        %{label: "App return URL", url: oauth_callback, required?: true},
        %{label: "Calendar webhook callback", url: calendar_webhook, required?: false},
        %{label: "Gmail Pub/Sub push callback", url: gmail_webhook, required?: false}
      ],
      env_requirements: [
        env_requirement(
          "GOOGLE_CLIENT_ID",
          config_value(:google, :client_id),
          "Google app client ID",
          true
        ),
        env_requirement(
          "GOOGLE_CLIENT_SECRET",
          config_value(:google, :client_secret),
          "Google app client secret",
          true
        ),
        env_requirement(
          "GOOGLE_REDIRECT_URI",
          config_value(:google, :redirect_uri),
          "Must match the Google app return URL",
          true,
          oauth_callback
        ),
        env_requirement(
          "GOOGLE_CALENDAR_WEBHOOK_URL",
          config_value(:google, :calendar_webhook_url),
          "Used when registering Calendar watches",
          false,
          calendar_webhook
        ),
        env_requirement(
          "GOOGLE_PUBSUB_TOPIC",
          config_value(:google, :pubsub_topic),
          "Pub/Sub topic used for Gmail push delivery",
          false
        )
      ],
      setup_notes: [
        "Register the app return URL in Google Cloud Console.",
        "Set the Google permission screen publishing status to Production to avoid short-lived testing access.",
        "If you want Calendar watches, point GOOGLE_CALENDAR_WEBHOOK_URL at the calendar webhook callback.",
        "If you want Gmail push, grant Gmail Pub/Sub push access to the Gmail webhook callback."
      ]
    }
  end

  defp provider_setup("github") do
    %{
      logo: :github,
      permissions: [
        "repo",
        "read:org",
        "notifications",
        "user:email"
      ],
      callback_urls: [
        %{label: "App return URL", url: callback_url("/auth/github/callback"), required?: true},
        %{label: "Webhook callback", url: callback_url("/webhooks/github"), required?: false}
      ],
      env_requirements: [
        env_requirement(
          "GITHUB_CLIENT_ID",
          config_value(:github, :client_id),
          "GitHub app client ID",
          true
        ),
        env_requirement(
          "GITHUB_CLIENT_SECRET",
          config_value(:github, :client_secret),
          "GitHub app client secret",
          true
        ),
        env_requirement(
          "GITHUB_REDIRECT_URI",
          config_value(:github, :redirect_uri),
          "Must match the GitHub app return URL",
          true,
          callback_url("/auth/github/callback")
        ),
        env_requirement(
          "GITHUB_WEBHOOK_SECRET",
          config_value(:github, :webhook_secret),
          "Used to verify repository webhooks",
          false
        ),
        env_requirement(
          "GITHUB_ACCESS_TOKEN",
          config_value(:github, :api_token),
          "Optional fallback token for repo actions when no user grant is provided",
          false
        )
      ],
      setup_notes: [
        "Create a GitHub App connection and register the app return URL.",
        "For repo events, add a repository or org webhook pointing at the GitHub webhook callback.",
        "Agents can use a per-user GitHub grant or the optional fallback access token."
      ]
    }
  end

  defp provider_setup("slack") do
    oauth_callback = callback_url("/auth/slack/callback")
    events_callback = callback_url("/webhooks/slack")

    %{
      logo: :slack,
      permissions: [
        "Read channel and thread history",
        "Read DM and MPIM history with user scopes",
        "Post messages and thread replies with the connected user's Slack token",
        "Process Slack Events API webhooks for near-real-time updates"
      ],
      callback_urls: [
        %{label: "App return URL", url: oauth_callback, required?: true},
        %{label: "Events callback", url: events_callback, required?: true}
      ],
      env_requirements: [
        env_requirement(
          "SLACK_CLIENT_ID",
          config_value(:slack, :client_id),
          "Slack app client ID",
          true
        ),
        env_requirement(
          "SLACK_CLIENT_SECRET",
          config_value(:slack, :client_secret),
          "Slack app client secret",
          true
        ),
        env_requirement(
          "SLACK_REDIRECT_URI",
          config_value(:slack, :redirect_uri),
          "Must match the Slack app return URL",
          true,
          oauth_callback
        ),
        env_requirement(
          "SLACK_SIGNING_SECRET",
          config_value(:slack, :signing_secret),
          "Used to verify Slack Events API signatures",
          true
        )
      ],
      setup_notes: [
        "Enable background access rotation in your Slack app so Maraithon can stay connected.",
        "Install the app to each workspace and request both bot scopes and user scopes for read/write as user.",
        "Configure Event Subscriptions with the events callback URL and enable message events for channels and DMs.",
        "After install, reconnect once if scopes change so Maraithon stores the updated grant."
      ]
    }
  end

  defp provider_setup("linear") do
    %{
      logo: :linear,
      permissions: [
        "read",
        "write",
        "issues:create",
        "comments:create"
      ],
      callback_urls: [
        %{label: "App return URL", url: callback_url("/auth/linear/callback"), required?: true},
        %{label: "Webhook callback", url: callback_url("/webhooks/linear"), required?: false}
      ],
      env_requirements: [
        env_requirement(
          "LINEAR_CLIENT_ID",
          config_value(:linear, :client_id),
          "Linear app client ID",
          true
        ),
        env_requirement(
          "LINEAR_CLIENT_SECRET",
          config_value(:linear, :client_secret),
          "Linear app client secret",
          true
        ),
        env_requirement(
          "LINEAR_REDIRECT_URI",
          config_value(:linear, :redirect_uri),
          "Must match the Linear app return URL",
          true,
          callback_url("/auth/linear/callback")
        ),
        env_requirement(
          "LINEAR_WEBHOOK_SECRET",
          config_value(:linear, :webhook_secret),
          "Used to verify Linear webhooks",
          false
        )
      ],
      setup_notes: [
        "Register the redirect URI in Linear.",
        "If you want inbound issue events, configure a Linear webhook pointed at the webhook callback."
      ]
    }
  end

  defp provider_setup("notion") do
    %{
      logo: :notion,
      permissions: [
        "Workspace permissions are configured in the Notion integration dashboard."
      ],
      callback_urls: [
        %{label: "App return URL", url: callback_url("/auth/notion/callback"), required?: true}
      ],
      env_requirements: [
        env_requirement(
          "NOTION_CLIENT_ID",
          config_value(:notion, :client_id),
          "Notion public integration client ID",
          true
        ),
        env_requirement(
          "NOTION_CLIENT_SECRET",
          config_value(:notion, :client_secret),
          "Notion public integration client secret",
          true
        ),
        env_requirement(
          "NOTION_REDIRECT_URI",
          config_value(:notion, :redirect_uri),
          "Must match the Notion app return URL",
          true,
          callback_url("/auth/notion/callback")
        )
      ],
      setup_notes: [
        "Create a public Notion integration and register the callback URL.",
        "Workspace-level permissions are chosen in Notion, not in the query string."
      ]
    }
  end

  defp provider_setup("notaui") do
    oauth_callback = callback_url("/auth/notaui/callback")

    %{
      logo: :notaui,
      permissions: [
        "Read and update Notaui tasks",
        "Read and update Notaui projects",
        "Write Notaui tags",
        "Call Notaui MCP tools with a user bearer token"
      ],
      callback_urls: [
        %{label: "App return URL", url: oauth_callback, required?: true}
      ],
      env_requirements: [
        env_requirement(
          "NOTAUI_CLIENT_ID",
          config_value(:notaui, :client_id),
          "Notaui app client ID",
          true
        ),
        env_requirement(
          "NOTAUI_CLIENT_SECRET",
          config_value(:notaui, :client_secret),
          "Notaui app client secret",
          true
        ),
        env_requirement(
          "NOTAUI_REDIRECT_URI",
          config_value(:notaui, :redirect_uri),
          "Must match the Notaui app return URL",
          true,
          oauth_callback
        ),
        env_requirement(
          "NOTAUI_SCOPE",
          config_value(:notaui, :scope),
          "Requested Notaui permissions for this app connection",
          false,
          "tasks:read tasks:write projects:read projects:write tags:write"
        ),
        env_requirement(
          "NOTAUI_AUTH_URL",
          config_value(:notaui, :auth_url),
          "Override for the Notaui authorization endpoint",
          false,
          "https://api.notaui.com/oauth/authorize"
        ),
        env_requirement(
          "NOTAUI_TOKEN_URL",
          config_value(:notaui, :token_url),
          "Override for the Notaui token endpoint",
          false,
          "https://api.notaui.com/oauth/token"
        ),
        env_requirement(
          "NOTAUI_MCP_URL",
          config_value(:notaui, :mcp_url),
          "Bearer-token MCP endpoint used after connect",
          false,
          "https://api.notaui.com/mcp"
        ),
        env_requirement(
          "NOTAUI_ISSUER",
          config_value(:notaui, :issuer),
          "Issuer used for Notaui connection metadata and diagnostics",
          false,
          "https://api.notaui.com"
        ),
        env_requirement(
          "NOTAUI_REGISTER_URL",
          config_value(:notaui, :register_url),
          "Optional Notaui dynamic registration endpoint",
          false,
          "https://api.notaui.com/oauth/register"
        ),
        env_requirement(
          "NOTAUI_AUTH_SERVER_METADATA_URL",
          config_value(:notaui, :auth_server_metadata_url),
          "Optional Notaui authorization-server metadata endpoint",
          false,
          "https://api.notaui.com/.well-known/oauth-authorization-server"
        ),
        env_requirement(
          "NOTAUI_PROTECTED_RESOURCE_METADATA_URL",
          config_value(:notaui, :protected_resource_metadata_url),
          "Optional Notaui protected-resource metadata endpoint",
          false,
          "https://api.notaui.com/.well-known/oauth-protected-resource"
        )
      ],
      setup_notes: [
        "Register the app return URL exactly as shown above in Notaui.",
        "Use authorization code + PKCE (S256) for the browser connect flow.",
        "Configure token endpoint auth as client_secret_basic.",
        "After connect, Maraithon discovers accessible Notaui accounts with account.list and stores a default account.",
        "When Maraithon targets a non-default Notaui account it sends X-Notaui-Account-ID with the MCP request."
      ]
    }
  end

  defp provider_setup("desktop") do
    %{
      logo: :desktop,
      permissions: [
        "Pair a Mac securely with Maraithon",
        "Make local iMessage, Apple Notes, reminders, calendar, files, browser history, and voice memo context available",
        "Keep local context scoped to the signed-in Maraithon user"
      ],
      callback_urls: [],
      env_requirements: [],
      setup_notes: [
        "Install the Maraithon Mac companion app on a Mac you control.",
        "Pair the app with Maraithon, then choose which local sources to make available.",
        "Only the sources you enable are available to your assistant, and they stay scoped to your Maraithon account."
      ]
    }
  end

  defp provider_setup("telegram") do
    secret_path = config_value(:telegram, :webhook_secret_path)

    webhook_path =
      if present?(secret_path),
        do: "/webhooks/telegram/#{secret_path}",
        else: "/webhooks/telegram/{TELEGRAM_WEBHOOK_SECRET}"

    %{
      logo: :telegram,
      permissions: [
        "Read incoming bot messages for link commands",
        "Send push notifications for high-priority insights",
        "Read inline button feedback to tune thresholds"
      ],
      callback_urls: [
        %{label: "Webhook callback", url: callback_url(webhook_path), required?: true}
      ],
      env_requirements: [
        env_requirement(
          "TELEGRAM_BOT_TOKEN",
          config_value(:telegram, :bot_token),
          "Telegram bot token from BotFather",
          true
        ),
        env_requirement(
          "TELEGRAM_BOT_USERNAME",
          config_value(:telegram, :bot_username),
          "Telegram bot username used for self-serve deep links",
          true,
          "maraithon_bot"
        ),
        env_requirement(
          "TELEGRAM_WEBHOOK_SECRET",
          config_value(:telegram, :webhook_secret_path),
          "Secret path segment used by the webhook endpoint",
          true
        )
      ],
      setup_notes: [
        "Set your webhook to the callback URL shown above.",
        "Users link their chat from the Connect Telegram button or with: /start their-email@example.com",
        "Only insights above each user's threshold are pushed."
      ]
    }
  end

  defp callback_url(path) do
    Maraithon.AppUrl.url(path)
  end

  defp config_value(namespace, key) do
    Application.get_env(:maraithon, namespace, [])
    |> Keyword.get(key, "")
  end

  defp env_requirement(name, value, description, required?, recommended_value \\ nil) do
    %{
      name: name,
      description: description,
      required?: required?,
      present?: present?(value),
      recommended_value: recommended_value
    }
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(value), do: not is_nil(value)

  defp safe_fetch(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, error}
  end

  defp format_datetime(nil, _timezone_info), do: "never"

  defp format_datetime(%DateTime{} = value, timezone_info) do
    LocalTime.format_datetime(value, "never", timezone_info)
  end

  defp format_datetime(%NaiveDateTime{} = value, timezone_info) do
    LocalTime.format_datetime(value, "never", timezone_info)
  end
end
