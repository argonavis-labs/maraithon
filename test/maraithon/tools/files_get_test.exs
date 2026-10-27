defmodule Maraithon.Tools.FilesGetTest do
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
    test "marks user_id and file_id as required" do
      schema = Capabilities.tool_descriptor("files_get").input_schema
      assert Enum.sort(schema["required"]) == ["file_id", "user_id"]
    end
  end

  describe "execute/1" do
    test "returns the full record by guid" do
      user_id = "files-get-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("file-xyz", %{
            "filename" => "architecture.md",
            "text_content" => "thinking out loud about the system",
            "byte_size" => 1_048_576
          })
        ])

      assert {:ok, result} =
               Tools.execute("files_get", %{
                 "user_id" => user_id,
                 "file_id" => "file-xyz"
               })

      assert result.source == "local_files"
      file = result.file
      assert file.guid == "file-xyz"
      assert file.file_id == "file-xyz"
      assert file.filename == "architecture.md"
      assert file.text_content == "thinking out loud about the system"
      assert file.byte_size == 1_048_576
      assert file.text_truncated == false
      assert file.text_truncated_for_response == false
      assert is_binary(file.modified_at)
    end

    test "caps response text_content at 30 KB" do
      user_id = "files-cap-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      body = String.duplicate("a", 60_000)

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("file-big", %{
            "filename" => "big.md",
            "text_content" => body
          })
        ])

      assert {:ok, %{file: file}} =
               Tools.execute("files_get", %{
                 "user_id" => user_id,
                 "file_id" => "file-big"
               })

      assert byte_size(file.text_content) == 30 * 1024
      assert file.text_truncated_for_response == true
    end

    test "returns file_not_found when missing" do
      user_id = "files-miss-#{System.unique_integer([:positive])}@example.com"

      assert {:error, "file_not_found"} =
               Tools.execute("files_get", %{
                 "user_id" => user_id,
                 "file_id" => "nope"
               })
    end

    test "rejects missing args" do
      assert {:error, _} = Tools.execute("files_get", %{"user_id" => "u"})
      assert {:error, _} = Tools.execute("files_get", %{"file_id" => "f"})
    end
  end
end
