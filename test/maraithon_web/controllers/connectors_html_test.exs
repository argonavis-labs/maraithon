defmodule MaraithonWeb.ConnectorsHTMLTest do
  use ExUnit.Case, async: true

  alias MaraithonWeb.ConnectorsHTML

  test "connection_primary_action/1 uses view wording for healthy connected telegram" do
    assert ConnectorsHTML.connection_primary_action(%{provider: "telegram", status: :connected}) ==
             "View Telegram"

    assert ConnectorsHTML.connection_primary_action(%{
             provider: "telegram",
             status: :disconnected
           }) == "Link Telegram"
  end

  test "connection_status_label/1 supports needs_refresh status" do
    assert ConnectorsHTML.connection_status_label(:needs_refresh) == "refresh required"
  end

  test "connection_primary_action/1 uses reconnect wording for refresh-required google" do
    assert ConnectorsHTML.connection_primary_action(%{provider: "google", status: :needs_refresh}) ==
             "Reconnect Google"
  end

  test "connection_primary_action/1 only uses reconnect wording for stale slack" do
    assert ConnectorsHTML.connection_primary_action(%{provider: "slack", status: :connected}) ==
             "View Slack"

    assert ConnectorsHTML.connection_primary_action(%{provider: "slack", status: :missing_scope}) ==
             "Reconnect Slack"
  end

  test "account_reconnect_visible?/3 only shows stale account reconnect controls" do
    provider = %{provider: "slack", connect_blocked?: false}

    refute ConnectorsHTML.account_reconnect_visible?(
             provider,
             %{reconnect_url: "/auth/slack", needs_reconnect?: false},
             true
           )

    assert ConnectorsHTML.account_reconnect_visible?(
             provider,
             %{reconnect_url: "/auth/slack", needs_reconnect?: true},
             true
           )
  end

  test "refresh_token_status_label/1 explains refresh token state" do
    assert ConnectorsHTML.refresh_token_status_label(:active) == "refresh active"
    assert ConnectorsHTML.refresh_token_status_label(:inactive) == "refresh inactive"
    assert ConnectorsHTML.refresh_token_status_label(:not_applicable) == "not applicable"
  end

  test "connection_action_enabled?/1 blocks providers gated behind telegram" do
    refute ConnectorsHTML.connection_action_enabled?(%{
             configured?: true,
             connect_blocked?: true
           })

    assert ConnectorsHTML.connection_action_enabled?(%{
             configured?: true,
             connect_blocked?: false
           })
  end
end
