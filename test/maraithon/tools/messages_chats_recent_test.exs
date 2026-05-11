defmodule Maraithon.Tools.MessagesChatsRecentTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Capabilities
  alias Maraithon.LocalMessages
  alias Maraithon.Tools

  defp sample_message(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "m:#{guid}",
        "guid" => guid,
        "is_from_me" => false,
        "sender_handle" => "+15555550100",
        "chat_key" => "+15555550100",
        "chat_display_name" => "Charlie",
        "chat_style" => "1:1",
        "text" => "hello",
        "sent_at" => "2026-05-10T13:14:22Z",
        "has_attachments" => false,
        "attachments" => %{}
      },
      overrides
    )
  end

  describe "input_schema" do
    test "marks only user_id as required" do
      schema = Capabilities.tool_descriptor("messages_chats_recent").input_schema
      assert schema["required"] == ["user_id"]
      assert schema["properties"]["limit"]["type"] == "integer"
    end
  end

  describe "execute/1" do
    test "returns each chat with the latest message and 7d count" do
      user_id = "chats-recent-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      recent_iso = DateTime.to_iso8601(now)
      mid_iso = DateTime.to_iso8601(DateTime.add(now, -60 * 60, :second))
      older_iso = DateTime.to_iso8601(DateTime.add(now, -60 * 60 * 24, :second))
      pre_window_iso = DateTime.to_iso8601(DateTime.add(now, -60 * 60 * 24 * 14, :second))

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("a1", %{
            "chat_key" => "chat-a",
            "chat_display_name" => "Charlie",
            "text" => "latest in a",
            "sent_at" => recent_iso
          }),
          sample_message("a2", %{
            "chat_key" => "chat-a",
            "chat_display_name" => "Charlie",
            "text" => "earlier in a",
            "sent_at" => mid_iso
          }),
          sample_message("a3", %{
            "chat_key" => "chat-a",
            "chat_display_name" => "Charlie",
            "text" => "old in a",
            "sent_at" => pre_window_iso
          }),
          sample_message("b1", %{
            "chat_key" => "chat-b",
            "chat_display_name" => "Dana",
            "text" => "only in b",
            "sent_at" => older_iso
          })
        ])

      assert {:ok, result} =
               Tools.execute("messages_chats_recent", %{"user_id" => user_id})

      assert result.source == "local_messages"
      assert result.count == 2

      [first, second] = result.chats
      assert first.chat_key == "chat-a"
      assert first.chat_display_name == "Charlie"
      assert first.latest_text_snippet == "latest in a"
      assert first.message_count_last_7d == 2
      assert is_binary(first.latest_sent_at)

      assert second.chat_key == "chat-b"
      assert second.chat_display_name == "Dana"
      assert second.latest_text_snippet == "only in b"
      assert second.message_count_last_7d == 1
    end

    test "honors limit" do
      user_id =
        "chats-recent-limit-#{System.unique_integer([:positive])}@example.com"

      device_id = Ecto.UUID.generate()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      messages =
        for i <- 1..4 do
          sent_at =
            now
            |> DateTime.add(-i * 60, :second)
            |> DateTime.to_iso8601()

          sample_message("c#{i}", %{
            "chat_key" => "chat-#{i}",
            "chat_display_name" => "Chat #{i}",
            "text" => "msg #{i}",
            "sent_at" => sent_at
          })
        end

      {:ok, _} = LocalMessages.ingest_batch(user_id, device_id, messages)

      assert {:ok, result} =
               Tools.execute("messages_chats_recent", %{
                 "user_id" => user_id,
                 "limit" => 2
               })

      assert result.count == 2
    end

    test "returns empty list when no messages exist" do
      user_id =
        "chats-recent-empty-#{System.unique_integer([:positive])}@example.com"

      assert {:ok, %{count: 0, chats: []}} =
               Tools.execute("messages_chats_recent", %{"user_id" => user_id})
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("messages_chats_recent", %{})
    end
  end
end
