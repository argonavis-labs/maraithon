defmodule Maraithon.Tools.RemindersDueSoonTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Capabilities
  alias Maraithon.LocalReminders
  alias Maraithon.Tools

  defp sample_reminder(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "r:#{guid}",
        "guid" => guid,
        "title" => "task",
        "list_name" => "Personal",
        "priority" => 0,
        "is_completed" => false,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  describe "input_schema" do
    test "marks user_id as required" do
      schema = Capabilities.tool_descriptor("reminders_due_soon").input_schema
      assert "user_id" in schema["required"]
      assert schema["properties"]["days_ahead"]["type"] == "integer"
    end
  end

  describe "execute/1" do
    test "defaults to a 7-day window and returns overdue + upcoming" do
      user_id = "rem-due-tool-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      now = DateTime.utc_now()
      overdue = now |> DateTime.add(-86_400, :second) |> DateTime.to_iso8601()
      soon = now |> DateTime.add(86_400, :second) |> DateTime.to_iso8601()
      far = now |> DateTime.add(30 * 86_400, :second) |> DateTime.to_iso8601()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("o", %{"title" => "overdue", "due_at" => overdue}),
          sample_reminder("s", %{"title" => "soon", "due_at" => soon}),
          sample_reminder("f", %{"title" => "far", "due_at" => far})
        ])

      assert {:ok, %{count: 2, days_ahead: 7, reminders: rs}} =
               Tools.execute("reminders_due_soon", %{"user_id" => user_id})

      titles = Enum.map(rs, & &1.title)
      assert "overdue" in titles
      assert "soon" in titles
      refute "far" in titles
    end

    test "honors a custom days_ahead and clamps to 365" do
      user_id = "rem-due-window-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      now = DateTime.utc_now()
      far = now |> DateTime.add(60 * 86_400, :second) |> DateTime.to_iso8601()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("g1", %{"title" => "far", "due_at" => far})
        ])

      assert {:ok, %{days_ahead: 90, count: 1}} =
               Tools.execute("reminders_due_soon", %{
                 "user_id" => user_id,
                 "days_ahead" => 90
               })

      # Out-of-range value clamps down to 365.
      assert {:ok, %{days_ahead: 365}} =
               Tools.execute("reminders_due_soon", %{
                 "user_id" => user_id,
                 "days_ahead" => 10_000
               })
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("reminders_due_soon", %{})
    end
  end
end
