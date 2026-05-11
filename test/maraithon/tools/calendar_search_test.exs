defmodule Maraithon.Tools.CalendarSearchTest do
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
    test "marks user_id and query as required" do
      schema = Capabilities.tool_descriptor("calendar_search").input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]
    end
  end

  describe "execute/1" do
    test "matches substring on title and notes" do
      user_id = "csearch-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("e1", %{
            "title" => "Launch review",
            "start_at" => "2026-05-12T10:00:00Z",
            "end_at" => "2026-05-12T11:00:00Z"
          }),
          sample_event("e2", %{
            "title" => "Standup",
            "notes" => "talk about launch plan",
            "start_at" => "2026-05-13T10:00:00Z",
            "end_at" => "2026-05-13T10:30:00Z"
          }),
          sample_event("other", %{
            "title" => "Off-site",
            "notes" => "nothing about that",
            "start_at" => "2026-05-14T10:00:00Z",
            "end_at" => "2026-05-14T11:00:00Z"
          })
        ])

      assert {:ok, result} =
               Tools.execute("calendar_search", %{
                 "user_id" => user_id,
                 "query" => "launch",
                 "since" => "2026-05-01T00:00:00Z"
               })

      assert result.source == "local_calendar"
      assert result.query == "launch"
      assert result.count == 2
      titles = Enum.map(result.events, & &1.title) |> Enum.sort()
      assert titles == ["Launch review", "Standup"]
    end

    test "rejects missing query" do
      assert {:error, message} =
               Tools.execute("calendar_search", %{"user_id" => "u"})

      assert message =~ "query is required"
    end
  end
end
