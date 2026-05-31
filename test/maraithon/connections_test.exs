defmodule Maraithon.ConnectionsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Companion.Devices
  alias Maraithon.Connections
  alias Maraithon.OAuth

  describe "safe_dashboard_snapshot/2" do
    test "returns product-safe degraded copy when connection inventory cannot load" do
      assert {:degraded, snapshot} =
               Connections.safe_dashboard_snapshot("connections-copy@example.com",
                 fetcher: fn ->
                   raise DBConnection.ConnectionError, message: "queue timeout"
                 end
               )

      assert snapshot.degraded

      assert [%{message: "Connection inventory is temporarily unavailable.", details: details}] =
               snapshot.errors

      assert details =~ "Maraithon will refresh connection status"
      refute details =~ "database"
      refute details =~ "queue timeout"
      refute inspect(snapshot) =~ "Token store"

      assert Enum.all?(snapshot.providers, &(&1.status == :unknown))
      assert Enum.find(snapshot.providers, &(&1.id == "desktop"))
    end
  end

  describe "dashboard_snapshot/2 desktop copy" do
    test "uses action-oriented setup copy before a Mac is paired" do
      snapshot = Connections.dashboard_snapshot("desktop-unpaired@example.com")
      desktop = Enum.find(snapshot.providers, &(&1.provider == "desktop"))

      assert "Pair a Mac to start syncing local sources." in desktop.details

      assert Enum.any?(desktop.details, fn detail ->
               String.contains?(detail, "Install the Maraithon Mac companion app")
             end)

      refute inspect(desktop) =~ "No Mac paired yet"
    end

    test "shows waiting copy when a paired Mac has not completed a local sync" do
      user_id = "desktop-waiting@example.com"

      assert {:ok, _result} =
               Devices.register(user_id, Ecto.UUID.generate(), device_name: "Studio Mac")

      snapshot = Connections.dashboard_snapshot(user_id)
      desktop = Enum.find(snapshot.providers, &(&1.provider == "desktop"))

      assert "1 Mac paired" in desktop.details
      assert "Waiting for local sources to finish their first check." in desktop.details

      assert [%{account: "Studio Mac", details: device_details}] = desktop.accounts
      assert "Paired and waiting for the first local sync." in device_details

      visible_copy = inspect(desktop)
      refute visible_copy =~ "Paired, but no local sources have synced yet"
      refute visible_copy =~ "No local sources synced yet"
    end
  end

  describe "dashboard_snapshot/2 Notaui copy" do
    test "uses actionable copy when Notaui returns no usable accounts" do
      user_id = "notaui-empty@example.com"

      assert {:ok, _token} =
               OAuth.store_tokens(user_id, "notaui", %{
                 access_token: "notaui-token",
                 refresh_token: "notaui-refresh",
                 scopes: ["tasks:read"],
                 metadata: %{
                   "account_count" => 0,
                   "accounts" => [],
                   "mcp_url" => "https://api.notaui.com/mcp"
                 }
               })

      snapshot = Connections.dashboard_snapshot(user_id)
      notaui = Enum.find(snapshot.providers, &(&1.provider == "notaui"))

      assert "Notaui connected, but it did not return any accounts Maraithon can use. Reconnect Notaui if accounts are missing." in notaui.details

      refute inspect(notaui) =~ "No accessible Notaui accounts were discovered yet"
    end
  end
end
