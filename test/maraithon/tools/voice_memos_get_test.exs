defmodule Maraithon.Tools.VoiceMemosGetTest do
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
    test "marks user_id and memo_id as required" do
      schema = Capabilities.tool_descriptor("voice_memos_get").input_schema
      assert Enum.sort(schema["required"]) == ["memo_id", "user_id"]
    end
  end

  describe "execute/1" do
    test "returns the full record by guid" do
      user_id = "vm-get-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("memo-xyz", %{
            "title" => "Architecture rant",
            "snippet" => "thinking out loud",
            "duration_seconds" => 240,
            "file_size_bytes" => 1_048_576
          })
        ])

      assert {:ok, result} =
               Tools.execute("voice_memos_get", %{
                 "user_id" => user_id,
                 "memo_id" => "memo-xyz"
               })

      assert result.source == "local_voice_memos"
      memo = result.voice_memo
      assert memo.guid == "memo-xyz"
      assert memo.memo_id == "memo-xyz"
      assert memo.title == "Architecture rant"
      assert memo.snippet == "thinking out loud"
      assert memo.duration_seconds == 240
      assert memo.file_size_bytes == 1_048_576
      assert is_binary(memo.created_at)
    end

    test "returns voice_memo_not_found when missing" do
      user_id = "vm-get-miss-#{System.unique_integer([:positive])}@example.com"

      assert {:error, "voice_memo_not_found"} =
               Tools.execute("voice_memos_get", %{
                 "user_id" => user_id,
                 "memo_id" => "nope"
               })
    end

    test "rejects missing args" do
      assert {:error, _} = Tools.execute("voice_memos_get", %{"user_id" => "u"})
      assert {:error, _} = Tools.execute("voice_memos_get", %{"memo_id" => "m"})
    end
  end
end
