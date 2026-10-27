defmodule Maraithon.Tools.RemindersSemanticSearchTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Capabilities
  alias Maraithon.LocalReminders
  alias Maraithon.Tools

  defp seed_user(label) do
    email = "rem-sem-#{label}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {user.id, Ecto.UUID.generate()}
  end

  defp sample_reminder(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "r:#{guid}",
        "guid" => guid,
        "title" => "Untitled",
        "notes" => nil,
        "list_name" => "Personal",
        "priority" => 0,
        "is_completed" => false,
        "due_at" => nil,
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  describe "registration" do
    test "registered read-only with required user_id + query" do
      descriptor = Capabilities.tool_descriptor("reminders_semantic_search")
      assert descriptor.description =~ "Semantic search of the user's mirrored macOS Reminders"
      schema = descriptor.input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]

      policy = Tools.policy_metadata_for("reminders_semantic_search")
      assert policy.read_only? == true
    end
  end

  describe "execute/1" do
    test "ranks the most semantically-similar reminder first" do
      {user_id, device_id} = seed_user("rank")

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("r1", %{
            "title" => "Renew passport before international trip",
            "notes" => "passport expires next month international travel"
          }),
          sample_reminder("r2", %{
            "title" => "Buy birthday gift",
            "notes" => "card, wrapping paper"
          })
        ])

      assert {:ok, result} =
               Tools.execute("reminders_semantic_search", %{
                 "user_id" => user_id,
                 "query" => "passport renewal international travel"
               })

      assert result.source == "local_reminders"
      assert result.search_mode == "semantic"
      assert result.count >= 1
      [top | _] = result.reminders
      assert top.title == "Renew passport before international trip"
    end

    test "rejects missing query" do
      {user_id, _device_id} = seed_user("mq")

      assert {:error, message} =
               Tools.execute("reminders_semantic_search", %{"user_id" => user_id})

      assert message =~ "query is required"
    end
  end
end
