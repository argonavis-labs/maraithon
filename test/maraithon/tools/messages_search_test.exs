defmodule Maraithon.Tools.MessagesSearchTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Capabilities
  alias Maraithon.Crm
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

  defp seed_user(test_label) do
    user_id =
      "messages-search-#{test_label}-#{System.unique_integer([:positive])}@example.com"

    device_id = Ecto.UUID.generate()
    {user_id, device_id}
  end

  describe "input_schema" do
    test "marks user_id and query as required" do
      schema = Capabilities.tool_descriptor("messages_search").input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]
      assert schema["properties"]["limit"]["type"] == "integer"
      assert schema["properties"]["from_handle"]["type"] == "string"
      assert schema["properties"]["since"]["type"] == "string"
      assert schema["properties"]["before"]["type"] == "string"
    end
  end

  describe "execute/1" do
    test "returns substring matches on text" do
      {user_id, device_id} = seed_user("hit")

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("g1", %{"text" => "Need to grab milk and eggs"}),
          sample_message("g2", %{"text" => "Hotel reservation confirmed"}),
          sample_message("g3", %{"text" => "Random chatter about books"})
        ])

      assert {:ok, result} =
               Tools.execute("messages_search", %{
                 "user_id" => user_id,
                 "query" => "hotel"
               })

      assert result.source == "local_messages"
      assert result.query == "hotel"
      assert result.count == 1
      [msg] = result.messages
      assert msg.guid == "g2"
      assert msg.message_id == "g2"
      assert msg.text_snippet == "Hotel reservation confirmed"
      assert msg.chat_display_name == "Charlie"
      assert is_binary(msg.sent_at)
    end

    test "filters by from_handle substring" do
      {user_id, device_id} = seed_user("from-handle")

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("g1", %{
            "text" => "same topic",
            "sender_handle" => "charlie@example.com"
          }),
          sample_message("g2", %{
            "text" => "same topic",
            "sender_handle" => "dave@example.com",
            "chat_display_name" => "Dave"
          })
        ])

      assert {:ok, result} =
               Tools.execute("messages_search", %{
                 "user_id" => user_id,
                 "query" => "topic",
                 "from_handle" => "charlie"
               })

      assert result.count == 1
      [msg] = result.messages
      assert msg.sender_handle =~ "charlie"
    end

    test "includes resolved sender identity from People phone contacts" do
      {user_id, device_id} = seed_user("resolved-sender")
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, person} =
        Crm.upsert_person(user_id, %{
          "display_name" => "Charlie Smith",
          "phone" => "+1 (416) 526-1454"
        })

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("g-known-phone", %{
            "text" => "Can you send the pricing answer?",
            "sender_handle" => "+14165261454",
            "chat_display_name" => nil
          })
        ])

      assert {:ok, result} =
               Tools.execute("messages_search", %{
                 "user_id" => user_id,
                 "query" => "pricing"
               })

      [msg] = result.messages
      assert msg.sender_handle == "+14165261454"
      assert msg.sender_display_name == "Charlie Smith"
      assert msg.sender_person_id == person.id
    end

    test "filters by since and before window" do
      {user_id, device_id} = seed_user("date-range")

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("g-old", %{
            "text" => "common keyword",
            "sent_at" => "2026-04-01T10:00:00Z"
          }),
          sample_message("g-mid", %{
            "text" => "common keyword",
            "sent_at" => "2026-05-05T10:00:00Z"
          }),
          sample_message("g-new", %{
            "text" => "common keyword",
            "sent_at" => "2026-05-10T10:00:00Z"
          })
        ])

      assert {:ok, result} =
               Tools.execute("messages_search", %{
                 "user_id" => user_id,
                 "query" => "common keyword",
                 "since" => "2026-05-01T00:00:00Z",
                 "before" => "2026-05-09T00:00:00Z"
               })

      assert result.count == 1
      [msg] = result.messages
      assert msg.guid == "g-mid"
    end

    test "returns empty list when nothing matches" do
      {user_id, device_id} = seed_user("empty")

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("g1", %{"text" => "Something unrelated"})
        ])

      assert {:ok, result} =
               Tools.execute("messages_search", %{
                 "user_id" => user_id,
                 "query" => "nothing matches"
               })

      assert result.count == 0
      assert result.messages == []
    end

    test "rejects missing query" do
      {user_id, _device_id} = seed_user("missing-query")

      assert {:error, message} =
               Tools.execute("messages_search", %{"user_id" => user_id})

      assert message =~ "query is required"
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("messages_search", %{"query" => "hello"})
    end

    test "honors limit and clamps to max 50" do
      {user_id, device_id} = seed_user("limit")

      messages =
        for i <- 1..6 do
          sample_message("g-#{i}", %{
            "text" => "match #{i} common keyword",
            "sent_at" => "2026-05-10T1#{i}:00:00Z"
          })
        end

      {:ok, _} = LocalMessages.ingest_batch(user_id, device_id, messages)

      assert {:ok, %{count: 3}} =
               Tools.execute("messages_search", %{
                 "user_id" => user_id,
                 "query" => "common keyword",
                 "limit" => 3
               })
    end

    test "truncates long text snippets to 200 chars" do
      {user_id, device_id} = seed_user("snippet")

      long_text = String.duplicate("a", 250)

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          sample_message("g1", %{"text" => long_text})
        ])

      assert {:ok, result} =
               Tools.execute("messages_search", %{
                 "user_id" => user_id,
                 "query" => "aaa"
               })

      [msg] = result.messages
      assert String.length(msg.text_snippet) == 203
      assert String.ends_with?(msg.text_snippet, "...")
    end
  end
end
