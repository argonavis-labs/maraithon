defmodule Maraithon.LocalFilesTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.LocalFiles
  alias Maraithon.LocalFiles.LocalFile
  alias Maraithon.Repo

  defp sample_file(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "~/Documents/Projects/notes.md",
        "guid" => guid,
        "path" => "~/Documents/Projects/notes.md",
        "filename" => "notes.md",
        "extension" => "md",
        "mime_type" => "text/markdown",
        "byte_size" => 4823,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp files_for(user_id, device_id) do
    Repo.all(
      from f in LocalFile,
        where: f.user_id == ^user_id and f.device_id == ^device_id
    )
  end

  defp file_count(user_id, device_id) do
    Repo.aggregate(
      from(f in LocalFile,
        where: f.user_id == ^user_id and f.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  describe "ingest_batch/3" do
    test "inserts a fresh batch and reports accepted counts" do
      user_id = "files-ingest-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      files =
        for i <- 1..3 do
          sample_file("guid-#{i}", %{"filename" => "f#{i}.md"})
        end

      {:ok, %{accepted: 3, duplicate: 0, invalid: 0}} =
        LocalFiles.ingest_batch(user_id, device_id, files)

      stored = files_for(user_id, device_id)
      assert length(stored) == 3
      assert Enum.all?(stored, &(&1.user_id == user_id))
      assert Enum.all?(stored, &(&1.source == "files"))
    end

    test "dedupes via the unique constraint on re-send" do
      user_id = "files-dedupe-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      files = [sample_file("g-a"), sample_file("g-b")]

      {:ok, %{accepted: 2, duplicate: 0}} =
        LocalFiles.ingest_batch(user_id, device_id, files)

      {:ok, %{accepted: 0, duplicate: 2}} =
        LocalFiles.ingest_batch(user_id, device_id, files)

      assert file_count(user_id, device_id) == 2
    end

    test "applies the default source when omitted" do
      user_id = "files-source-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g1") |> Map.delete("source")
        ])

      [stored] = files_for(user_id, device_id)
      assert stored.source == "files"
    end

    test "lower-cases extensions and strips leading dot" do
      user_id = "files-ext-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g1", %{"extension" => ".PDF"}),
          sample_file("g2", %{"extension" => "TXT"})
        ])

      stored = files_for(user_id, device_id)
      extensions = stored |> Enum.map(& &1.extension) |> Enum.sort()
      assert extensions == ["pdf", "txt"]
    end

    test "stores plain text content under the cap" do
      user_id = "files-text-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      body = "this is a markdown note with several plain words"

      {:ok, %{accepted: 1}} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g1", %{"text_content" => body})
        ])

      [stored] = files_for(user_id, device_id)
      assert stored.text_content == body
      assert stored.text_truncated == false
    end

    test "decodes base64 text_content_base64" do
      user_id = "files-b64-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      body = "Here is the extracted PDF body — multiple words."
      b64 = Base.encode64(body)

      {:ok, %{accepted: 1}} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g1", %{"text_content_base64" => b64})
        ])

      [stored] = files_for(user_id, device_id)
      assert stored.text_content == body
      assert stored.text_truncated == false
    end

    test "truncates oversize text and flags text_truncated" do
      user_id = "files-trunc-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      # 200 KB cap; build payload > cap.
      oversized = String.duplicate("a", 200 * 1024 + 1)
      b64 = Base.encode64(oversized)

      {:ok, %{accepted: 1}} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g-big", %{"text_content_base64" => b64})
        ])

      [stored] = files_for(user_id, device_id)
      assert is_nil(stored.text_content)
      assert stored.text_truncated == true
    end

    test "honors client text_truncated flag when no content present" do
      user_id = "files-cflag-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 1}} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g-flag", %{"text_truncated" => true})
        ])

      [stored] = files_for(user_id, device_id)
      assert is_nil(stored.text_content)
      assert stored.text_truncated == true
    end

    test "metadata-only rows (binary files) ingest cleanly" do
      user_id = "files-bin-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 1}} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g-img", %{
            "filename" => "screenshot.png",
            "extension" => "png",
            "mime_type" => "image/png",
            "byte_size" => 1_048_576
          })
          |> Map.delete("text_content")
        ])

      [stored] = files_for(user_id, device_id)
      assert stored.extension == "png"
      assert is_nil(stored.text_content)
      assert stored.text_truncated == false
    end

    test "tolerates nil filename / extension" do
      user_id = "files-nil-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 1}} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g1", %{"filename" => nil, "extension" => nil})
        ])

      [stored] = files_for(user_id, device_id)
      assert is_nil(stored.filename)
      assert is_nil(stored.extension)
    end
  end

  describe "recent_for_user/2" do
    test "returns files newest modified first" do
      user_id = "files-recent-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g1", %{
            "modified_at" => "2026-05-10T10:00:00Z",
            "filename" => "older.md"
          }),
          sample_file("g2", %{
            "modified_at" => "2026-05-10T12:00:00Z",
            "filename" => "newer.md"
          })
        ])

      [first, second] = LocalFiles.recent_for_user(user_id)
      assert first.filename == "newer.md"
      assert second.filename == "older.md"
    end

    test "filters by extension" do
      user_id = "files-ext-filter-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g1", %{"extension" => "md", "filename" => "note.md"}),
          sample_file("g2", %{"extension" => "pdf", "filename" => "spec.pdf"})
        ])

      results = LocalFiles.recent_for_user(user_id, extension: "pdf")
      assert length(results) == 1
      assert hd(results).filename == "spec.pdf"
    end
  end

  describe "search/3" do
    test "matches substring across filename and text_content" do
      user_id = "files-search-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g1", %{
            "filename" => "Morning rant.md",
            "text_content" => "talking about coffee and routines"
          }),
          sample_file("g2", %{
            "filename" => "Standup.md",
            "text_content" => "team blockers and dependencies"
          })
        ])

      results = LocalFiles.search(user_id, "blockers")
      assert length(results) == 1
      assert hd(results).filename == "Standup.md"

      results_case = LocalFiles.search(user_id, "MORNING")
      assert length(results_case) == 1
    end

    test "filters by path_substring" do
      user_id = "files-path-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g1", %{
            "path" => "~/Documents/Projects/notes.md",
            "filename" => "notes.md",
            "text_content" => "match here"
          }),
          sample_file("g2", %{
            "path" => "~/Downloads/notes.md",
            "filename" => "notes.md",
            "text_content" => "match here"
          })
        ])

      results = LocalFiles.search(user_id, "match", path_substring: "Documents")
      assert length(results) == 1
      assert String.contains?(hd(results).path, "Documents")
    end
  end

  describe "get_by_guid/2" do
    test "returns nil when no match" do
      user_id = "files-miss-#{System.unique_integer([:positive])}@example.com"
      assert is_nil(LocalFiles.get_by_guid(user_id, "nope"))
    end

    test "returns the row when matched" do
      user_id = "files-hit-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [sample_file("g1")])

      file = LocalFiles.get_by_guid(user_id, "g1")
      assert file.filename == "notes.md"
    end
  end

  describe "purge_device/2" do
    test "removes all rows for the (user, device) pair" do
      user_id = "files-purge-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("g1"),
          sample_file("g2")
        ])

      assert file_count(user_id, device_id) == 2

      {:ok, %{deleted: 2}} = LocalFiles.purge_device(user_id, device_id)
      assert file_count(user_id, device_id) == 0
    end
  end
end
