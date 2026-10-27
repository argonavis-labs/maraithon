defmodule Maraithon.Tools.CalendarEventGetTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Capabilities
  alias Maraithon.LocalCalendar
  alias Maraithon.Tools

  defp sample_event(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "evt:#{guid}",
        "guid" => guid,
        "calendar_name" => "Home",
        "title" => "Coffee",
        "notes" => "remember the deck",
        "location" => "Cafe",
        "start_at" => "2026-05-12T15:00:00Z",
        "end_at" => "2026-05-12T15:30:00Z",
        "is_all_day" => false,
        "is_recurring" => false,
        "organizer_email" => "host@example.com",
        "attendees_count" => 2,
        "attendee_emails" => ["a@example.com", "b@example.com"]
      },
      overrides
    )
  end

  describe "input_schema" do
    test "marks user_id and event_id as required" do
      schema = Capabilities.tool_descriptor("calendar_event_get").input_schema
      assert Enum.sort(schema["required"]) == ["event_id", "user_id"]
    end
  end

  describe "execute/1" do
    test "returns the full record by guid including attendees and notes" do
      user_id = "ceget-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("evt-xyz")
        ])

      assert {:ok, result} =
               Tools.execute("calendar_event_get", %{
                 "user_id" => user_id,
                 "event_id" => "evt-xyz"
               })

      assert result.source == "local_calendar"
      event = result.event
      assert event.event_id == "evt-xyz"
      assert event.guid == "evt-xyz"
      assert event.title == "Coffee"
      assert event.notes == "remember the deck"
      assert event.organizer_email == "host@example.com"
      assert event.attendees_count == 2
      assert event.attendee_emails == ["a@example.com", "b@example.com"]
      assert is_binary(event.start_at)
    end

    test "returns calendar_event_not_found when missing" do
      user_id = "ceget-miss-#{System.unique_integer([:positive])}@example.com"

      assert {:error, "calendar_event_not_found"} =
               Tools.execute("calendar_event_get", %{
                 "user_id" => user_id,
                 "event_id" => "nope"
               })
    end

    test "rejects missing args" do
      assert {:error, _} = Tools.execute("calendar_event_get", %{"user_id" => "u"})
      assert {:error, _} = Tools.execute("calendar_event_get", %{"event_id" => "e"})
    end
  end
end
