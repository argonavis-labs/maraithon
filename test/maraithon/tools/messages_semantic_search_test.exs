defmodule Maraithon.Tools.MessagesSemanticSearchTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Capabilities
  alias Maraithon.LocalMessages
  alias Maraithon.Tools

  defp seed_user(label) do
    email = "msg-sem-#{label}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {user.id, Ecto.UUID.generate()}
  end

  defp sample_message(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "m:#{guid}",
        "guid" => guid,
        "chat_key" => "chat:1",
        "chat_display_name" => "Charlie",
        "sender_handle" => "+15555550100",
        "text" => "hi",
        "sent_at" => "2026-05-10T13:14:22Z",
        "is_from_me" => false
      },
      overrides
    )
  end

  describe "registration" do
    test "registered with required query + user_id and read-only policy" do
      descriptor = Capabilities.tool_descriptor("messages_semantic_search")
      assert descriptor.description =~ "Semantic search of the user's mirrored iMessage history"
      schema = descriptor.input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]
      assert schema["properties"]["from_handle"]["type"] == "string"

      policy = Tools.policy_metadata_for("messages_semantic_search")
      assert policy.read_only? == true
    end
  end

  describe "execute/1" do
    test "ranks the semantically-closest message first" do
      {user_id, device_id} = seed_user("rank")

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("m1", %{"text" => "wanna meet for coffee tomorrow morning?"}),
          sample_message("m2", %{"text" => "send me the slide deck for the investor pitch"}),
          sample_message("m3", %{"text" => "grocery run later, need eggs and milk"})
        ])

      assert {:ok, result} =
               Tools.execute("messages_semantic_search", %{
                 "user_id" => user_id,
                 "query" => "investor pitch slide deck"
               })

      assert result.source == "local_messages"
      assert result.search_mode == "semantic"
      assert result.count >= 1
      [top | _] = result.messages
      assert top.guid == "m2"
    end

    test "returns empty list cleanly when no messages exist" do
      {user_id, _device_id} = seed_user("empty")

      assert {:ok, %{count: 0, messages: []}} =
               Tools.execute("messages_semantic_search", %{
                 "user_id" => user_id,
                 "query" => "no such message"
               })
    end

    test "rejects missing query" do
      {user_id, _device_id} = seed_user("missq")

      assert {:error, message} =
               Tools.execute("messages_semantic_search", %{"user_id" => user_id})

      assert message =~ "query is required"
    end
  end
end
