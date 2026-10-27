defmodule Maraithon.Tools.VoiceMemosListRecentTest do
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
    test "marks only user_id as required" do
      schema = Capabilities.tool_descriptor("voice_memos_list_recent").input_schema
      assert schema["required"] == ["user_id"]
      assert schema["properties"]["limit"]["type"] == "integer"
    end
  end

  describe "execute/1" do
    test "orders newest created first and returns serialized summaries" do
      user_id = "vm-recent-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("v-old", %{
            "title" => "older",
            "created_at" => "2026-05-10T10:00:00Z"
          }),
          sample_memo("v-new", %{
            "title" => "newer",
            "created_at" => "2026-05-10T12:00:00Z",
            "duration_seconds" => 120,
            "file_size_bytes" => 200_000
          })
        ])

      assert {:ok, result} =
               Tools.execute("voice_memos_list_recent", %{"user_id" => user_id})

      assert result.source == "local_voice_memos"
      assert result.count == 2
      titles = Enum.map(result.voice_memos, & &1.title)
      assert titles == ["newer", "older"]
      first = hd(result.voice_memos)
      assert first.duration_seconds == 120
      assert first.file_size_bytes == 200_000
    end

    test "honors a smaller limit" do
      user_id = "vm-recent-limit-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      memos =
        for i <- 1..5 do
          sample_memo("v#{i}", %{
            "title" => "m#{i}",
            "created_at" => "2026-05-10T1#{i}:00:00Z"
          })
        end

      {:ok, _} = LocalVoiceMemos.ingest_batch(user_id, device_id, memos)

      assert {:ok, %{count: 2}} =
               Tools.execute("voice_memos_list_recent", %{
                 "user_id" => user_id,
                 "limit" => 2
               })
    end

    test "returns empty list cleanly when no memos exist" do
      user_id = "vm-recent-empty-#{System.unique_integer([:positive])}@example.com"

      assert {:ok, %{count: 0, voice_memos: []}} =
               Tools.execute("voice_memos_list_recent", %{"user_id" => user_id})
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("voice_memos_list_recent", %{})
    end
  end
end
