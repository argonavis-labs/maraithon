defmodule Maraithon.Tools.CalendarEventsForPersonTest do
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
        "notes" => "",
        "location" => "Cafe",
        "start_at" => "2026-05-12T15:00:00Z",
        "end_at" => "2026-05-12T15:30:00Z",
        "is_all_day" => false,
        "is_recurring" => false,
        "attendee_emails" => []
      },
      overrides
    )
  end

  describe "input_schema" do
    test "marks user_id and email_or_substring as required" do
      schema = Capabilities.tool_descriptor("calendar_events_for_person").input_schema
      assert Enum.sort(schema["required"]) == ["email_or_substring", "user_id"]
    end
  end

  describe "execute/1" do
    test "returns events with the matching attendee" do
      user_id = "cefp-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("with-charlie", %{
            "title" => "1:1 with Charlie",
            "attendee_emails" => ["charlie@example.com"],
            "start_at" => "2026-05-12T10:00:00Z",
            "end_at" => "2026-05-12T10:30:00Z"
          }),
          sample_event("solo", %{
            "title" => "Focus",
            "attendee_emails" => [],
            "start_at" => "2026-05-13T10:00:00Z",
            "end_at" => "2026-05-13T11:00:00Z"
          })
        ])

      assert {:ok, result} =
               Tools.execute("calendar_events_for_person", %{
                 "user_id" => user_id,
                 "email_or_substring" => "charlie@example.com",
                 "since" => "2026-05-01T00:00:00Z"
               })

      assert result.source == "local_calendar"
      assert result.query == "charlie@example.com"
      assert result.count == 1
      [event] = result.events
      assert event.title == "1:1 with Charlie"
    end

    test "matches case-insensitively on substring" do
      user_id = "cefp-ci-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("via-title", %{
            "title" => "Sync with Diana",
            "attendee_emails" => [],
            "start_at" => "2026-05-12T10:00:00Z",
            "end_at" => "2026-05-12T10:30:00Z"
          })
        ])

      assert {:ok, %{count: 1}} =
               Tools.execute("calendar_events_for_person", %{
                 "user_id" => user_id,
                 "email_or_substring" => "DIANA",
                 "since" => "2026-05-01T00:00:00Z"
               })
    end

    test "rejects missing email_or_substring" do
      assert {:error, message} =
               Tools.execute("calendar_events_for_person", %{"user_id" => "u"})

      assert message =~ "email_or_substring is required"
    end
  end
end
