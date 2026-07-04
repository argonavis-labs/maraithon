defmodule Maraithon.Calendar.FreeBlocksTest do
  # DataCase (not ExUnit.Case) so the caller-parity test can drive the real
  # CalendarCheckIn.build_check_in_input/4, which reads todos/held items.
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Calendar.FreeBlocks
  alias Maraithon.ChiefOfStaff.Skills.CalendarCheckIn

  # Wednesday; 15:00 UTC = 10:00 local at -5.
  @date ~D[2026-05-13]
  @now DateTime.new!(@date, ~T[15:00:00], "Etc/UTC")
  @offset -5
  @timezone "UTC-05:00"

  defp opening_opts(overrides \\ []) do
    Keyword.merge(
      [
        work_start_utc: FreeBlocks.work_day_start_utc(@date, 9, @offset),
        work_end_utc: FreeBlocks.work_day_end_utc(@date, 18, @offset),
        min_opening_minutes: 45,
        offset: @offset,
        timezone: @timezone
      ],
      overrides
    )
  end

  defp event(start_time, end_time, extra \\ %{}) do
    Map.merge(
      %{
        "summary" => "Meeting",
        "start" => DateTime.new!(@date, start_time, "Etc/UTC") |> DateTime.to_iso8601(),
        "end" => DateTime.new!(@date, end_time, "Etc/UTC") |> DateTime.to_iso8601()
      },
      extra
    )
  end

  test "subtracts busy intervals and returns the check-in opening shape" do
    openings = FreeBlocks.openings([event(~T[16:00:00], ~T[17:00:00])], @now, opening_opts())

    assert [first, second] = openings

    assert first["start"] == "2026-05-13T15:00:00Z"
    assert first["end"] == "2026-05-13T16:00:00Z"
    assert first["local_start"] == "10:00:00"
    assert first["local_end"] == "11:00:00"
    assert first["display_range"] == "10:00-11:00 AM UTC-05:00"
    assert first["timezone"] == @timezone
    assert first["minutes"] == 60

    assert second["local_start"] == "12:00:00"
    assert second["minutes"] == 360
  end

  test "accepts DateTime structs and ISO strings interchangeably" do
    iso = FreeBlocks.openings([event(~T[16:00:00], ~T[17:00:00])], @now, opening_opts())

    struct_events = [
      %{
        "summary" => "Meeting",
        "start" => DateTime.new!(@date, ~T[16:00:00], "Etc/UTC"),
        "end" => DateTime.new!(@date, ~T[17:00:00], "Etc/UTC")
      }
    ]

    assert FreeBlocks.openings(struct_events, @now, opening_opts()) == iso
  end

  test "all-day events never block timed work and short gaps are dropped" do
    all_day = %{"summary" => "Offsite", "start" => %{"date" => "2026-05-13"}, "end" => %{"date" => "2026-05-14"}}

    assert [_single_giant_opening] = FreeBlocks.openings([all_day], @now, opening_opts())

    # 30-minute gap under a 45-minute floor disappears.
    tight = [event(~T[15:30:00], ~T[23:00:00])]
    assert FreeBlocks.openings(tight, @now, opening_opts()) == []
    assert [_short] = FreeBlocks.openings(tight, @now, opening_opts(min_opening_minutes: 15))
  end

  test "returns no openings once the window has closed" do
    late = DateTime.new!(@date, ~T[23:30:00], "Etc/UTC")
    assert FreeBlocks.openings([], late, opening_opts()) == []
  end

  test "work-day end hour 24 means local end of day" do
    end_utc = FreeBlocks.work_day_end_utc(@date, 24, @offset)
    assert end_utc == DateTime.new!(~D[2026-05-14], ~T[04:59:59], "Etc/UTC")
  end

  test "attach_next_events points each opening at the meeting right after it" do
    events = [
      event(~T[16:00:00], ~T[17:00:00], %{"summary" => "Pricing sync", "location" => "Zoom"})
    ]

    [first, second] =
      events
      |> FreeBlocks.openings(@now, opening_opts())
      |> FreeBlocks.attach_next_events(events, @offset, @timezone)

    assert first["next_event"]["summary"] == "Pricing sync"
    assert first["next_event"]["local_start"] == "11:00:00"
    assert first["next_event"]["location"] == "Zoom"
    # Last opening of the day has nothing after it.
    assert second["next_event"] == nil
  end

  # SPEC 06 R7 acceptance: identical event/now/work-day inputs produce
  # identical openings regardless of which caller invokes the shared math —
  # here, direct FreeBlocks vs. the proactive CalendarCheckIn path.
  test "check-in path returns identical openings to a direct FreeBlocks call" do
    user_id = "free-blocks-parity-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    events = [event(~T[16:00:00], ~T[17:00:00]), event(~T[19:00:00], ~T[20:30:00])]

    state = CalendarCheckIn.init(%{"user_id" => user_id})

    context = %{
      user_id: user_id,
      timestamp: @now,
      trigger: %{type: :wakeup},
      source_bundle: %{
        "calendar" => %{"events" => events},
        "freshness" => %{"calendar" => %{"source" => "calendar", "status" => "ready"}}
      }
    }

    check_in_openings =
      CalendarCheckIn.build_check_in_input(user_id, @now, state, context)
      |> Map.fetch!("openings")
      |> Enum.map(&Map.delete(&1, "next_event"))

    direct_openings =
      FreeBlocks.openings(events, @now,
        work_start_utc: FreeBlocks.work_day_start_utc(@date, state.work_day_start_hour, @offset),
        work_end_utc: FreeBlocks.work_day_end_utc(@date, state.work_day_end_hour, @offset),
        min_opening_minutes: state.min_opening_minutes,
        offset: @offset,
        timezone: @timezone
      )

    assert check_in_openings == direct_openings
    assert length(direct_openings) == 3
  end
end
