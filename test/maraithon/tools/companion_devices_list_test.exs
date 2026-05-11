defmodule Maraithon.Tools.CompanionDevicesListTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Capabilities
  alias Maraithon.Companion.Devices
  alias Maraithon.LocalMessages
  alias Maraithon.Tools

  defp sample_message(guid) do
    %{
      "local_id" => "p:#{guid}",
      "guid" => guid,
      "service" => "iMessage",
      "is_from_me" => false,
      "sender_handle" => "+1",
      "chat_handles" => ["+1"],
      "chat_style" => "im",
      "text" => "hi",
      "sent_at" => "2026-05-10T13:14:22Z",
      "has_attachments" => false,
      "attachments" => []
    }
  end

  describe "input_schema" do
    test "marks only user_id as required" do
      schema = Capabilities.tool_descriptor("companion_devices_list").input_schema
      assert schema["required"] == ["user_id"]
    end
  end

  describe "execute/1" do
    test "returns the user's devices with per-source counts" do
      email = "tool-devices-#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Accounts.get_or_create_user_by_email(email)

      {:ok, %{device: mac_a}} = Devices.register(user.id, Ecto.UUID.generate(), device_name: "A")
      {:ok, %{device: _mac_b}} = Devices.register(user.id, Ecto.UUID.generate(), device_name: "B")

      {:ok, _} =
        LocalMessages.ingest_batch(user.id, mac_a.device_id, [
          sample_message("tool-g1"),
          sample_message("tool-g2"),
          sample_message("tool-g3")
        ])

      assert {:ok, %{source: "companion_devices", count: 2, devices: devices}} =
               Tools.execute("companion_devices_list", %{"user_id" => user.id})

      a_summary = Enum.find(devices, &(&1.device_id == mac_a.device_id))
      assert a_summary.device_name == "A"
      assert a_summary.counts.messages_count == 3
      assert a_summary.revoked == false
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("companion_devices_list", %{})
    end

    test "returns an empty list when the user has no devices" do
      email = "tool-devices-empty-#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Accounts.get_or_create_user_by_email(email)

      assert {:ok, %{count: 0, devices: []}} =
               Tools.execute("companion_devices_list", %{"user_id" => user.id})
    end
  end
end
