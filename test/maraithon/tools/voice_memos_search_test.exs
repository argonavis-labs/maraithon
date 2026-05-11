defmodule Maraithon.Tools.VoiceMemosSearchTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Capabilities
  alias Maraithon.LocalVoiceMemos
  alias Maraithon.Tools

  defp sample_memo(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "v:#{guid}",
        "guid" => guid,
        "title" => "Untitled memo",
        "snippet" => "no body",
        "duration_seconds" => 60,
        "file_size_bytes" => 51_200,
        "created_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  describe "input_schema" do
    test "marks user_id and query as required" do
      schema = Capabilities.tool_descriptor("voice_memos_search").input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]
    end
  end

  describe "execute/1" do
    test "returns matching memos by title substring" do
      user_id = "vm-search-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("v1", %{"title" => "Standup recap"}),
          sample_memo("v2", %{"title" => "Strategy idea"}),
          sample_memo("v3", %{"title" => "Grocery thoughts"})
        ])

      assert {:ok, result} =
               Tools.execute("voice_memos_search", %{
                 "user_id" => user_id,
                 "query" => "strategy"
               })

      assert result.source == "local_voice_memos"
      assert result.query == "strategy"
      assert result.count == 1
      [memo] = result.voice_memos
      assert memo.title == "Strategy idea"
      assert memo.guid == "v2"
      assert memo.duration_seconds == 60
      assert is_binary(memo.created_at)
    end

    test "returns empty list cleanly when no matches" do
      user_id = "vm-search-empty-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("v1", %{"title" => "Other"})
        ])

      assert {:ok, %{count: 0, voice_memos: []}} =
               Tools.execute("voice_memos_search", %{
                 "user_id" => user_id,
                 "query" => "no such memo"
               })
    end

    test "matches on transcript text and exposes transcript_snippet" do
      user_id = "vm-tx-search-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("v-tx", %{
            "title" => nil,
            "snippet" => nil,
            "transcript" => "remember the avocado toast investor pitch on monday"
          })
        ])

      assert {:ok, result} =
               Tools.execute("voice_memos_search", %{
                 "user_id" => user_id,
                 "query" => "avocado"
               })

      assert result.count == 1
      [memo] = result.voice_memos
      assert memo.guid == "v-tx"
      assert is_binary(memo.transcript_snippet)
      assert memo.transcript_snippet =~ "avocado"
    end

    test "rejects missing query" do
      assert {:error, message} =
               Tools.execute("voice_memos_search", %{"user_id" => "u"})

      assert message =~ "query is required"
    end
  end
end
