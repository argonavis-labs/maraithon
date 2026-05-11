defmodule Maraithon.Tools.RemindersSearchTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Capabilities
  alias Maraithon.LocalReminders
  alias Maraithon.Tools

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

  describe "input_schema" do
    test "marks user_id and query as required" do
      schema = Capabilities.tool_descriptor("reminders_search").input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]
    end
  end

  describe "execute/1" do
    test "matches substring on title and notes (case-insensitive)" do
      user_id = "rem-search-tool-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("g1", %{"title" => "Pick up passport"}),
          sample_reminder("g2", %{
            "title" => "Call dentist",
            "notes" => "Ask about whitening"
          }),
          sample_reminder("g3", %{"title" => "Run errands"})
        ])

      assert {:ok, result} =
               Tools.execute("reminders_search", %{
                 "user_id" => user_id,
                 "query" => "passport"
               })

      assert result.source == "local_reminders"
      assert result.query == "passport"
      assert result.count == 1
      assert hd(result.reminders).title == "Pick up passport"

      assert {:ok, %{count: 1, reminders: [r]}} =
               Tools.execute("reminders_search", %{
                 "user_id" => user_id,
                 "query" => "WHITENING"
               })

      assert r.title == "Call dentist"
    end

    test "returns notes_snippet for matched reminders" do
      user_id = "rem-search-snippet-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()
      long_notes = String.duplicate("alpha ", 40) <> "needle " <> String.duplicate("omega ", 40)

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("g1", %{"title" => "Search me", "notes" => long_notes})
        ])

      assert {:ok, %{reminders: [r]}} =
               Tools.execute("reminders_search", %{
                 "user_id" => user_id,
                 "query" => "needle"
               })

      assert is_binary(r.notes_snippet)
      assert String.length(r.notes_snippet) <= 203
    end

    test "rejects missing args" do
      assert {:error, _} = Tools.execute("reminders_search", %{"user_id" => "u"})
      assert {:error, _} = Tools.execute("reminders_search", %{"query" => "x"})
    end
  end
end
