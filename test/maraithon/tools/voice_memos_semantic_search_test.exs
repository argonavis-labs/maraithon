defmodule Maraithon.Tools.VoiceMemosSemanticSearchTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Capabilities
  alias Maraithon.LocalVoiceMemos
  alias Maraithon.Tools

  defp seed_user(label) do
    email = "vm-sem-#{label}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {user.id, Ecto.UUID.generate()}
  end

  defp sample_memo(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "v:#{guid}",
        "guid" => guid,
        "title" => "Untitled memo",
        "snippet" => "",
        "duration_seconds" => 60,
        "file_size_bytes" => 51_200,
        "created_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  describe "registration" do
    test "registered with required query + user_id and read-only policy" do
      descriptor = Capabilities.tool_descriptor("voice_memos_semantic_search")
      assert descriptor.description =~ "Semantic search of the user's mirrored macOS Voice Memos"
      schema = descriptor.input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]

      policy = Tools.policy_metadata_for("voice_memos_semantic_search")
      assert policy.read_only? == true
    end
  end

  describe "execute/1" do
    test "ranks the most semantically-similar memo first" do
      {user_id, device_id} = seed_user("rank")

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("v1", %{
            "title" => "Investor pitch ideas",
            "snippet" => "avocado toast monday meeting investor pitch",
            "transcript" => "avocado toast monday investor pitch slide deck"
          }),
          sample_memo("v2", %{
            "title" => "Grocery list",
            "snippet" => "milk eggs bread",
            "transcript" => "milk eggs bread cheese yogurt"
          })
        ])

      assert {:ok, result} =
               Tools.execute("voice_memos_semantic_search", %{
                 "user_id" => user_id,
                 "query" => "avocado toast investor pitch monday"
               })

      assert result.source == "local_voice_memos"
      assert result.search_mode == "semantic"
      assert result.count >= 1
      assert List.first(result.voice_memos).title == "Investor pitch ideas"
    end

    test "returns empty list when no candidate memos exist" do
      {user_id, _device_id} = seed_user("empty")

      assert {:ok, result} =
               Tools.execute("voice_memos_semantic_search", %{
                 "user_id" => user_id,
                 "query" => "anything"
               })

      assert result.count == 0
      assert result.voice_memos == []
    end

    test "rejects missing user_id" do
      assert {:error, _} =
               Tools.execute("voice_memos_semantic_search", %{"query" => "x"})
    end
  end
end
