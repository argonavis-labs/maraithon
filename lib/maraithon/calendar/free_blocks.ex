defmodule Maraithon.Calendar.FreeBlocks do
  @moduledoc """
  Deterministic, calendar-source-agnostic free-block (opening) math (SPEC 06 R7).

  Extracted from `Maraithon.ChiefOfStaff.Skills.CalendarCheckIn`'s private
  `compute_openings/3` so both calendar surfaces share one implementation:
  the acquisition-fed proactive check-in (Google events via `SourceBundle`)
  and the `Maraithon.LocalCalendar`-fed reactive `get_today_focus` toolbox
  tool. A wrong gap subtraction is a trust bug ("you said I had 20 minutes,
  I only had 5"), so there is exactly one copy of this arithmetic.

  This module is pure interval math over already-fetched events. Callers own:

    * fetching + the "is this calendar actually connected?" honesty check
      (`SourceBundle.fetched?/2` on the proactive path, `SourceFreshness`
      desktop evidence on the reactive path) — an empty event list fed here
      is trusted as a genuinely open window;
    * timezone offset resolution — always a per-datetime, DST-aware offset
      from `Maraithon.Timezones.offset_at/3` (directly or via
      `Maraithon.BriefingSchedules.summarize_for_prompt/1`), never a second
      hardcoded default.

  Events are maps with `"start"`/`"end"` keys (string or atom) holding either
  `%DateTime{}` structs or ISO-8601 strings. All-day events (e.g. Google's
  `%{"date" => ...}` shape) do not parse into an interval and therefore never
  block timed work.
  """

  # Mirrors CalendarCheckIn's @default_work_day_end_hour — the shared sane
  # fallback (18:00 local) when a caller has no per-user skill config to read.
  @default_work_day_end_hour 18

  def default_work_day_end_hour, do: @default_work_day_end_hour

  @doc """
  Free stretches >= `:min_opening_minutes` between `max(now, work_start_utc)`
  and `:work_end_utc`, subtracting the given events' busy intervals.

  Required opts: `:work_start_utc`, `:work_end_utc`, `:min_opening_minutes`,
  `:offset` (integer hours), `:timezone` (display label, may be `nil`).

  Returns opening maps with the exact shape the calendar check-in has always
  produced: `"start"/"end"/"local_start"/"local_end"/"display_range"/
  "timezone"/"minutes"`.
  """
  def openings(events, %DateTime{} = now, opts) when is_list(events) and is_list(opts) do
    work_start_utc = Keyword.fetch!(opts, :work_start_utc)
    work_end_utc = Keyword.fetch!(opts, :work_end_utc)
    min_opening_minutes = Keyword.fetch!(opts, :min_opening_minutes)
    offset = Keyword.fetch!(opts, :offset)
    timezone = Keyword.get(opts, :timezone)

    window_start = latest(now, work_start_utc)
    window_end = work_end_utc

    if DateTime.compare(window_start, window_end) != :lt do
      []
    else
      busy =
        events
        |> Enum.map(&event_interval/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn {s, e} ->
          DateTime.compare(e, window_start) == :gt and DateTime.compare(s, window_end) == :lt
        end)
        |> Enum.sort_by(fn {s, _e} -> DateTime.to_unix(s, :microsecond) end)

      {openings, cursor} =
        Enum.reduce(busy, {[], window_start}, fn {s, e}, {acc, cursor} ->
          gap_end = earliest(s, window_end)

          acc = maybe_add_opening(acc, cursor, gap_end, offset, timezone, min_opening_minutes)

          {acc, latest(e, cursor)}
        end)

      openings
      |> maybe_add_opening(cursor, window_end, offset, timezone, min_opening_minutes)
      |> Enum.reverse()
    end
  end

  @doc """
  UTC instant for `hour`:00 local on `local_date` (the work-day start bound),
  using the same local->UTC formula `compute_openings/3` always used.
  """
  def work_day_start_utc(%Date{} = local_date, hour, offset)
      when is_integer(hour) and is_integer(offset) do
    local_date
    |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
    |> DateTime.add(-offset, :hour)
  end

  @doc """
  UTC instant for the work-day end bound on `local_date`. Hour 24 means
  end-of-day (23:59:59 local), preserved verbatim from the check-in skill.
  """
  def work_day_end_utc(%Date{} = local_date, hour, offset)
      when is_integer(hour) and is_integer(offset) do
    local_date
    |> work_day_end_datetime(hour)
    |> DateTime.add(-offset, :hour)
  end

  @doc """
  Deterministic next-meeting-prep (SPEC 06 R4): attaches a `"next_event"` key
  to each opening — the earliest event whose start is at or after the
  opening's end, serialized via `event_for_prompt/3` — or `nil` when no such
  event exists (last opening of the day). Pure post-processing, no model call.
  """
  def attach_next_events(openings, events, offset, timezone)
      when is_list(openings) and is_list(events) do
    intervals =
      events
      |> Enum.map(fn event -> {event_interval(event), event} end)
      |> Enum.reject(fn {interval, _event} -> is_nil(interval) end)

    Enum.map(openings, fn opening ->
      next_event =
        case coerce_datetime(read_any(opening, "end")) do
          %DateTime{} = end_at -> next_event_after(intervals, end_at, offset, timezone)
          _ -> nil
        end

      Map.put(opening, "next_event", next_event)
    end)
  end

  @doc """
  Prompt-facing serialization of a timed event: summary, local clock times,
  display range, location, organizer. `nil` for all-day/unparseable events.
  """
  def event_for_prompt(event, offset, timezone) when is_map(event) do
    case event_interval(event) do
      {start_at, end_at} ->
        %{
          "summary" => read_string(event, "summary", "Untitled event"),
          "local_start" => local_clock(start_at, offset),
          "local_end" => local_clock(end_at, offset),
          "display_time" => display_clock_range(start_at, end_at, offset, timezone),
          "timezone" => timezone,
          "location" => read_string(event, "location", nil),
          "organizer" => read_string(event, "organizer", nil)
        }

      nil ->
        nil
    end
  end

  def event_for_prompt(_event, _offset, _timezone), do: nil

  @doc """
  `{start, end}` DateTimes for a timed event, or `nil` for all-day events
  (which arrive as `%{"date" => ...}` and do not block timed work),
  unparseable values, or zero/negative-length intervals. Tolerates both
  `%DateTime{}` structs and ISO-8601 strings.
  """
  def event_interval(event) when is_map(event) do
    with %DateTime{} = start_at <- coerce_datetime(read_any(event, "start")),
         %DateTime{} = end_at <- coerce_datetime(read_any(event, "end")),
         :lt <- DateTime.compare(start_at, end_at) do
      {start_at, end_at}
    else
      _ -> nil
    end
  end

  def event_interval(_event), do: nil

  @doc "Local wall-clock ISO time (`\"14:30:00\"`) for a UTC datetime at a fixed hour offset."
  def local_clock(%DateTime{} = datetime, offset) do
    datetime
    |> DateTime.add(offset, :hour)
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_iso8601()
  end

  @doc "Compact display range (`\"11:00 AM-12:00 PM ET\"`) for a UTC interval."
  def display_clock_range(start_at, end_at, offset, timezone) when is_integer(offset) do
    start_label =
      start_at
      |> local_clock(offset)
      |> display_clock_label()

    end_label =
      end_at
      |> local_clock(offset)
      |> display_clock_label()

    compact_clock_range(start_label, end_label, timezone)
  end

  @doc false
  def compact_clock_range(start_label, end_label, timezone)
      when is_binary(start_label) and is_binary(end_label) do
    range =
      case {String.split(start_label, " "), String.split(end_label, " ")} do
        {[start_time, meridiem], [end_time, end_meridiem]} when meridiem == end_meridiem ->
          "#{start_time}-#{end_time} #{meridiem}"

        _ ->
          "#{start_label}-#{end_label}"
      end

    case normalize_string(timezone) do
      nil -> range
      timezone -> "#{range} #{timezone}"
    end
  end

  def compact_clock_range(_start_label, _end_label, _timezone), do: nil

  @doc false
  def display_clock_label(nil), do: nil

  def display_clock_label(value) when is_binary(value) do
    value
    |> clock_parts()
    |> case do
      nil ->
        nil

      {hour, minute} ->
        display_hour =
          case rem(hour, 12) do
            0 -> 12
            hour -> hour
          end

        meridiem = if hour < 12, do: "AM", else: "PM"
        "#{display_hour}:#{String.pad_leading(Integer.to_string(minute), 2, "0")} #{meridiem}"
    end
  end

  def display_clock_label(_value), do: nil

  # ==========================================================================
  # Internal helpers (moved verbatim from CalendarCheckIn)
  # ==========================================================================

  defp next_event_after(intervals, %DateTime{} = at, offset, timezone) do
    intervals
    |> Enum.filter(fn {{start_at, _end_at}, _event} ->
      DateTime.compare(start_at, at) != :lt
    end)
    |> Enum.min_by(
      fn {{start_at, _end_at}, _event} -> DateTime.to_unix(start_at, :microsecond) end,
      fn -> nil end
    )
    |> case do
      nil -> nil
      {_interval, event} -> event_for_prompt(event, offset, timezone)
    end
  end

  defp work_day_end_datetime(date, 24), do: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

  defp work_day_end_datetime(date, hour),
    do: DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")

  defp maybe_add_opening(acc, gap_start, gap_end, offset, timezone, min_minutes) do
    minutes = gap_end |> DateTime.diff(gap_start, :second) |> div(60)

    if minutes >= min_minutes do
      [
        %{
          "start" => DateTime.to_iso8601(gap_start),
          "end" => DateTime.to_iso8601(gap_end),
          "local_start" => local_clock(gap_start, offset),
          "local_end" => local_clock(gap_end, offset),
          "display_range" => display_clock_range(gap_start, gap_end, offset, timezone),
          "timezone" => timezone,
          "minutes" => minutes
        }
        | acc
      ]
    else
      acc
    end
  end

  defp coerce_datetime(%DateTime{} = value), do: value

  defp coerce_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp coerce_datetime(_value), do: nil

  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp clock_parts(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.split(":")
    |> case do
      [hour, minute | _] ->
        with {hour, ""} <- Integer.parse(hour),
             {minute, ""} <- Integer.parse(minute),
             true <- hour in 0..23,
             true <- minute in 0..59 do
          {hour, minute}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp clock_parts(_value), do: nil

  defp read_any(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, safe_existing_atom(key)))
  end

  defp read_any(_map, _key), do: nil

  defp read_string(map, key, default) when is_map(map) do
    case read_any(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      nil ->
        default

      value ->
        to_string(value)
    end
  end

  defp read_string(_map, _key, default), do: default

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp safe_existing_atom(key), do: key

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil
end
