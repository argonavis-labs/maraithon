defmodule Maraithon.Tools.NotesGetTest do
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
    test "marks user_id and note_id as required" do
      schema = Capabilities.tool_descriptor("notes_get").input_schema
      assert Enum.sort(schema["required"]) == ["note_id", "user_id"]
    end
  end

  describe "execute/1" do
    test "returns the full record by guid" do
      user_id = "notes-get-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("note-abc", %{
            "title" => "Birthday plan",
            "snippet" => "cake, candles, invites",
            "folder" => "Family",
            "is_pinned" => true
          })
        ])

      assert {:ok, result} =
               Tools.execute("notes_get", %{
                 "user_id" => user_id,
                 "note_id" => "note-abc"
               })

      assert result.source == "local_notes"
      note = result.note
      assert note.guid == "note-abc"
      assert note.note_id == "note-abc"
      assert note.title == "Birthday plan"
      assert note.snippet == "cake, candles, invites"
      assert note.folder == "Family"
      assert note.is_pinned == true
      assert is_binary(note.modified_at)
      # Body fields ship even when no body was synced — body is nil,
      # body_format defaults to "plain" so renderers can branch safely.
      assert Map.has_key?(note, :body)
      assert note.body_format == "plain"
    end

    test "returns the decoded body when present" do
      user_id = "notes-get-body-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()
      body = "First line of the note.\n\nSecond paragraph here."

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("note-body", %{
            "title" => "With body",
            "body" => body,
            "body_format" => "plain"
          })
        ])

      assert {:ok, result} =
               Tools.execute("notes_get", %{
                 "user_id" => user_id,
                 "note_id" => "note-body"
               })

      assert result.note.body == body
      assert result.note.body_format == "plain"
    end

    test "returns note_not_found when guid is missing" do
      user_id = "notes-get-miss-#{System.unique_integer([:positive])}@example.com"

      assert {:error, "note_not_found"} =
               Tools.execute("notes_get", %{
                 "user_id" => user_id,
                 "note_id" => "does-not-exist"
               })
    end

    test "rejects missing args" do
      assert {:error, _} = Tools.execute("notes_get", %{"user_id" => "u"})
      assert {:error, _} = Tools.execute("notes_get", %{"note_id" => "n"})
    end
  end
end
