defmodule Maraithon.LocalMessagesTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.LocalMessages
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.Repo

  defp sample_message(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "p:1",
        "guid" => guid,
        "service" => "iMessage",
        "is_from_me" => false,
        "sender_handle" => "+14165550199",
        "chat_handles" => ["+14165550199"],
        "chat_display_name" => nil,
        "chat_style" => "im",
        "text" => "Hello",
        "sent_at" => "2026-05-10T13:14:22Z",
        "has_attachments" => false,
        "attachments" => []
      },
      overrides
    )
  end

  describe "ingest_batch/3" do
    test "inserts a fresh batch and reports accepted counts" do
      user_id = "ingest-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      messages =
        for i <- 1..3 do
          sample_message("guid-#{i}", %{"text" => "msg #{i}"})
        end

      {:ok, %{accepted: 3, duplicate: 0}} =
        LocalMessages.ingest_batch(user_id, device_id, messages)

      stored = Repo.all(LocalMessage)
      assert length(stored) == 3
      assert Enum.all?(stored, &(&1.user_id == user_id))
      assert Enum.all?(stored, &(&1.device_id == device_id))
      assert Enum.all?(stored, &(&1.text in ["msg 1", "msg 2", "msg 3"]))
    end

    test "dedupes via the unique constraint on re-send" do
      user_id = "dedupe-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      messages = [sample_message("guid-a"), sample_message("guid-b")]

      {:ok, %{accepted: 2, duplicate: 0}} =
        LocalMessages.ingest_batch(user_id, device_id, messages)

      {:ok, %{accepted: 0, duplicate: 2}} =
        LocalMessages.ingest_batch(user_id, device_id, messages)

      assert Repo.aggregate(LocalMessage, :count, :id) == 2
    end

    test "derives chat_key from chat_handles when not provided" do
      user_id = "chat-key-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("guid-1", %{"chat_handles" => ["+14165550199", "+14165550111"]})
        ])

      [stored] = Repo.all(LocalMessage)
      assert stored.chat_key == "+14165550111,+14165550199"
    end
  end

  describe "purge_device/2" do
    test "removes all rows for the (user, device) pair" do
      user_id = "purge-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("guid-1"),
          sample_message("guid-2")
        ])

      assert Repo.aggregate(LocalMessage, :count, :id) == 2

      {:ok, %{deleted: 2}} = LocalMessages.purge_device(user_id, device_id)

      assert Repo.aggregate(LocalMessage, :count, :id) == 0
    end
  end

  describe "recent_for_chat/3" do
    test "returns messages for that chat newest first" do
      user_id = "recent-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("g1", %{
            "chat_handles" => ["+14165550100"],
            "sent_at" => "2026-05-10T10:00:00Z"
          }),
          sample_message("g2", %{
            "chat_handles" => ["+14165550100"],
            "sent_at" => "2026-05-10T11:00:00Z"
          }),
          sample_message("g3", %{
            "chat_handles" => ["+14165550200"],
            "sent_at" => "2026-05-10T12:00:00Z"
          })
        ])

      rows = LocalMessages.recent_for_chat(user_id, "+14165550100")
      assert length(rows) == 2
      assert hd(rows).sent_at
    end
  end
end
