defmodule Maraithon.Tools.NotesSemanticSearchTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Capabilities
  alias Maraithon.LocalNotes
  alias Maraithon.Tools

  defp sample_note(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "n:#{guid}",
        "guid" => guid,
        "title" => "Untitled",
        "snippet" => "",
        "folder" => "Personal",
        "is_pinned" => false,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp seed_user(label) do
    email = "notes-sem-#{label}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    device_id = Ecto.UUID.generate()
    {user.id, device_id}
  end

  describe "registration" do
    test "registered with required query + user_id and read-only policy" do
      descriptor = Capabilities.tool_descriptor("notes_semantic_search")
      assert descriptor.description =~ "Semantic search of the user's mirrored macOS Notes"
      schema = descriptor.input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]

      policy = Tools.policy_metadata_for("notes_semantic_search")
      assert policy.read_only? == true
      assert policy.destructive? == false
    end
  end

  describe "execute/1" do
    test "returns the most semantically-similar note for a synonym-style query" do
      {user_id, device_id} = seed_user("similar")

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          sample_note("g1", %{
            "title" => "Wedding planning checklist",
            "snippet" => "venue, catering, invitations, music",
            "body" => "venue, catering, invitations, music, photographer"
          }),
          sample_note("g2", %{
            "title" => "Tax filing reminders",
            "snippet" => "W-2, deductions, deadlines",
            "body" => "W-2 forms, deductions, IRS deadlines"
          }),
          sample_note("g3", %{
            "title" => "Recipe ideas",
            "snippet" => "pasta, salad, soup",
            "body" => "pasta, salad, soup variations"
          })
        ])

      assert {:ok, result} =
               Tools.execute("notes_semantic_search", %{
                 "user_id" => user_id,
                 "query" => "wedding venue catering invitations music"
               })

      assert result.source == "local_notes"
      assert result.search_mode == "semantic"
      assert result.count >= 1
      titles = Enum.map(result.notes, & &1.title)
      assert "Wedding planning checklist" in titles
      # The wedding note should rank above the unrelated ones.
      assert List.first(result.notes).title == "Wedding planning checklist"
    end

    test "returns empty result list when no candidates exist" do
      {user_id, _device_id} = seed_user("empty")

      assert {:ok, result} =
               Tools.execute("notes_semantic_search", %{
                 "user_id" => user_id,
                 "query" => "anything"
               })

      assert result.count == 0
      assert result.notes == []
    end

    test "rejects missing query" do
      {user_id, _device_id} = seed_user("missing")

      assert {:error, message} =
               Tools.execute("notes_semantic_search", %{"user_id" => user_id})

      assert message =~ "query is required"
    end
  end
end
