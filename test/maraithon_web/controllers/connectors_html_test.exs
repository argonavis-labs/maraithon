defmodule MaraithonWeb.ConnectorsHTMLTest do
  use ExUnit.Case, async: true

  alias MaraithonWeb.ConnectorsHTML

  test "connection_primary_action/1 uses reconnect wording for connected telegram" do
    assert ConnectorsHTML.connection_primary_action(%{provider: "telegram", status: :connected}) ==
             "Reconnect Telegram"

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
