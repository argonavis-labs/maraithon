defmodule Maraithon.LocalCalendarTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.LocalCalendar
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.Repo

  defp sample_event(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "evt:#{guid}",
        "guid" => guid,
        "calendar_name" => "Home",
        "calendar_color" => "#ff8800",
        "title" => "Coffee with Charlie",
        "notes" => "Talk through Q3 plan",
        "location" => "Java Hut",
        "start_at" => "2026-05-12T15:00:00Z",
        "end_at" => "2026-05-12T15:30:00Z",
        "is_all_day" => false,
        "is_recurring" => false,
        "organizer_email" => "kent@example.com",
        "attendees_count" => 2,
        "attendee_emails" => ["charlie@example.com", "kent@example.com"],
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp events_for(user_id, device_id) do
    Repo.all(
      from event in LocalEvent,
        where: event.user_id == ^user_id and event.device_id == ^device_id
    )
  end

  defp event_count(user_id, device_id) do
    Repo.aggregate(
      from(event in LocalEvent,
        where: event.user_id == ^user_id and event.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  describe "ingest_batch/3" do
    test "inserts a fresh batch and reports accepted counts" do
      user_id = "cal-ingest-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      events =
        for i <- 1..3 do
          sample_event("guid-#{i}", %{"title" => "event #{i}"})
        end

      {:ok, %{accepted: 3, duplicate: 0, invalid: 0}} =
        LocalCalendar.ingest_batch(user_id, device_id, events)

      stored = events_for(user_id, device_id)
      assert length(stored) == 3
      assert Enum.all?(stored, &(&1.user_id == user_id))
      assert Enum.all?(stored, &(&1.device_id == device_id))
      assert Enum.all?(stored, &(&1.title in ["event 1", "event 2", "event 3"]))
    end

    test "upserts existing events on re-send so reschedules stay current" do
      user_id = "cal-upsert-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      original = sample_event("g-a", %{"title" => "Original slot"})

      {:ok, %{accepted: 1, duplicate: 0}} =
        LocalCalendar.ingest_batch(user_id, device_id, [original])

      updated =
        sample_event("g-a", %{
          "title" => "Rescheduled slot",
          "location" => "Boardroom",
          "start_at" => "2026-05-12T18:00:00Z",
          "end_at" => "2026-05-12T18:45:00Z",
          "modified_at" => "2026-05-10T16:14:22Z"
        })

      {:ok, %{accepted: 1, duplicate: 0}} =
        LocalCalendar.ingest_batch(user_id, device_id, [updated])

      assert event_count(user_id, device_id) == 1
      [stored] = events_for(user_id, device_id)
      assert stored.title == "Rescheduled slot"
      assert stored.location == "Boardroom"
      assert stored.start_at == ~U[2026-05-12 18:00:00.000000Z]
      assert stored.end_at == ~U[2026-05-12 18:45:00.000000Z]
      assert stored.modified_at == ~U[2026-05-10 16:14:22.000000Z]
    end

    test "accepts long EventKit identifiers and long locations" do
      user_id = "cal-long-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()
      guid = String.duplicate("eventkit-identifier-", 18)
      location = String.duplicate("Long conference bridge location ", 20)

      {:ok, %{accepted: 1, duplicate: 0, invalid: 0}} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event(guid, %{
            "local_id" => "cal:#{guid}",
            "location" => location
          })
        ])

      [stored] = events_for(user_id, device_id)
      assert stored.guid == guid
      assert stored.local_id == "cal:#{guid}"
      assert stored.location == location
    end

    test "applies the default source when omitted" do
      user_id = "cal-source-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("g1") |> Map.delete("source")
        ])

      [stored] = events_for(user_id, device_id)
      assert stored.source == "calendar"
    end

    test "stores attendee_emails as an array and counts them" do
      user_id = "cal-att-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("g1", %{
            "attendee_emails" => ["a@example.com", "b@example.com", "c@example.com"],
            "attendees_count" => 3
          })
        ])

      [stored] = events_for(user_id, device_id)
      assert stored.attendee_emails == ["a@example.com", "b@example.com", "c@example.com"]
      assert stored.attendees_count == 3
    end

    test "derives attendees_count from list when omitted" do
      user_id = "cal-att-derive-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("g1", %{
            "attendee_emails" => ["x@example.com", "y@example.com"]
          })
          |> Map.delete("attendees_count")
        ])

      [stored] = events_for(user_id, device_id)
      assert stored.attendees_count == 2
    end
  end

  describe "events_around/2" do
    test "returns events that overlap the window, ordered by start_at" do
      user_id = "cal-around-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("past", %{
            "start_at" => "2026-05-01T10:00:00Z",
            "end_at" => "2026-05-01T11:00:00Z",
            "title" => "before-window"
          }),
          sample_event("now-1", %{
            "start_at" => "2026-05-12T10:00:00Z",
            "end_at" => "2026-05-12T11:00:00Z",
            "title" => "first-in-window"
          }),
          sample_event("now-2", %{
            "start_at" => "2026-05-13T10:00:00Z",
            "end_at" => "2026-05-13T11:00:00Z",
            "title" => "second-in-window"
          }),
          sample_event("future", %{
            "start_at" => "2026-12-01T10:00:00Z",
            "end_at" => "2026-12-01T11:00:00Z",
            "title" => "after-window"
          })
        ])

      since = ~U[2026-05-10 00:00:00.000000Z]
      until = ~U[2026-05-15 00:00:00.000000Z]

      results = LocalCalendar.events_around(user_id, since: since, until: until)
      titles = Enum.map(results, & &1.title)
      assert titles == ["first-in-window", "second-in-window"]
    end

    test "matches events whose end_at is in window even if start_at is before" do
      user_id = "cal-around-span-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("spans", %{
            "start_at" => "2026-05-10T08:00:00Z",
            "end_at" => "2026-05-12T08:00:00Z",
            "title" => "spans-window"
          })
        ])

      since = ~U[2026-05-11 00:00:00.000000Z]
      until = ~U[2026-05-13 00:00:00.000000Z]

      results = LocalCalendar.events_around(user_id, since: since, until: until)
      assert length(results) == 1
      assert hd(results).title == "spans-window"
    end

    test "honors a smaller limit" do
      user_id = "cal-around-limit-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      events =
        for i <- 1..5 do
          sample_event("g#{i}", %{
            "start_at" => "2026-05-12T1#{i}:00:00Z",
            "end_at" => "2026-05-12T1#{i}:30:00Z",
            "title" => "e#{i}"
          })
        end

      {:ok, _} = LocalCalendar.ingest_batch(user_id, device_id, events)

      since = ~U[2026-05-12 00:00:00.000000Z]
      until = ~U[2026-05-13 00:00:00.000000Z]

      results = LocalCalendar.events_around(user_id, since: since, until: until, limit: 2)
      assert length(results) == 2
    end
  end

  describe "events_for_attendee/3" do
    test "matches by exact email" do
      user_id = "cal-attendee-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("with-charlie", %{
            "title" => "1:1",
            "attendee_emails" => ["charlie@example.com", "kent@example.com"],
            "start_at" => "2026-05-12T10:00:00Z",
            "end_at" => "2026-05-12T10:30:00Z"
          }),
          sample_event("solo", %{
            "title" => "Focus",
            "attendee_emails" => ["kent@example.com"],
            "start_at" => "2026-05-13T10:00:00Z",
            "end_at" => "2026-05-13T11:00:00Z"
          })
        ])

      since = ~U[2026-05-01 00:00:00.000000Z]
      results = LocalCalendar.events_for_attendee(user_id, "charlie@example.com", since: since)
      assert length(results) == 1
      assert hd(results).title == "1:1"
    end

    test "matches case-insensitively against attendees, organizer, and title" do
      user_id = "cal-attendee-ci-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("title", %{
            "title" => "Sync with Diana",
            "attendee_emails" => [],
            "organizer_email" => "x@example.com",
            "start_at" => "2026-05-12T10:00:00Z",
            "end_at" => "2026-05-12T10:30:00Z"
          }),
          sample_event("organizer", %{
            "title" => "Generic",
            "attendee_emails" => [],
            "organizer_email" => "DIANA.boss@example.com",
            "start_at" => "2026-05-13T10:00:00Z",
            "end_at" => "2026-05-13T11:00:00Z"
          }),
          sample_event("none", %{
            "title" => "Other thing",
            "attendee_emails" => ["someone@else.com"],
            "organizer_email" => "another@else.com",
            "start_at" => "2026-05-14T10:00:00Z",
            "end_at" => "2026-05-14T11:00:00Z"
          })
        ])

      since = ~U[2026-05-01 00:00:00.000000Z]
      results = LocalCalendar.events_for_attendee(user_id, "diana", since: since)
      titles = Enum.map(results, & &1.title) |> Enum.sort()
      assert titles == ["Generic", "Sync with Diana"]
    end
  end

  describe "search/3" do
    test "matches substring on title, notes, and location" do
      user_id = "cal-search-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("by-title", %{
            "title" => "Launch review",
            "notes" => nil,
            "location" => "HQ",
            "start_at" => "2026-05-12T10:00:00Z",
            "end_at" => "2026-05-12T11:00:00Z"
          }),
          sample_event("by-notes", %{
            "title" => "Standup",
            "notes" => "Discuss launch milestones",
            "location" => "Office",
            "start_at" => "2026-05-13T10:00:00Z",
            "end_at" => "2026-05-13T10:30:00Z"
          }),
          sample_event("by-location", %{
            "title" => "Lunch",
            "notes" => "tasty",
            "location" => "Launch Cafe",
            "start_at" => "2026-05-14T10:00:00Z",
            "end_at" => "2026-05-14T11:00:00Z"
          }),
          sample_event("other", %{
            "title" => "Other",
            "notes" => "boring",
            "location" => "elsewhere",
            "start_at" => "2026-05-15T10:00:00Z",
            "end_at" => "2026-05-15T11:00:00Z"
          })
        ])

      since = ~U[2026-05-01 00:00:00.000000Z]
      results = LocalCalendar.search(user_id, "launch", since: since)
      titles = Enum.map(results, & &1.title) |> Enum.sort()
      assert titles == ["Launch review", "Lunch", "Standup"]
    end
  end

  describe "get_by_guid/2" do
    test "returns the event for the user and guid" do
      user_id = "cal-getby-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("uniq-1", %{"title" => "Specific"})
        ])

      event = LocalCalendar.get_by_guid(user_id, "uniq-1")
      refute is_nil(event)
      assert event.title == "Specific"
    end

    test "returns nil when nothing matches" do
      user_id = "cal-getby-miss-#{System.unique_integer([:positive])}@example.com"
      assert is_nil(LocalCalendar.get_by_guid(user_id, "nope"))
    end
  end

  describe "purge_device/2" do
    test "removes all rows for the (user, device) pair" do
      user_id = "cal-purge-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("g1"),
          sample_event("g2")
        ])

      assert event_count(user_id, device_id) == 2

      {:ok, %{deleted: 2}} = LocalCalendar.purge_device(user_id, device_id)

      assert event_count(user_id, device_id) == 0
    end
  end
end
