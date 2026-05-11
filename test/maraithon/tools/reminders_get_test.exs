defmodule Maraithon.Tools.RemindersGetTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Capabilities
  alias Maraithon.LocalReminders
  alias Maraithon.Tools

  defp sample_reminder(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "r:#{guid}",
        "guid" => guid,
        "title" => "Pay bill",
        "notes" => "the rent",
        "list_name" => "Personal",
        "list_color" => "#FF3B30",
        "priority" => 5,
        "due_at" => "2026-05-12T10:00:00Z",
        "is_completed" => false,
        "has_alarm" => true,
        "url_attachment" => "https://example.com/pay",
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  describe "input_schema" do
    test "marks user_id and reminder_id as required" do
      schema = Capabilities.tool_descriptor("reminders_get").input_schema
      assert Enum.sort(schema["required"]) == ["reminder_id", "user_id"]
    end
  end

  describe "execute/1" do
    test "returns the full record by guid" do
      user_id = "rem-get-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [sample_reminder("rid-abc")])

      assert {:ok, result} =
               Tools.execute("reminders_get", %{
                 "user_id" => user_id,
                 "reminder_id" => "rid-abc"
               })

      assert result.source == "local_reminders"
      r = result.reminder
      assert r.guid == "rid-abc"
      assert r.reminder_id == "rid-abc"
      assert r.title == "Pay bill"
      assert r.notes == "the rent"
      assert r.list_name == "Personal"
      assert r.list_color == "#FF3B30"
      assert r.priority == 5
      assert r.priority_label == "medium"
      assert r.has_alarm == true
      assert r.url_attachment == "https://example.com/pay"
      assert is_binary(r.due_at)
      assert is_binary(r.created_at)
      assert is_binary(r.modified_at)
    end

    test "returns reminder_not_found when guid is missing" do
      user_id = "rem-get-miss-#{System.unique_integer([:positive])}@example.com"

      assert {:error, "reminder_not_found"} =
               Tools.execute("reminders_get", %{
                 "user_id" => user_id,
                 "reminder_id" => "does-not-exist"
               })
    end

    test "rejects missing args" do
      assert {:error, _} = Tools.execute("reminders_get", %{"user_id" => "u"})
      assert {:error, _} = Tools.execute("reminders_get", %{"reminder_id" => "r"})
    end
  end
end
