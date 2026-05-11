defmodule Maraithon.Companion.DevicesTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Companion.Device
  alias Maraithon.Companion.Devices
  alias Maraithon.LocalMessages
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.LocalNotes
  alias Maraithon.LocalNotes.LocalNote
  alias Maraithon.Repo

  import Ecto.Query

  defp create_user(email) do
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    user
  end

  describe "register/3" do
    test "creates a new device row with a hashed token and bumps last_seen_at" do
      user = create_user("devices-register-#{System.unique_integer([:positive])}@example.com")
      device_id = Ecto.UUID.generate()

      {:ok, %{device: device, token: token}} =
        Devices.register(user.id, device_id, device_name: "Kent's Mac")

      assert device.user_id == user.id
      assert device.device_id == device_id
      assert device.device_name == "Kent's Mac"
      assert is_binary(token)
      assert byte_size(token) > 16
      assert device.token_hash == Devices.hash_token(token)
      assert device.last_seen_at
      refute device.revoked_at
    end

    test "is idempotent on (user, device): rotates the token and clears revoked_at" do
      user = create_user("devices-rotate-#{System.unique_integer([:positive])}@example.com")
      device_id = Ecto.UUID.generate()

      {:ok, %{token: token_a, device: device_a}} = Devices.register(user.id, device_id)
      {:ok, _} = Devices.revoke(user.id, device_a.id)
      {:ok, %{token: token_b, device: device_b}} = Devices.register(user.id, device_id)

      assert device_a.id == device_b.id
      assert token_a != token_b
      refute device_b.revoked_at
      assert device_b.token_hash == Devices.hash_token(token_b)
    end
  end

  describe "verify_token/1" do
    test "returns the device for an active token" do
      user = create_user("devices-verify-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: device, token: token}} = Devices.register(user.id, Ecto.UUID.generate())

      assert %Device{id: id} = Devices.verify_token(token)
      assert id == device.id
    end

    test "returns nil for a revoked device" do
      user = create_user("devices-revoke-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: device, token: token}} = Devices.register(user.id, Ecto.UUID.generate())

      {:ok, _} = Devices.revoke(user.id, device.id)

      assert is_nil(Devices.verify_token(token))
    end

    test "returns nil for unknown or empty tokens" do
      assert is_nil(Devices.verify_token("does-not-exist"))
      assert is_nil(Devices.verify_token(""))
      assert is_nil(Devices.verify_token(nil))
    end
  end

  describe "touch_last_seen/1" do
    test "moves last_seen_at forward" do
      user = create_user("devices-touch-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: device}} = Devices.register(user.id, Ecto.UUID.generate())

      :timer.sleep(5)
      touched = Devices.touch_last_seen(device)

      assert DateTime.compare(touched.last_seen_at, device.last_seen_at) == :gt
    end
  end

  describe "list_for_user/1" do
    test "returns rows for a user (including revoked) sorted by recency" do
      user = create_user("devices-list-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: a}} = Devices.register(user.id, Ecto.UUID.generate())
      {:ok, %{device: b}} = Devices.register(user.id, Ecto.UUID.generate())

      list = Devices.list_for_user(user.id)
      ids = Enum.map(list, & &1.id)

      assert a.id in ids
      assert b.id in ids
    end
  end

  describe "get/2" do
    test "returns the device only when it belongs to the user" do
      user_a = create_user("devices-get-a-#{System.unique_integer([:positive])}@example.com")
      user_b = create_user("devices-get-b-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: device}} = Devices.register(user_a.id, Ecto.UUID.generate())

      assert %Device{} = Devices.get(user_a.id, device.id)
      assert is_nil(Devices.get(user_b.id, device.id))
    end
  end

  describe "enrich_with_stats/1" do
    test "joins per-source counts onto each device" do
      user = create_user("devices-stats-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: mac_a}} = Devices.register(user.id, Ecto.UUID.generate())
      {:ok, %{device: mac_b}} = Devices.register(user.id, Ecto.UUID.generate())

      {:ok, _} =
        LocalMessages.ingest_batch(user.id, mac_a.device_id, [
          %{
            "local_id" => "p:1",
            "guid" => "g-stat-a-1",
            "service" => "iMessage",
            "is_from_me" => false,
            "sender_handle" => "+1",
            "chat_handles" => ["+1"],
            "chat_style" => "im",
            "text" => "hi",
            "sent_at" => "2026-05-10T13:14:22Z",
            "has_attachments" => false,
            "attachments" => []
          },
          %{
            "local_id" => "p:2",
            "guid" => "g-stat-a-2",
            "service" => "iMessage",
            "is_from_me" => false,
            "sender_handle" => "+1",
            "chat_handles" => ["+1"],
            "chat_style" => "im",
            "text" => "hi2",
            "sent_at" => "2026-05-10T13:15:22Z",
            "has_attachments" => false,
            "attachments" => []
          }
        ])

      {:ok, _} =
        LocalNotes.ingest_batch(user.id, mac_a.device_id, [
          %{
            "local_id" => "n:1",
            "guid" => "n-stat-a-1",
            "title" => "n",
            "snippet" => "s",
            "folder" => "f",
            "is_pinned" => false,
            "created_at" => "2026-05-09T08:00:00Z",
            "modified_at" => "2026-05-10T13:14:22Z"
          }
        ])

      enriched = Devices.enrich_with_stats([mac_a, mac_b])

      assert {^mac_a, stats_a} = Enum.find(enriched, fn {d, _} -> d.id == mac_a.id end)
      assert {^mac_b, stats_b} = Enum.find(enriched, fn {d, _} -> d.id == mac_b.id end)
      assert stats_a.messages_count == 2
      assert stats_a.notes_count == 1
      assert stats_a.voice_memos_count == 0
      assert stats_b.messages_count == 0
      assert stats_b.notes_count == 0
    end

    test "returns zeroed stats for every device when there is no data" do
      user = create_user("devices-empty-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: device}} = Devices.register(user.id, Ecto.UUID.generate())

      [{returned, stats}] = Devices.enrich_with_stats([device])
      assert returned.id == device.id
      assert stats.messages_count == 0
      assert stats.notes_count == 0
      assert stats.voice_memos_count == 0
      assert stats.calendar_events_count == 0
      assert stats.reminders_count == 0
      assert stats.files_count == 0
      assert stats.browser_visits_count == 0
    end

    test "returns [] when called with no devices" do
      assert Devices.enrich_with_stats([]) == []
    end
  end

  describe "delete/2" do
    test "deletes the device row and purges its mirrored data" do
      user = create_user("devices-delete-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: device}} = Devices.register(user.id, Ecto.UUID.generate())

      {:ok, _} =
        LocalMessages.ingest_batch(user.id, device.device_id, [
          %{
            "local_id" => "p:1",
            "guid" => "g-del-1",
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
        ])

      {:ok, _} =
        LocalNotes.ingest_batch(user.id, device.device_id, [
          %{
            "local_id" => "n:1",
            "guid" => "n-del-1",
            "title" => "n",
            "snippet" => "s",
            "folder" => "f",
            "is_pinned" => false,
            "created_at" => "2026-05-09T08:00:00Z",
            "modified_at" => "2026-05-10T13:14:22Z"
          }
        ])

      assert {:ok, %{device: deleted, deleted: counts}} = Devices.delete(user.id, device.id)
      assert deleted.id == device.id
      assert counts.messages == 1
      assert counts.notes == 1
      refute Devices.get(user.id, device.id)
      assert message_count_for(user.id, device.device_id) == 0
      assert note_count_for(user.id, device.device_id) == 0
    end

    test "returns :not_found when the device does not belong to the user" do
      user_a = create_user("devices-del-a-#{System.unique_integer([:positive])}@example.com")
      user_b = create_user("devices-del-b-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: device}} = Devices.register(user_a.id, Ecto.UUID.generate())

      assert {:error, :not_found} = Devices.delete(user_b.id, device.id)
    end
  end

  defp message_count_for(user_id, device_id) do
    Repo.aggregate(
      from(m in LocalMessage, where: m.user_id == ^user_id and m.device_id == ^device_id),
      :count,
      :id
    )
  end

  defp note_count_for(user_id, device_id) do
    Repo.aggregate(
      from(n in LocalNote, where: n.user_id == ^user_id and n.device_id == ^device_id),
      :count,
      :id
    )
  end
end
