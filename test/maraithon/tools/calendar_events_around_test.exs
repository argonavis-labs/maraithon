defmodule Maraithon.Tools.CalendarEventsAroundTest do
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
    test "marks only user_id as required" do
      schema = Capabilities.tool_descriptor("calendar_events_around").input_schema
      assert schema["required"] == ["user_id"]
      assert schema["properties"]["since"]["type"] == "string"
      assert schema["properties"]["until"]["type"] == "string"
      assert schema["properties"]["limit"]["type"] == "integer"
    end
  end

  describe "execute/1" do
    test "returns events ordered by start_at within the given window" do
      user_id = "cea-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("e1", %{
            "title" => "earlier",
            "start_at" => "2026-05-12T09:00:00Z",
            "end_at" => "2026-05-12T10:00:00Z"
          }),
          sample_event("e2", %{
            "title" => "later",
            "start_at" => "2026-05-12T11:00:00Z",
            "end_at" => "2026-05-12T12:00:00Z"
          }),
          sample_event("outside", %{
            "title" => "skip",
            "start_at" => "2026-06-01T09:00:00Z",
            "end_at" => "2026-06-01T10:00:00Z"
          })
        ])

      assert {:ok, result} =
               Tools.execute("calendar_events_around", %{
                 "user_id" => user_id,
                 "since" => "2026-05-12T00:00:00Z",
                 "until" => "2026-05-13T00:00:00Z"
               })

      assert result.source == "local_calendar"
      assert result.count == 2
      titles = Enum.map(result.events, & &1.title)
      assert titles == ["earlier", "later"]
      assert hd(result.events).event_id == "e1"
    end

    test "honors a smaller limit" do
      user_id = "cea-limit-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      events =
        for i <- 1..4 do
          sample_event("g#{i}", %{
            "title" => "e#{i}",
            "start_at" => "2026-05-12T1#{i}:00:00Z",
            "end_at" => "2026-05-12T1#{i}:30:00Z"
          })
        end

      {:ok, _} = LocalCalendar.ingest_batch(user_id, device_id, events)

      assert {:ok, %{count: 2}} =
               Tools.execute("calendar_events_around", %{
                 "user_id" => user_id,
                 "since" => "2026-05-12T00:00:00Z",
                 "until" => "2026-05-13T00:00:00Z",
                 "limit" => 2
               })
    end

    test "returns empty cleanly when no matches" do
      user_id = "cea-empty-#{System.unique_integer([:positive])}@example.com"

      assert {:ok, %{count: 0, events: []}} =
               Tools.execute("calendar_events_around", %{"user_id" => user_id})
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("calendar_events_around", %{})
    end
  end
end
