defmodule Maraithon.Delegations.Scheduling do
  @moduledoc "Bounded calendar reads and deterministic slots shared by proposals and booking."
  alias Maraithon.Calendar.FreeBlocks
  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.Delegations.Preferences

  @max_days 31

  def propose_slots(user_id, %{window: {first, last}} = request) do
    prefs = Preferences.get(user_id)
    now = DateTime.utc_now()

    with :ok <- valid_window(first, last),
         {:ok, ids} <- account_ids(user_id, prefs, request[:default_account_id]),
         {:ok, events} <- read_accounts(user_id, ids, first, last),
         {:ok, slots} <- slots(events, request, prefs, now) do
      {:ok,
       %{
         "slots" => slots,
         "coverage" => %{
           "account_ids" => ids,
           "read_at" => DateTime.to_iso8601(now),
           "from" => DateTime.to_iso8601(first),
           "until" => DateTime.to_iso8601(last),
           "complete" => true
         }
       }}
    end
  end

  @doc "Pure slot calculation over a complete read. Opaque all-day events block their local dates."
  def slots(events, %{window: {first, last}} = request, prefs, now) do
    duration = Map.get(request, :duration_min, prefs["default_duration_min"])

    with :ok <- valid_window(first, last),
         true <- is_integer(duration) and duration in 5..240,
         {:ok, busy} <- busy_events(events, prefs) do
      start_date = Preferences.local_time(first, prefs) |> DateTime.to_date()
      end_date = Preferences.local_time(last, prefs) |> DateTime.to_date()
      earliest = DateTime.add(now, prefs["lead_time_hours"], :hour) |> later(first)
      buffer = prefs["buffer_min"] * 60

      padded =
        Enum.map(busy, fn event ->
          %{start: DateTime.add(event.start, -buffer), end: DateTime.add(event.end, buffer)}
        end)

      slots =
        Date.range(start_date, end_date)
        |> Enum.filter(&(Date.day_of_week(&1) in prefs["work_days"]))
        |> Enum.flat_map(fn date ->
          day_start = local_at(date, prefs["work_start"], prefs)
          day_end = local_at(date, prefs["work_end"], prefs) |> earlier(last)
          midnight = Preferences.from_local(date, ~T[00:00:00], prefs)
          tomorrow = Preferences.from_local(Date.add(date, 1), ~T[00:00:00], prefs)
          meetings = Enum.count(busy, &overlaps?(&1, midnight, tomorrow))

          if meetings >= prefs["max_meetings_per_day"] do
            []
          else
            offset = DateTime.diff(Preferences.local_time(day_start, prefs), day_start, :hour)

            FreeBlocks.openings(padded, earliest,
              work_start_utc: day_start,
              work_end_utc: day_end,
              min_opening_minutes: duration,
              offset: offset,
              timezone: prefs["timezone"]
            )
            |> Enum.flat_map(&split_opening(&1, duration, prefs["timezone"]))
            |> Enum.take(3)
          end
        end)

      {:ok, slots}
    else
      false -> {:error, :invalid_meeting_duration}
      error -> error
    end
  end

  @doc "Display the actual local dates and times without labelling UTC as local time."
  def slot_label(slot) do
    prefs = %{"timezone" => slot["timezone"]}
    {:ok, first, _} = DateTime.from_iso8601(slot["start_at"])
    {:ok, last, _} = DateTime.from_iso8601(slot["end_at"])
    first = Preferences.local_time(first, prefs)
    last = Preferences.local_time(last, prefs)

    Calendar.strftime(first, "%a, %b %-d, %Y, %-I:%M %p") <>
      " to " <>
      Calendar.strftime(last, "%a, %b %-d, %Y, %-I:%M %p") <>
      " (#{slot["timezone"]})"
  end

  @doc "Re-read every calendar frozen into the offer immediately before booking."
  def ensure_free(user_id, account_ids, start_at, end_at, own_event_id, prefs) do
    buffer = prefs["buffer_min"] * 60
    first = DateTime.add(start_at, -buffer)
    last = DateTime.add(end_at, buffer)

    with true <-
           is_list(account_ids) and account_ids != [] and length(account_ids) <= 10 and
             Enum.all?(account_ids, &(is_integer(&1) and &1 > 0)),
         {:ok, events} <- read_accounts(user_id, account_ids, first, last),
         {:ok, busy} <- busy_events(events, prefs) do
      if Enum.any?(busy, &(&1.event_id != own_event_id and overlaps?(&1, first, last))),
        do: {:error, "slot_no_longer_free"},
        else: :ok
    else
      false -> {:error, :invalid_calendar_accounts}
      error -> error
    end
  end

  defp account_ids(user_id, prefs, default_id) do
    available = Preferences.calendar_accounts(user_id) |> Enum.map(& &1.id)
    default = if default_id in available, do: default_id, else: List.first(available)
    booking = prefs["booking_calendar_account_id"] || default
    ids = Enum.uniq(List.wrap(booking) ++ prefs["calendar_account_ids"])

    if length(ids) in 1..10 and Enum.all?(ids, &(&1 in available)),
      do: {:ok, ids},
      else: {:error, :invalid_calendar_accounts}
  end

  defp read_accounts(user_id, ids, first, last) do
    Enum.reduce_while(Enum.uniq(ids), {:ok, []}, fn id, {:ok, acc} ->
      case GoogleCalendar.events_in_window(user_id, id, first, last) do
        {:ok, events} -> {:cont, {:ok, acc ++ events}}
        error -> {:halt, error}
      end
    end)
  end

  defp busy_events(events, prefs) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, acc} ->
      cond do
        event[:status] == "cancelled" or event[:transparency] == "transparent" or
            Enum.any?(
              event[:attendees] || [],
              &(&1[:self] and &1[:response_status] == "declined")
            ) ->
          {:cont, {:ok, acc}}

        true ->
          case interval(event, prefs) do
            {first, last} ->
              {:cont, {:ok, [%{start: first, end: last, event_id: event[:event_id]} | acc]}}

            nil ->
              {:halt, {:error, :calendar_source_gap}}
          end
      end
    end)
  end

  defp interval(%{start: %{date: first}, end: %{date: last}}, prefs) do
    with {:ok, first} <- Date.from_iso8601(first),
         {:ok, last} <- Date.from_iso8601(last),
         :lt <- Date.compare(first, last) do
      {Preferences.from_local(first, ~T[00:00:00], prefs),
       Preferences.from_local(last, ~T[00:00:00], prefs)}
    else
      _ -> nil
    end
  end

  defp interval(event, _), do: FreeBlocks.event_interval(event)

  defp split_opening(opening, duration, timezone) do
    {:ok, first, _} = DateTime.from_iso8601(opening["start"])
    {:ok, last, _} = DateTime.from_iso8601(opening["end"])
    # Round to a quarter hour so a seconds-level lead time doesn't become an offer.
    first = DateTime.from_unix!(div(DateTime.to_unix(first) + 899, 900) * 900)

    Stream.iterate(first, &DateTime.add(&1, max(duration, 15), :minute))
    |> Enum.take_while(&(DateTime.compare(DateTime.add(&1, duration, :minute), last) != :gt))
    |> Enum.take(8)
    |> Enum.map(fn start_at ->
      %{
        "start_at" => DateTime.to_iso8601(start_at),
        "end_at" => start_at |> DateTime.add(duration, :minute) |> DateTime.to_iso8601(),
        "timezone" => timezone
      }
    end)
  end

  defp valid_window(%DateTime{} = first, %DateTime{} = last) do
    if DateTime.diff(last, first) in 1..(@max_days * 86_400),
      do: :ok,
      else: {:error, :invalid_scheduling_window}
  end

  defp valid_window(_, _), do: {:error, :invalid_scheduling_window}

  defp local_at(date, time, prefs),
    do: Preferences.from_local(date, Time.from_iso8601!(time <> ":00"), prefs)

  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp overlaps?(event, first, last),
    do: DateTime.compare(event.start, last) == :lt and DateTime.compare(event.end, first) == :gt
end
