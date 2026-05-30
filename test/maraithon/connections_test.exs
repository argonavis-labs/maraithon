defmodule Maraithon.ConnectionsTest do
  use ExUnit.Case, async: true

  alias Maraithon.Connections

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
end
