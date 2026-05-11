defmodule Maraithon.Tools.MessagesGetTest do
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
    test "marks user_id and message_id as required" do
      schema = Capabilities.tool_descriptor("messages_get").input_schema
      assert Enum.sort(schema["required"]) == ["message_id", "user_id"]
    end
  end

  describe "execute/1" do
    test "returns the full record by guid" do
      user_id = "messages-get-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("msg-abc", %{
            "text" => "Don't forget the cake",
            "chat_display_name" => "Family",
            "is_from_me" => true
          })
        ])

      assert {:ok, result} =
               Tools.execute("messages_get", %{
                 "user_id" => user_id,
                 "message_id" => "msg-abc"
               })

      assert result.source == "local_messages"
      msg = result.message
      assert msg.guid == "msg-abc"
      assert msg.message_id == "msg-abc"
      assert msg.text == "Don't forget the cake"
      assert msg.chat_display_name == "Family"
      assert msg.is_from_me == true
      assert is_binary(msg.sent_at)
    end

    test "returns message_not_found when guid is missing" do
      user_id = "messages-get-miss-#{System.unique_integer([:positive])}@example.com"

      assert {:error, "message_not_found"} =
               Tools.execute("messages_get", %{
                 "user_id" => user_id,
                 "message_id" => "does-not-exist"
               })
    end

    test "rejects missing args" do
      assert {:error, _} = Tools.execute("messages_get", %{"user_id" => "u"})
      assert {:error, _} = Tools.execute("messages_get", %{"message_id" => "m"})
    end
  end
end
