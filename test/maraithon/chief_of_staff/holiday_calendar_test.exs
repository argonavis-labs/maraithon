defmodule Maraithon.ChiefOfStaff.HolidayCalendarTest do
  use ExUnit.Case, async: true

  alias Maraithon.ChiefOfStaff.HolidayCalendar

  test "returns upcoming major holidays in order with concrete dates" do
    holidays = HolidayCalendar.upcoming(~D[2026-11-01], lookahead_days: 65)

    assert Enum.any?(holidays, &(&1["id"] == "thanksgiving_us_2026"))
    assert Enum.any?(holidays, &(&1["id"] == "christmas_day_2026"))
    assert Enum.any?(holidays, &(&1["id"] == "new_years_eve_2026"))

    thanksgiving = Enum.find(holidays, &(&1["id"] == "thanksgiving_us_2026"))
    christmas = Enum.find(holidays, &(&1["id"] == "christmas_day_2026"))

    assert thanksgiving["date"] == "2026-11-26"
    assert christmas["date"] == "2026-12-25"
    assert thanksgiving["days_until"] < christmas["days_until"]
  end

  test "includes movable spring holidays" do
    holidays = HolidayCalendar.upcoming(~D[2026-04-01], lookahead_days: 45)

    assert Enum.any?(holidays, &(&1["id"] == "good_friday_2026"))
    assert Enum.any?(holidays, &(&1["id"] == "easter_sunday_2026"))
    assert Enum.any?(holidays, &(&1["id"] == "mothers_day_2026"))

    easter = Enum.find(holidays, &(&1["id"] == "easter_sunday_2026"))
    mothers_day = Enum.find(holidays, &(&1["id"] == "mothers_day_2026"))

    assert easter["date"] == "2026-04-05"
    assert mothers_day["date"] == "2026-05-10"
  end
end
