defmodule Maraithon.Tools.MessagesListRecentTest do
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
      schema = Capabilities.tool_descriptor("messages_list_recent").input_schema
      assert schema["required"] == ["user_id"]
      assert schema["properties"]["limit"]["type"] == "integer"
      assert schema["properties"]["chat_key"]["type"] == "string"
    end
  end

  describe "execute/1" do
    test "orders newest first and serializes summaries" do
      user_id = "messages-recent-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("g-old", %{
            "text" => "older",
            "sent_at" => "2026-05-10T10:00:00Z"
          }),
          sample_message("g-new", %{
            "text" => "newer",
            "sent_at" => "2026-05-10T12:00:00Z"
          })
        ])

      assert {:ok, result} =
               Tools.execute("messages_list_recent", %{"user_id" => user_id})

      assert result.source == "local_messages"
      assert result.count == 2
      snippets = Enum.map(result.messages, & &1.text_snippet)
      assert snippets == ["newer", "older"]
    end

    test "honors a smaller limit" do
      user_id =
        "messages-recent-limit-#{System.unique_integer([:positive])}@example.com"

      device_id = Ecto.UUID.generate()

      messages =
        for i <- 1..5 do
          sample_message("g#{i}", %{
            "text" => "n#{i}",
            "sent_at" => "2026-05-10T1#{i}:00:00Z"
          })
        end

      {:ok, _} = LocalMessages.ingest_batch(user_id, device_id, messages)

      assert {:ok, %{count: 2}} =
               Tools.execute("messages_list_recent", %{
                 "user_id" => user_id,
                 "limit" => 2
               })
    end

    test "filters by chat_key when supplied" do
      user_id =
        "messages-recent-chat-#{System.unique_integer([:positive])}@example.com"

      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("g1", %{
            "chat_key" => "chat-a",
            "text" => "in chat a"
          }),
          sample_message("g2", %{
            "chat_key" => "chat-b",
            "text" => "in chat b"
          })
        ])

      assert {:ok, result} =
               Tools.execute("messages_list_recent", %{
                 "user_id" => user_id,
                 "chat_key" => "chat-b"
               })

      assert result.chat_key == "chat-b"
      assert result.count == 1
      [msg] = result.messages
      assert msg.chat_key == "chat-b"
    end

    test "returns empty list cleanly when no messages exist" do
      user_id =
        "messages-recent-empty-#{System.unique_integer([:positive])}@example.com"

      assert {:ok, %{count: 0, messages: []}} =
               Tools.execute("messages_list_recent", %{"user_id" => user_id})
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("messages_list_recent", %{})
    end
  end
end
