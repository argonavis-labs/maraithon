defmodule Maraithon.Tools.FilesSemanticSearchTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Capabilities
  alias Maraithon.LocalFiles
  alias Maraithon.Tools

  defp seed_user(label) do
    email = "files-sem-#{label}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {user.id, Ecto.UUID.generate()}
  end

  defp sample_file(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "~/Documents/#{guid}.md",
        "guid" => guid,
        "path" => "~/Documents/#{guid}.md",
        "filename" => "#{guid}.md",
        "extension" => "md",
        "mime_type" => "text/markdown",
        "byte_size" => 2048,
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  describe "registration" do
    test "registered with required query + user_id and read-only policy" do
      descriptor = Capabilities.tool_descriptor("files_semantic_search")
      assert descriptor.description =~ "Semantic search of the user's mirrored macOS files"
      schema = descriptor.input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]
      assert schema["properties"]["extension"]["type"] == "string"

      policy = Tools.policy_metadata_for("files_semantic_search")
      assert policy.read_only? == true
    end
  end

  describe "execute/1" do
    test "ranks the semantically-closest file first" do
      {user_id, device_id} = seed_user("rank")

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          sample_file("strategy", %{
            "filename" => "strategy.md",
            "text_content" =>
              "long-form strategy document for the company roadmap covering planning quarters revenue runway"
          }),
          sample_file("recipes", %{
            "filename" => "recipes.md",
            "text_content" => "pasta carbonara, eggs, bacon, parmesan"
          })
        ])

      assert {:ok, result} =
               Tools.execute("files_semantic_search", %{
                 "user_id" => user_id,
                 "query" => "company roadmap planning quarters"
               })

      assert result.source == "local_files"
      assert result.search_mode == "semantic"
      assert result.count >= 1
      [top | _] = result.files
      assert top.filename == "strategy.md"
    end

    test "returns empty when no files exist" do
      {user_id, _device_id} = seed_user("empty")

      assert {:ok, %{count: 0, files: []}} =
               Tools.execute("files_semantic_search", %{
                 "user_id" => user_id,
                 "query" => "anything"
               })
    end

    test "rejects missing query" do
      user_id = "files-sem-mq-#{System.unique_integer([:positive])}@example.com"

      assert {:error, message} =
               Tools.execute("files_semantic_search", %{"user_id" => user_id})

      assert message =~ "query is required"
    end
  end
end
