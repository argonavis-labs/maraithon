defmodule MaraithonWeb.ConnectorsHTML do
  use MaraithonWeb, :html

  embed_templates "connectors_html/*"

  def provider_detail_path(provider) when is_map(provider),
    do: "/connectors/#{provider.provider}"

  def provider_subtitle(%{details: details}) when is_list(details) do
    details
    |> Enum.take(2)
    |> Enum.join(" ")
  end

  def provider_subtitle(_provider), do: "No details yet."

  def telegram_connected?(providers) when is_list(providers) do
    Enum.any?(providers, fn provider ->
      provider.provider == "telegram" and
        (provider.status == :connected or provider[:disconnectable?] == true)
    end)
  end

  def telegram_connected?(_providers), do: false

  def setup_completion_text(%{setup_status: :configured}), do: "Connector configured"
  def setup_completion_text(_provider), do: "Connector setup required"

  def provider_account_summary(provider) when is_map(provider) do
    accounts = Map.get(provider, :accounts, [])
    total_count = Enum.count(accounts)
    connected_count = Enum.count(accounts, &(&1.status == :connected))
    unit = provider_account_unit(provider)

    cond do
      total_count == 0 ->
        "No #{unit}s connected"

      total_count == connected_count ->
        pluralize_units(connected_count, unit, "connected")

      connected_count == 0 ->
        attention_summary(total_count, unit)

      true ->
        "#{connected_count} of #{total_count} #{unit}s connected"
    end
  end

  def provider_account_summary(_provider), do: "No accounts connected"

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

  def provider_oauth_setup_visible?(%{provider: "desktop"}), do: false
  def provider_oauth_setup_visible?(_provider), do: true

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
      do: "View Desktop App"

  def connection_primary_action(%{provider: "desktop"}), do: "Set up Desktop App"

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
  def connection_status_label(:missing_scope), do: "needs scope"
  def connection_status_label(:needs_refresh), do: "refresh required"
  def connection_status_label(:not_configured), do: "not configured"
  def connection_status_label(:unknown), do: "unknown"
  def connection_status_label(_status), do: "disconnected"

  def connection_status_color(:connected), do: "emerald"
  def connection_status_color(status) when status in [:partial, :missing_scope], do: "amber"
  def connection_status_color(:needs_refresh), do: "rose"
  def connection_status_color(_status), do: "zinc"

  def refresh_token_status_label(:active), do: "refresh active"
  def refresh_token_status_label(:inactive), do: "refresh inactive"
  def refresh_token_status_label(:missing), do: "no refresh token"
  def refresh_token_status_label(:not_required), do: "not required"
  def refresh_token_status_label(:not_applicable), do: "not applicable"
  def refresh_token_status_label(:unknown), do: "unknown"
  def refresh_token_status_label(_status), do: "unknown"

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

  def setup_status_label(:configured), do: "configured"
  def setup_status_label(:incomplete), do: "needs setup"
  def setup_status_label(_status), do: "unknown"

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

  def connection_token_summary(token) when is_map(token) do
    scopes =
      case Map.get(token, :scopes) || Map.get(token, "scopes") do
        values when is_list(values) and values != [] -> "Scopes: #{Enum.join(values, ", ")}"
        _ -> nil
      end

    expires =
      case Map.get(token, :expires_at) || Map.get(token, "expires_at") do
        %DateTime{} = value -> "Expires #{format_datetime(value)}"
        %NaiveDateTime{} = value -> "Expires #{format_datetime(value)}"
        _ -> nil
      end

    [scopes, expires]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No additional token metadata"
      values -> Enum.join(values, " • ")
    end
  end

  defp provider_account_unit(%{provider: "slack"}), do: "workspace"
  defp provider_account_unit(%{provider: "desktop"}), do: "Mac"
  defp provider_account_unit(_provider), do: "account"

  defp pluralize_units(1, unit, status), do: "1 #{unit} #{status}"
  defp pluralize_units(count, unit, status), do: "#{count} #{unit}s #{status}"

  defp attention_summary(1, unit), do: "1 #{unit} needs attention"
  defp attention_summary(count, unit), do: "#{count} #{unit}s need attention"

  def format_datetime(nil), do: "never"
  def format_datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")

  def format_datetime(%NaiveDateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")

  def format_datetime(value) when is_binary(value), do: value
  def format_datetime(_value), do: "unknown"

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

  defp connector_logo_alt(_provider), do: "Connector"
end
