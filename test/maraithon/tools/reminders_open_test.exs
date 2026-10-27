defmodule Maraithon.Tools.RemindersOpenTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Capabilities
  alias Maraithon.LocalReminders
  alias Maraithon.Tools

  defp sample_reminder(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "r:#{guid}",
        "guid" => guid,
        "title" => "thing",
        "list_name" => "Personal",
        "priority" => 0,
        "due_at" => "2026-05-12T10:00:00Z",
        "is_completed" => false,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp seed_user(label) do
    user_id = "rem-open-#{label}-#{System.unique_integer([:positive])}@example.com"
    device_id = Ecto.UUID.generate()
    {user_id, device_id}
  end

  describe "input_schema" do
    test "marks user_id as required, list_name and limit as optional" do
      schema = Capabilities.tool_descriptor("reminders_open").input_schema
      assert "user_id" in schema["required"]
      refute "list_name" in schema["required"]
      assert schema["properties"]["list_name"]["type"] == "string"
      assert schema["properties"]["limit"]["type"] == "integer"
    end
  end

  describe "execute/1" do
    test "returns open reminders ordered by due then priority, with priority_label" do
      {user_id, device_id} = seed_user("ordering")

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("a", %{
            "title" => "late",
            "due_at" => "2026-05-15T10:00:00Z"
          }),
          sample_reminder("b", %{
            "title" => "soon high",
            "due_at" => "2026-05-12T10:00:00Z",
            "priority" => 1
          })
        ])

      assert {:ok, result} =
               Tools.execute("reminders_open", %{"user_id" => user_id})

      assert result.source == "local_reminders"
      assert result.count == 2
      [first, second] = result.reminders
      assert first.title == "soon high"
      assert first.priority == 1
      assert first.priority_label == "high"
      assert second.title == "late"
      assert second.priority == 0
      assert second.priority_label == "none"
    end

    test "filters by list_name when provided" do
      {user_id, device_id} = seed_user("filter")

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("g1", %{"list_name" => "Work", "title" => "ship"}),
          sample_reminder("g2", %{"list_name" => "Personal", "title" => "shop"})
        ])

      assert {:ok, %{count: 1, list_name: "Work", reminders: [r]}} =
               Tools.execute("reminders_open", %{
                 "user_id" => user_id,
                 "list_name" => "Work"
               })

      assert r.title == "ship"
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("reminders_open", %{})
    end
  end
end
