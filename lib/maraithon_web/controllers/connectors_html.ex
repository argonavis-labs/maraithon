defmodule MaraithonWeb.ConnectorsHTML do
  use MaraithonWeb, :html

  alias MaraithonWeb.LocalTime

  embed_templates "connectors_html/*"

  def provider_detail_path(provider) when is_map(provider),
    do: "/connectors/#{provider.provider}"

  def provider_subtitle(%{details: details}) when is_list(details) do
    details
    |> Enum.take(2)
    |> Enum.join(" ")
  end

  def provider_subtitle(_provider), do: "Connection details unavailable."

  def telegram_connected?(providers) when is_list(providers) do
    Enum.any?(providers, fn provider ->
      provider.provider == "telegram" and
        (provider.status == :connected or provider[:disconnectable?] == true)
    end)
  end

  def telegram_connected?(_providers), do: false

  def setup_completion_text(%{setup_status: :configured}), do: "Connection ready"
  def setup_completion_text(_provider), do: "Connection needs attention"

  def provider_account_summary(provider) when is_map(provider) do
    accounts = Map.get(provider, :accounts, [])
    total_count = Enum.count(accounts)
    connected_count = Enum.count(accounts, &(&1.status == :connected))
    unit = provider_account_unit(provider)

    cond do
      total_count == 0 ->
        pluralize_units(0, unit, "connected")

      total_count == connected_count ->
        pluralize_units(connected_count, unit, "connected")

      connected_count == 0 ->
        attention_summary(total_count, unit)

      true ->
        "#{connected_count} of #{total_count} #{unit}s connected"
    end
  end

  def provider_account_summary(_provider), do: "0 accounts connected"

  def empty_accounts_message(%{provider: "desktop"}, _telegram_connected),
    do: "Install and sign in to the Mac companion app to pair this Mac."

  def empty_accounts_message(provider, telegram_connected) when is_map(provider) do
    cond do
      requires_telegram_first?(provider) and not telegram_connected ->
        "Connect Telegram first, then add #{Map.get(provider, :label, "this source")}."

      connection_action_enabled?(provider) ->
        "#{connection_primary_action(provider)} to start syncing."

      true ->
        "Finish connecting this source to start syncing."
    end
  end

  def empty_accounts_message(_provider, _telegram_connected),
    do: "Finish connecting this source to start syncing."

  def connection_error_detail(%{details: details}), do: public_error_detail(details)
  def connection_error_detail(_error), do: nil

  def provider_local_source_summary(%{provider: "desktop", details: details})
      when is_list(details) do
    Enum.find(details, &String.starts_with?(&1, "Context available: "))
  end

  def provider_local_source_summary(_provider), do: nil

  def connected_accounts_heading(%{provider: "slack"}), do: "Connected Workspaces"
  def connected_accounts_heading(%{provider: "desktop"}), do: "Paired Macs"
  def connected_accounts_heading(_provider), do: "Connected Accounts"

  def requires_telegram_first?(provider) when is_map(provider) do
    Map.get(provider, :provider) != "telegram" and Map.get(provider, :requires_telegram?, true)
  end

  def requires_telegram_first?(_provider), do: true

  def provider_grant_panels_visible?(provider) when is_map(provider) do
    case Map.get(provider, :provider) do
      "desktop" -> false
      "google" -> false
      "slack" -> Map.get(provider, :accounts, []) == []
      _provider -> true
    end
  end

  def provider_grant_panels_visible?(_provider), do: false

  def provider_oauth_setup_visible?(%{is_admin: true}, %{provider: "desktop"}), do: false
  def provider_oauth_setup_visible?(%{is_admin: true}, _provider), do: true
  def provider_oauth_setup_visible?(_user, _provider), do: false

  def refresh_token_badge_visible?(%{provider: "desktop"}), do: false
  def refresh_token_badge_visible?(_provider), do: true

  def connection_primary_action(%{provider: "google", status: status})
      when status in [:connected, :partial],
      do: "Add Google Account"

  def connection_primary_action(%{provider: "google", status: :needs_refresh}),
    do: "Reconnect Google"

  def connection_primary_action(%{provider: "google"}), do: "Connect Google"

  def connection_primary_action(%{provider: "telegram", status: :connected}),
    do: "View Telegram"

  def connection_primary_action(%{provider: "telegram", status: :needs_refresh}),
    do: "Reconnect Telegram"

  def connection_primary_action(%{provider: "telegram"}), do: "Link Telegram"

  def connection_primary_action(%{provider: "desktop", status: status})
      when status in [:connected, :partial],
      do: "View Mac companion"

  def connection_primary_action(%{provider: "desktop"}), do: "Set up Mac companion"

  def connection_primary_action(%{provider: "slack", status: :connected}), do: "View Slack"

  def connection_primary_action(%{provider: "slack", status: status})
      when status in [:partial, :missing_scope, :needs_refresh],
      do: "Reconnect Slack"

  def connection_primary_action(%{provider: "slack"}), do: "Connect Slack"
  def connection_primary_action(%{status: :needs_refresh}), do: "Reconnect"
  def connection_primary_action(%{status: :connected}), do: "View"
  def connection_primary_action(_provider), do: "Connect"

  def connection_action_enabled?(%{connect_blocked?: true}), do: false
  def connection_action_enabled?(%{configured?: true}), do: true
  def connection_action_enabled?(_provider), do: false

  def connection_primary_url(%{provider: "google"} = provider), do: provider.connect_url

  def connection_primary_url(%{provider: "desktop"} = provider),
    do: provider_detail_path(provider)

  def connection_primary_url(%{status: :connected} = provider), do: provider_detail_path(provider)

  def connection_primary_url(provider) when is_map(provider),
    do: Map.get(provider, :connect_url) || provider_detail_path(provider)

  def connection_primary_url(_provider), do: "/connectors"

  def connection_primary_action_visible_on_detail?(%{provider: provider, status: :connected})
      when provider != "google",
      do: false

  def connection_primary_action_visible_on_detail?(provider),
    do: connection_action_enabled?(provider)

  def account_reconnect_visible?(provider, account, telegram_connected) do
    account[:reconnect_url] &&
      account[:needs_reconnect?] == true &&
      (provider.provider == "telegram" || telegram_connected) &&
      provider[:connect_blocked?] != true
  end

  def connection_status_label(:connected), do: "connected"
  def connection_status_label(:partial), do: "partial"
  def connection_status_label(:missing_scope), do: "needs permission"
  def connection_status_label(:needs_refresh), do: "reconnect needed"
  def connection_status_label(:not_configured), do: "not ready"
  def connection_status_label(:unknown), do: "status unavailable"
  def connection_status_label(_status), do: "disconnected"

  def connection_status_color(:connected), do: "emerald"
  def connection_status_color(status) when status in [:partial, :missing_scope], do: "amber"
  def connection_status_color(:needs_refresh), do: "rose"
  def connection_status_color(_status), do: "zinc"

  def refresh_token_status_label(:active), do: "background access on"
  def refresh_token_status_label(:inactive), do: "reconnect needed"
  def refresh_token_status_label(:missing), do: "reconnect needed"
  def refresh_token_status_label(:not_required), do: "not required"
  def refresh_token_status_label(:not_applicable), do: "not applicable"
  def refresh_token_status_label(:unknown), do: "background access not checked"
  def refresh_token_status_label(_status), do: "background access not checked"

  def refresh_token_status_color(:active), do: "emerald"
  def refresh_token_status_color(status) when status in [:inactive, :missing], do: "amber"
  def refresh_token_status_color(_status), do: "zinc"

  def refresh_token_badge_class(:active),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  def refresh_token_badge_class(:inactive),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  def refresh_token_badge_class(:missing),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  def refresh_token_badge_class(:not_required),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  def refresh_token_badge_class(:not_applicable),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  def refresh_token_badge_class(_status),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  def connection_status_badge_class(:connected),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  def connection_status_badge_class(:partial),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  def connection_status_badge_class(:missing_scope),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  def connection_status_badge_class(:needs_refresh),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  def connection_status_badge_class(:not_configured),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  def connection_status_badge_class(:unknown),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  def connection_status_badge_class(_status),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  def setup_status_label(:configured), do: "ready"
  def setup_status_label(:incomplete), do: "needs attention"
  def setup_status_label(_status), do: "not checked"

  def setup_status_badge_class(:configured),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  def setup_status_badge_class(:incomplete),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  def setup_status_badge_class(_status),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  def callback_badge_class(true),
    do:
      "inline-flex rounded-md bg-indigo-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-indigo-700"

  def callback_badge_class(false),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  def env_status_label(true, _required), do: "present"
  def env_status_label(false, true), do: "missing"
  def env_status_label(false, false), do: "optional"

  def env_status_badge_class(true, _required),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  def env_status_badge_class(false, true),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  def env_status_badge_class(false, false),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  def connection_token_summary(token, timezone_info \\ nil)

  def connection_token_summary(token, timezone_info) when is_map(token) do
    scopes =
      case Map.get(token, :scopes) || Map.get(token, "scopes") do
        values when is_list(values) and values != [] ->
          permission_summary(values)

        _ ->
          nil
      end

    expires =
      case Map.get(token, :expires_at) || Map.get(token, "expires_at") do
        %DateTime{} = value -> "Access expires #{format_datetime(value, timezone_info)}"
        %NaiveDateTime{} = value -> "Access expires #{format_datetime(value, timezone_info)}"
        _ -> nil
      end

    [scopes, expires]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No additional connection details"
      values -> Enum.join(values, " • ")
    end
  end

  defp public_error_detail(details) when is_binary(details) do
    details = String.trim(details)

    cond do
      details == "" ->
        nil

      technical_error_detail?(details) ->
        "Refresh this page before continuing."

      true ->
        details
    end
  end

  defp public_error_detail(_details), do: nil

  defp technical_error_detail?(details) do
    downcased = String.downcase(details)

    Regex.match?(~r/^[a-z0-9_]+$/, details) or
      Enum.any?(
        [
          "dbconnection",
          "postgrex",
          "ecto.",
          "exception",
          "stacktrace",
          "{:",
          "%{",
          "=>",
          "token",
          "oauth",
          "select ",
          "insert ",
          "update "
        ],
        &String.contains?(downcased, &1)
      )
  end

  defp provider_account_unit(%{provider: "slack"}), do: "workspace"
  defp provider_account_unit(%{provider: "desktop"}), do: "Mac"
  defp provider_account_unit(_provider), do: "account"

  defp pluralize_units(1, unit, status), do: "1 #{unit} #{status}"
  defp pluralize_units(count, unit, status), do: "#{count} #{unit}s #{status}"

  defp attention_summary(1, unit), do: "1 #{unit} needs attention"
  defp attention_summary(count, unit), do: "#{count} #{unit}s need attention"

  defp permission_summary(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> length()
    |> case do
      0 -> nil
      count -> "#{count} #{permission_word(count)} granted"
    end
  end

  defp permission_word(1), do: "permission"
  defp permission_word(_count), do: "permissions"

  def format_datetime(value, timezone_info \\ nil)

  def format_datetime(nil, _timezone_info), do: "never"

  def format_datetime(%DateTime{} = value, timezone_info) when is_map(timezone_info) do
    LocalTime.format_datetime(value, "never", timezone_info)
  end

  def format_datetime(%DateTime{} = value, _timezone_info) do
    Calendar.strftime(value, "%b %-d, %Y at %-I:%M %p UTC")
  end

  def format_datetime(%NaiveDateTime{} = value, timezone_info) when is_map(timezone_info) do
    LocalTime.format_datetime(value, "never", timezone_info)
  end

  def format_datetime(%NaiveDateTime{} = value, _timezone_info),
    do: Calendar.strftime(value, "%b %-d, %Y at %-I:%M %p UTC")

  def format_datetime(value, _timezone_info) when is_binary(value), do: value
  def format_datetime(_value, _timezone_info), do: "not recorded"

  def endpoint_url do
    MaraithonWeb.Endpoint.url()
  end

  attr :provider, :atom, required: true

  def oauth_logo(assigns) do
    ~H"""
    <div class="flex h-10 w-10 items-center justify-center overflow-hidden rounded-lg border border-zinc-950/10 bg-white p-1.5 shadow-sm">
      <img
        src={connector_logo_src(@provider)}
        alt={connector_logo_alt(@provider)}
        class="h-full w-full object-contain"
      />
    </div>
    """
  end

  defp connector_logo_src(:google), do: "/images/connector-logos/google.svg"
  defp connector_logo_src(:github), do: "/images/connector-logos/github.svg"
  defp connector_logo_src(:slack), do: "/images/connector-logos/slack.svg"
  defp connector_logo_src(:linear), do: "/images/connector-logos/linear.svg"
  defp connector_logo_src(:notion), do: "/images/connector-logos/notion.png"
  defp connector_logo_src(:notaui), do: "/images/connector-logos/notaui.png"
  defp connector_logo_src(:telegram), do: "/images/connector-logos/telegram.png"
  defp connector_logo_src(:desktop), do: "/favicon.ico"
  defp connector_logo_src(_provider), do: "/favicon.ico"

  defp connector_logo_alt(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp connector_logo_alt(_provider), do: "Connected app"
end
