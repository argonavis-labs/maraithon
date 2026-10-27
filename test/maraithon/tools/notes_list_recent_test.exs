defmodule Maraithon.Tools.NotesListRecentTest do
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

  describe "input_schema" do
    test "marks only user_id as required" do
      schema = Capabilities.tool_descriptor("notes_list_recent").input_schema
      assert schema["required"] == ["user_id"]
      assert schema["properties"]["limit"]["type"] == "integer"
      assert schema["properties"]["folder"]["type"] == "string"
    end
  end

  describe "execute/1" do
    test "orders newest modified first and serializes summaries" do
      user_id = "notes-recent-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("g-old", %{
            "title" => "older",
            "modified_at" => "2026-05-10T10:00:00Z"
          }),
          sample_note("g-new", %{
            "title" => "newer",
            "modified_at" => "2026-05-10T12:00:00Z"
          })
        ])

      assert {:ok, result} =
               Tools.execute("notes_list_recent", %{"user_id" => user_id})

      assert result.source == "local_notes"
      assert result.count == 2
      titles = Enum.map(result.notes, & &1.title)
      assert titles == ["newer", "older"]
    end

    test "honors a smaller limit" do
      user_id = "notes-recent-limit-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      notes =
        for i <- 1..5 do
          sample_note("g#{i}", %{
            "title" => "n#{i}",
            "modified_at" => "2026-05-10T1#{i}:00:00Z"
          })
        end

      {:ok, _} = LocalNotes.ingest_batch(user_id, device_id, notes)

      assert {:ok, %{count: 2}} =
               Tools.execute("notes_list_recent", %{
                 "user_id" => user_id,
                 "limit" => 2
               })
    end

    test "filters by folder when supplied" do
      user_id = "notes-recent-folder-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("g1", %{"folder" => "Work", "title" => "work note"}),
          sample_note("g2", %{"folder" => "Personal", "title" => "personal note"})
        ])

      assert {:ok, result} =
               Tools.execute("notes_list_recent", %{
                 "user_id" => user_id,
                 "folder" => "Work"
               })

      assert result.folder == "Work"
      assert result.count == 1
      [note] = result.notes
      assert note.folder == "Work"
    end

    test "returns empty list cleanly when no notes exist" do
      user_id = "notes-recent-empty-#{System.unique_integer([:positive])}@example.com"

      assert {:ok, %{count: 0, notes: []}} =
               Tools.execute("notes_list_recent", %{"user_id" => user_id})
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("notes_list_recent", %{})
    end
  end
end
