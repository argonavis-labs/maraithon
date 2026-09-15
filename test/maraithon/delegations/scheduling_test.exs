defmodule Maraithon.Delegations.SchedulingTest do
  use ExUnit.Case, async: true
  alias Maraithon.Delegations.{Preferences, Scheduling}

  @now ~U[2026-09-15 11:00:00Z]
  @window {~U[2026-09-15 12:00:00Z], ~U[2026-09-15 22:00:00Z]}

  defp prefs(attrs \\ %{}),
    do: Map.merge(Preferences.defaults(), Map.merge(%{"lead_time_hours" => 0}, attrs))

  test "buffered meetings leave only real free slots" do
    events = [%{start: ~U[2026-09-15 12:00:00Z], end: ~U[2026-09-15 13:00:00Z]}]

    assert {:ok, [first | _] = slots} =
             Scheduling.slots(events, %{window: @window}, prefs(), @now)

    assert first["start_at"] == "2026-09-15T13:15:00Z"
    assert first["end_at"] == "2026-09-15T13:45:00Z"
    assert length(slots) == 8
  end

  test "opaque all-day events block the user's local day" do
    event = %{start: %{date: "2026-09-15"}, end: %{date: "2026-09-16"}}
    assert {:ok, []} = Scheduling.slots([event], %{window: @window}, prefs(), @now)
  end

  test "transparent, cancelled and self-declined events do not consume capacity" do
    all_day = %{start: %{date: "2026-09-15"}, end: %{date: "2026-09-16"}}

    events = [
      Map.put(all_day, :transparency, "transparent"),
      Map.put(all_day, :status, "cancelled"),
      Map.put(all_day, :attendees, [%{self: true, response_status: "declined"}])
    ]

    assert {:ok, [first | _]} = Scheduling.slots(events, %{window: @window}, prefs(), @now)
    assert first["start_at"] == "2026-09-15T12:00:00Z"
  end

  test "an unreadable busy event prevents an availability claim" do
    assert {:error, :calendar_source_gap} =
             Scheduling.slots([%{start: "broken", end: nil}], %{window: @window}, prefs(), @now)
  end

  test "the daily meeting cap prevents more proposals" do
    event = %{start: ~U[2026-09-15 15:00:00Z], end: ~U[2026-09-15 16:00:00Z]}

    assert {:ok, []} =
             Scheduling.slots(
               [event],
               %{window: @window},
               prefs(%{"max_meetings_per_day" => 1}),
               @now
             )
  end

  test "lead time and a short remaining window cannot produce a partial slot" do
    assert {:ok, []} =
             Scheduling.slots([], %{window: @window}, prefs(%{"lead_time_hours" => 24}), @now)

    window = {~U[2026-09-15 21:45:00Z], ~U[2026-09-15 22:00:00Z]}
    assert {:ok, []} = Scheduling.slots([], %{window: window, duration_min: 30}, prefs(), @now)
  end

  test "local working hours survive the autumn DST change" do
    request = %{window: {~U[2026-10-30 00:00:00Z], ~U[2026-11-04 00:00:00Z]}}
    narrow = prefs(%{"work_start" => "09:00", "work_end" => "09:30", "buffer_min" => 0})
    assert {:ok, slots} = Scheduling.slots([], request, narrow, ~U[2026-10-29 00:00:00Z])

    assert Enum.map(slots, & &1["start_at"]) ==
             ["2026-10-30T13:00:00Z", "2026-11-02T14:00:00Z", "2026-11-03T14:00:00Z"]
  end

  test "an unbounded calendar window is rejected" do
    request = %{window: {@now, DateTime.add(@now, 32, :day)}}
    assert {:error, :invalid_scheduling_window} = Scheduling.slots([], request, prefs(), @now)
  end
end
