defmodule Maraithon.ChiefOfStaff.HolidayCalendar do
  @moduledoc """
  Curated major North American holiday and occasion calendar for Chief of Staff planning.
  """

  @default_lookahead_days 120

  def upcoming(%Date{} = from_date, opts \\ []) do
    lookahead_days = Keyword.get(opts, :lookahead_days, @default_lookahead_days)
    to_date = Date.add(from_date, lookahead_days)

    from_date.year..to_date.year
    |> Enum.flat_map(&holidays_for_year/1)
    |> Enum.filter(&date_in_range?(&1.date, from_date, to_date))
    |> Enum.sort_by(fn holiday -> {holiday.date, holiday.rank, holiday.name} end)
    |> Enum.map(&serialize_holiday(&1, from_date))
  end

  defp holidays_for_year(year) do
    easter = easter_sunday(year)

    [
      fixed_holiday(
        year,
        "new_years_day",
        "New Year's Day",
        1,
        1,
        ["north_america"],
        ["family", "travel", "hosting"],
        "Family plans, recovery, and long-weekend logistics can matter."
      ),
      fixed_holiday(
        year,
        "valentines_day",
        "Valentine's Day",
        2,
        14,
        ["north_america"],
        ["dinner", "gifts"],
        "Dinner reservations, flowers, and gifts tighten close to the date."
      ),
      nth_weekday_holiday(
        year,
        "family_day_ca",
        "Family Day",
        2,
        1,
        3,
        ["canada"],
        ["family", "travel"],
        "Long-weekend family plans and local trips may need lead time."
      ),
      relative_holiday(
        "good_friday",
        "Good Friday",
        Date.add(easter, -2),
        ["north_america"],
        ["family", "travel", "hosting"],
        "Holiday weekend logistics, meals, and travel can benefit from planning."
      ),
      relative_holiday(
        "easter_sunday",
        "Easter Sunday",
        easter,
        ["north_america"],
        ["family", "hosting", "gifts"],
        "Family meals, travel, and kid-focused plans may need some setup."
      ),
      nth_weekday_holiday(
        year,
        "mothers_day",
        "Mother's Day",
        5,
        7,
        2,
        ["north_america"],
        ["brunch", "dinner", "gifts"],
        "Brunch and dinner reservations, flowers, and gifts get harder close in."
      ),
      last_weekday_holiday(
        year,
        "memorial_day",
        "Memorial Day",
        5,
        1,
        ["us"],
        ["travel", "hosting"],
        "Long-weekend travel, hosting, and family plans can matter."
      ),
      nth_weekday_holiday(
        year,
        "fathers_day",
        "Father's Day",
        6,
        7,
        3,
        ["north_america"],
        ["meals", "gifts"],
        "Meals, tickets, and gifts can tighten as the day approaches."
      ),
      fixed_holiday(
        year,
        "canada_day",
        "Canada Day",
        7,
        1,
        ["canada"],
        ["travel", "hosting", "events"],
        "Travel, hosting, and local event plans can book up."
      ),
      fixed_holiday(
        year,
        "independence_day",
        "Independence Day",
        7,
        4,
        ["us"],
        ["travel", "hosting", "events"],
        "Travel, hosting, and event plans can fill up."
      ),
      nth_weekday_holiday(
        year,
        "labour_day",
        "Labour Day / Labor Day",
        9,
        1,
        1,
        ["north_america"],
        ["travel", "hosting"],
        "Long-weekend travel and hosting plans can need lead time."
      ),
      fixed_holiday(
        year,
        "halloween",
        "Halloween",
        10,
        31,
        ["north_america"],
        ["costumes", "hosting", "kids"],
        "Costumes, candy, parties, and kid logistics can sneak up."
      ),
      nth_weekday_holiday(
        year,
        "thanksgiving_ca",
        "Thanksgiving (Canada)",
        10,
        1,
        2,
        ["canada"],
        ["dinner", "travel", "hosting"],
        "Dinner reservations, hosting prep, and family travel usually need lead time."
      ),
      nth_weekday_holiday(
        year,
        "thanksgiving_us",
        "Thanksgiving (US)",
        11,
        4,
        4,
        ["us"],
        ["dinner", "travel", "hosting"],
        "Travel, hosting, and reservations usually need early coordination."
      ),
      fixed_holiday(
        year,
        "christmas_eve",
        "Christmas Eve",
        12,
        24,
        ["north_america"],
        ["travel", "hosting", "gifts"],
        "Shipping deadlines, travel, and family plans often need lead time."
      ),
      fixed_holiday(
        year,
        "christmas_day",
        "Christmas Day",
        12,
        25,
        ["north_america"],
        ["travel", "hosting", "gifts"],
        "Gifts, family schedules, and travel usually need early coordination."
      ),
      fixed_holiday(
        year,
        "new_years_eve",
        "New Year's Eve",
        12,
        31,
        ["north_america"],
        ["dinner", "events", "travel"],
        "Dinner reservations, event tickets, and travel plans can disappear quickly."
      )
    ]
  end

  defp fixed_holiday(year, id, name, month, day, markets, planning_tags, planning_note) do
    %{
      id: "#{id}_#{year}",
      name: name,
      date: Date.new!(year, month, day),
      markets: markets,
      planning_tags: planning_tags,
      planning_note: planning_note,
      rank: holiday_rank(id)
    }
  end

  defp nth_weekday_holiday(
         year,
         id,
         name,
         month,
         weekday,
         occurrence,
         markets,
         planning_tags,
         planning_note
       ) do
    %{
      id: "#{id}_#{year}",
      name: name,
      date: nth_weekday_of_month(year, month, weekday, occurrence),
      markets: markets,
      planning_tags: planning_tags,
      planning_note: planning_note,
      rank: holiday_rank(id)
    }
  end

  defp last_weekday_holiday(
         year,
         id,
         name,
         month,
         weekday,
         markets,
         planning_tags,
         planning_note
       ) do
    %{
      id: "#{id}_#{year}",
      name: name,
      date: last_weekday_of_month(year, month, weekday),
      markets: markets,
      planning_tags: planning_tags,
      planning_note: planning_note,
      rank: holiday_rank(id)
    }
  end

  defp relative_holiday(id, name, date, markets, planning_tags, planning_note) do
    %{
      id: "#{id}_#{date.year}",
      name: name,
      date: date,
      markets: markets,
      planning_tags: planning_tags,
      planning_note: planning_note,
      rank: holiday_rank(id)
    }
  end

  defp serialize_holiday(holiday, from_date) do
    %{
      "id" => holiday.id,
      "name" => holiday.name,
      "date" => Date.to_iso8601(holiday.date),
      "days_until" => Date.diff(holiday.date, from_date),
      "markets" => holiday.markets,
      "planning_tags" => holiday.planning_tags,
      "planning_note" => holiday.planning_note
    }
  end

  defp date_in_range?(date, from_date, to_date) do
    Date.compare(date, from_date) in [:eq, :gt] and Date.compare(date, to_date) in [:eq, :lt]
  end

  defp nth_weekday_of_month(year, month, weekday, occurrence) do
    first_of_month = Date.new!(year, month, 1)
    first_weekday = Date.day_of_week(first_of_month)
    offset = Integer.mod(weekday - first_weekday, 7)
    day = 1 + offset + 7 * (occurrence - 1)
    Date.new!(year, month, day)
  end

  defp last_weekday_of_month(year, month, weekday) do
    last_of_month = Date.end_of_month(Date.new!(year, month, 1))
    last_weekday = Date.day_of_week(last_of_month)
    offset = Integer.mod(last_weekday - weekday, 7)
    Date.add(last_of_month, -offset)
  end

  defp easter_sunday(year) do
    a = rem(year, 19)
    b = div(year, 100)
    c = rem(year, 100)
    d = div(b, 4)
    e = rem(b, 4)
    f = div(b + 8, 25)
    g = div(b - f + 1, 3)
    h = rem(19 * a + b - d - g + 15, 30)
    i = div(c, 4)
    k = rem(c, 4)
    l = rem(32 + 2 * e + 2 * i - h - k, 7)
    m = div(a + 11 * h + 22 * l, 451)
    month = div(h + l - 7 * m + 114, 31)
    day = rem(h + l - 7 * m + 114, 31) + 1
    Date.new!(year, month, day)
  end

  defp holiday_rank("christmas_eve"), do: 1
  defp holiday_rank("christmas_day"), do: 2
  defp holiday_rank("thanksgiving_us"), do: 3
  defp holiday_rank("thanksgiving_ca"), do: 4
  defp holiday_rank("mothers_day"), do: 5
  defp holiday_rank("fathers_day"), do: 6
  defp holiday_rank("valentines_day"), do: 7
  defp holiday_rank("new_years_eve"), do: 8
  defp holiday_rank(_id), do: 20
end
