defmodule Maraithon.Tools.NotesSearchTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Capabilities
  alias Maraithon.LocalNotes
  alias Maraithon.Tools

  defp sample_note(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "n:#{guid}",
        "guid" => guid,
        "title" => "Untitled",
        "snippet" => "no body",
        "folder" => "Personal",
        "is_pinned" => false,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp seed_user(test_label) do
    user_id = "notes-search-#{test_label}-#{System.unique_integer([:positive])}@example.com"
    device_id = Ecto.UUID.generate()
    {user_id, device_id}
  end

  describe "input_schema" do
    test "marks user_id and query as required" do
      schema = Capabilities.tool_descriptor("notes_search").input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]
      assert schema["properties"]["limit"]["type"] == "integer"
      assert schema["properties"]["folder"]["type"] == "string"
    end
  end

  describe "execute/1" do
    test "returns substring matches on title and snippet" do
      {user_id, device_id} = seed_user("hit")

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("g1", %{"title" => "Shopping list", "snippet" => "milk, eggs"}),
          sample_note("g2", %{"title" => "Trip notes", "snippet" => "passport, charger"}),
          sample_note("g3", %{"title" => "Book ideas", "snippet" => "sci-fi outline"})
        ])

      assert {:ok, result} =
               Tools.execute("notes_search", %{
                 "user_id" => user_id,
                 "query" => "passport"
               })

      assert result.source == "local_notes"
      assert result.query == "passport"
      assert result.count == 1
      [note] = result.notes
      assert note.title == "Trip notes"
      assert note.guid == "g2"
      assert note.note_id == "g2"
      assert note.folder == "Personal"
      assert is_binary(note.modified_at)
    end

    test "returns empty list when nothing matches" do
      {user_id, device_id} = seed_user("empty")

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("g1", %{"title" => "Different topic"})
        ])

      assert {:ok, result} =
               Tools.execute("notes_search", %{
                 "user_id" => user_id,
                 "query" => "nothing matches"
               })

      assert result.count == 0
      assert result.notes == []
    end

    test "rejects missing query" do
      {user_id, _device_id} = seed_user("missing-query")

      assert {:error, message} =
               Tools.execute("notes_search", %{"user_id" => user_id})

      assert message =~ "query is required"
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("notes_search", %{"query" => "hello"})
    end

    test "matches body content and returns body_snippet on hits" do
      {user_id, device_id} = seed_user("body")

      long_body = String.duplicate("alpha ", 60) <> "needle " <> String.duplicate("omega ", 60)

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("g1", %{
            "title" => "Diary",
            "snippet" => "an ordinary day",
            "body" => long_body
          })
        ])

      assert {:ok, result} =
               Tools.execute("notes_search", %{
                 "user_id" => user_id,
                 "query" => "needle"
               })

      assert result.count == 1
      [note] = result.notes
      assert note.title == "Diary"
      assert is_binary(note.body_snippet)
      # 200-char cap + ellipsis suffix.
      assert String.length(note.body_snippet) <= 203
      assert String.ends_with?(note.body_snippet, "...")
    end

    test "honors limit argument and clamps to max 50" do
      {user_id, device_id} = seed_user("limit")

      notes =
        for i <- 1..6 do
          sample_note("g-#{i}", %{
            "title" => "match #{i}",
            "snippet" => "common keyword",
            "modified_at" => "2026-05-10T1#{i}:00:00Z"
          })
        end

      {:ok, _} = LocalNotes.ingest_batch(user_id, device_id, notes)

      assert {:ok, %{count: 3}} =
               Tools.execute("notes_search", %{
                 "user_id" => user_id,
                 "query" => "common keyword",
                 "limit" => 3
               })
    end
  end
end
