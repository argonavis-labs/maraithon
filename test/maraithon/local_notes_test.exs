defmodule Maraithon.LocalNotesTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.LocalNotes
  alias Maraithon.LocalNotes.LocalNote
  alias Maraithon.Repo

  defp sample_note(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "n:1",
        "guid" => guid,
        "title" => "Grocery list",
        "snippet" => "Milk, eggs, bread",
        "folder" => "Personal",
        "is_pinned" => false,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp notes_for(user_id, device_id) do
    Repo.all(
      from note in LocalNote,
        where: note.user_id == ^user_id and note.device_id == ^device_id
    )
  end

  defp note_count(user_id, device_id) do
    Repo.aggregate(
      from(note in LocalNote,
        where: note.user_id == ^user_id and note.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  describe "ingest_batch/3" do
    test "inserts a fresh batch and reports accepted counts" do
      user_id = "notes-ingest-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      notes =
        for i <- 1..3 do
          sample_note("guid-#{i}", %{"title" => "note #{i}"})
        end

      {:ok, %{accepted: 3, duplicate: 0, invalid: 0}} =
        LocalNotes.ingest_batch(user_id, device_id, notes)

      stored = notes_for(user_id, device_id)
      assert length(stored) == 3
      assert Enum.all?(stored, &(&1.user_id == user_id))
      assert Enum.all?(stored, &(&1.device_id == device_id))
      assert Enum.all?(stored, &(&1.title in ["note 1", "note 2", "note 3"]))
    end

    test "dedupes via the unique constraint on re-send" do
      user_id = "notes-dedupe-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      notes = [sample_note("g-a"), sample_note("g-b")]

      {:ok, %{accepted: 2, duplicate: 0}} =
        LocalNotes.ingest_batch(user_id, device_id, notes)

      {:ok, %{accepted: 0, duplicate: 2}} =
        LocalNotes.ingest_batch(user_id, device_id, notes)

      assert note_count(user_id, device_id) == 2
    end

    test "applies the default source when omitted" do
      user_id = "notes-source-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("g1") |> Map.delete("source")
        ])

      [stored] = notes_for(user_id, device_id)
      assert stored.source == "notes"
    end
  end

  describe "recent_for_user/2" do
    test "returns notes newest modified first" do
      user_id = "notes-recent-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("g1", %{
            "modified_at" => "2026-05-10T10:00:00Z",
            "title" => "older"
          }),
          sample_note("g2", %{
            "modified_at" => "2026-05-10T12:00:00Z",
            "title" => "newer"
          })
        ])

      [first, second] = LocalNotes.recent_for_user(user_id)
      assert first.title == "newer"
      assert second.title == "older"
    end
  end

  describe "search/3" do
    test "matches substring on title and snippet" do
      user_id = "notes-search-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("g1", %{
            "title" => "Shopping list",
            "snippet" => "milk, eggs"
          }),
          sample_note("g2", %{
            "title" => "Trip notes",
            "snippet" => "passport, charger"
          }),
          sample_note("g3", %{
            "title" => "Book ideas",
            "snippet" => "sci-fi novel outline"
          })
        ])

      results = LocalNotes.search(user_id, "passport")
      assert length(results) == 1
      assert hd(results).title == "Trip notes"

      results_case = LocalNotes.search(user_id, "SHOPPING")
      assert length(results_case) == 1
      assert hd(results_case).title == "Shopping list"
    end

    test "matches substring on body content" do
      user_id = "notes-search-body-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("g1", %{
            "title" => "Shopping list",
            "snippet" => "milk",
            "body" => "Pick up sourdough on the way home"
          }),
          sample_note("g2", %{
            "title" => "Random",
            "snippet" => "stuff",
            "body" => "totally unrelated content here"
          })
        ])

      results = LocalNotes.search(user_id, "sourdough")
      assert length(results) == 1
      assert hd(results).title == "Shopping list"
    end
  end

  describe "body persistence" do
    test "stores body and body_format on ingest" do
      user_id = "notes-body-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      body = "Multi-line\nplain text body\nwith details."

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("body-g1", %{"body" => body, "body_format" => "plain"})
        ])

      [stored] = notes_for(user_id, device_id)
      assert stored.body == body
      assert stored.body_format == "plain"
    end

    test "defaults body_format to plain when omitted" do
      user_id = "notes-body-fmt-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("body-g1", %{"body" => "anything"})
        ])

      [stored] = notes_for(user_id, device_id)
      assert stored.body_format == "plain"
    end

    test "allows nil body for legacy / undecoded rows" do
      user_id = "notes-body-nil-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("body-nil") |> Map.delete("body")
        ])

      [stored] = notes_for(user_id, device_id)
      assert stored.body == nil
      assert stored.body_format == "plain"
    end
  end

  describe "purge_device/2" do
    test "removes all rows for the (user, device) pair" do
      user_id = "notes-purge-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("g1"),
          sample_note("g2")
        ])

      assert note_count(user_id, device_id) == 2

      {:ok, %{deleted: 2}} = LocalNotes.purge_device(user_id, device_id)

      assert note_count(user_id, device_id) == 0
    end
  end
end
