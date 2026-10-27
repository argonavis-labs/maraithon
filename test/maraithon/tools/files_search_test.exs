defmodule Maraithon.Tools.FilesSearchTest do
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
    test "marks user_id and query as required" do
      schema = Capabilities.tool_descriptor("files_search").input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]
      assert schema["properties"]["extension"]["type"] == "string"
      assert schema["properties"]["path_substring"]["type"] == "string"
    end
  end

  describe "execute/1" do
    test "returns matching files by content substring" do
      user_id = "files-search-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("f1", %{
            "filename" => "strategy.md",
            "text_content" => "long-form strategy document for the roadmap"
          }),
          sample_file("f2", %{
            "filename" => "groceries.md",
            "text_content" => "milk eggs bread"
          })
        ])

      assert {:ok, result} =
               Tools.execute("files_search", %{
                 "user_id" => user_id,
                 "query" => "roadmap"
               })

      assert result.source == "local_files"
      assert result.query == "roadmap"
      assert result.count == 1
      [file] = result.files
      assert file.filename == "strategy.md"
      assert file.guid == "f1"
      assert is_binary(file.text_content_snippet)
      assert file.text_content_snippet =~ "roadmap"
    end

    test "snippet caps at 200 characters" do
      user_id = "files-snip-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      body = String.duplicate("alphabet ", 60)

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("f1", %{
            "filename" => "long.md",
            "text_content" => body
          })
        ])

      assert {:ok, %{files: [file]}} =
               Tools.execute("files_search", %{
                 "user_id" => user_id,
                 "query" => "alphabet"
               })

      assert String.length(file.text_content_snippet) <= 201
      assert String.ends_with?(file.text_content_snippet, "…")
    end

    test "filters by extension" do
      user_id = "files-ext-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("f1", %{"filename" => "spec.pdf", "extension" => "pdf"}),
          sample_file("f2", %{"filename" => "notes.md", "extension" => "md"})
        ])

      assert {:ok, %{count: 1, files: [file]}} =
               Tools.execute("files_search", %{
                 "user_id" => user_id,
                 "query" => "spec",
                 "extension" => "pdf"
               })

      assert file.filename == "spec.pdf"
    end

    test "filters by path_substring" do
      user_id = "files-path-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("f1", %{
            "path" => "~/Documents/Projects/foo.md",
            "filename" => "foo.md",
            "text_content" => "match"
          }),
          sample_file("f2", %{
            "path" => "~/Downloads/foo.md",
            "filename" => "foo.md",
            "text_content" => "match"
          })
        ])

      assert {:ok, %{count: 1, files: [file]}} =
               Tools.execute("files_search", %{
                 "user_id" => user_id,
                 "query" => "match",
                 "path_substring" => "Projects"
               })

      assert String.contains?(file.path, "Projects")
    end

    test "returns empty list cleanly when no matches" do
      user_id = "files-empty-#{System.unique_integer([:positive])}@example.com"

      assert {:ok, %{count: 0, files: []}} =
               Tools.execute("files_search", %{
                 "user_id" => user_id,
                 "query" => "anything"
               })
    end

    test "rejects missing query" do
      assert {:error, message} =
               Tools.execute("files_search", %{"user_id" => "u"})

      assert message =~ "query is required"
    end
  end
end
