defmodule Maraithon.Tools.FilesListRecentTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Capabilities
  alias Maraithon.LocalFiles
  alias Maraithon.Tools

  defp sample_file(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "~/Documents/notes.md",
        "guid" => guid,
        "path" => "~/Documents/notes.md",
        "filename" => "notes.md",
        "extension" => "md",
        "mime_type" => "text/markdown",
        "byte_size" => 2048,
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  describe "input_schema" do
    test "marks only user_id as required" do
      schema = Capabilities.tool_descriptor("files_list_recent").input_schema
      assert schema["required"] == ["user_id"]
      assert schema["properties"]["limit"]["type"] == "integer"
      assert schema["properties"]["extension"]["type"] == "string"
    end
  end

  describe "execute/1" do
    test "orders newest modified first and returns serialized summaries" do
      user_id = "files-list-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("f-old", %{
            "filename" => "older.md",
            "modified_at" => "2026-05-10T10:00:00Z"
          }),
          sample_file("f-new", %{
            "filename" => "newer.md",
            "modified_at" => "2026-05-10T12:00:00Z",
            "byte_size" => 8192
          })
        ])

      assert {:ok, result} =
               Tools.execute("files_list_recent", %{"user_id" => user_id})

      assert result.source == "local_files"
      assert result.count == 2
      names = Enum.map(result.files, & &1.filename)
      assert names == ["newer.md", "older.md"]
      first = hd(result.files)
      assert first.byte_size == 8192
    end

    test "honors a smaller limit" do
      user_id = "files-limit-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      files =
        for i <- 1..5 do
          sample_file("f#{i}", %{
            "filename" => "f#{i}.md",
            "modified_at" => "2026-05-10T1#{i}:00:00Z"
          })
        end

      {:ok, _} = LocalFiles.ingest_batch(user_id, device_id, files)

      assert {:ok, %{count: 2}} =
               Tools.execute("files_list_recent", %{
                 "user_id" => user_id,
                 "limit" => 2
               })
    end

    test "filters by extension" do
      user_id = "files-list-ext-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("f1", %{"filename" => "spec.pdf", "extension" => "pdf"}),
          sample_file("f2", %{"filename" => "notes.md", "extension" => "md"}),
          sample_file("f3", %{"filename" => "doc.pdf", "extension" => "pdf"})
        ])

      assert {:ok, %{count: 2, files: files}} =
               Tools.execute("files_list_recent", %{
                 "user_id" => user_id,
                 "extension" => "pdf"
               })

      assert Enum.all?(files, &(&1.extension == "pdf"))
    end

    test "returns empty list cleanly when no files exist" do
      user_id = "files-list-empty-#{System.unique_integer([:positive])}@example.com"

      assert {:ok, %{count: 0, files: []}} =
               Tools.execute("files_list_recent", %{"user_id" => user_id})
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("files_list_recent", %{})
    end
  end
end
