defmodule Maraithon.LocalCalendar.AvailabilitySnapshot do
  @moduledoc "A complete, bounded EventKit window. Never infer completeness from changed-event uploads."
  alias Maraithon.LocalCalendar.LocalEvent

  @keys ~w(version captured_at from until calendars events)
  @calendar_keys ~w(id source_id name source_name)
  @event_keys ~w(guid start_at end_at start_date end_date is_all_day source_state)

  def validate(snapshot, now) when is_map(snapshot) do
    with {:fields, true} <- {:fields, Enum.sort(Map.keys(snapshot)) == Enum.sort(@keys)},
         {:version, true} <- {:version, snapshot["version"] == 1},
         {:captured_at, {:ok, captured}} <- {:captured_at, timestamp(snapshot["captured_at"])},
         {:freshness, true} <- {:freshness, DateTime.diff(now, captured) in 0..300},
         {:from, {:ok, first}} <- {:from, timestamp(snapshot["from"])},
         {:until, {:ok, last}} <- {:until, timestamp(snapshot["until"])},
         {:window, true} <- {:window, DateTime.diff(last, first) in 1..(60 * 86_400)},
         {:calendars, true} <- {:calendars, bounded_list?(snapshot["calendars"], 64)},
         {:calendar_fields, true} <-
           {:calendar_fields, Enum.all?(snapshot["calendars"], &calendar?/1)},
         calendars = MapSet.new(snapshot["calendars"], &{&1["id"], &1["source_id"]}),
         {:calendar_ids, true} <-
           {:calendar_ids, MapSet.size(calendars) == length(snapshot["calendars"])},
         {:events, true} <- {:events, bounded_list?(snapshot["events"], 2_000)},
         nil <- Enum.find_value(snapshot["events"], &event_error(&1, calendars, first, last)),
         {:bytes, true} <- {:bytes, byte_size(Jason.encode!(snapshot)) <= 1_048_576} do
      :ok
    else
      {field, _} -> {:error, "invalid_calendar_availability_#{field}"}
    end
  end

  def validate(_, _), do: {:error, :invalid_calendar_availability}

  def timestamp(value) when is_binary(value) and byte_size(value) <= 40 do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> {:ok, time}
      _ -> :error
    end
  end

  def timestamp(_), do: :error

  defp calendar?(item) when is_map(item),
    do:
      Enum.sort(Map.keys(item)) == Enum.sort(@calendar_keys) and
        Enum.all?(@calendar_keys, &text?(item[&1]))

  defp calendar?(_), do: false

  defp event_error(item, calendars, first, last) when is_map(item) do
    with {:event_fields, true} <-
           {:event_fields, Enum.all?(Map.keys(item), &(&1 in @event_keys))},
         {:event_fields, true} <-
           {:event_fields, text?(item["guid"]) and is_boolean(item["is_all_day"])},
         state = item["source_state"],
         {:event_state, true} <- {:event_state, LocalEvent.valid_source_state?(state)},
         {:event_calendar, true} <-
           {:event_calendar,
            MapSet.member?(calendars, {state["calendar_id"], state["source_id"]})},
         {:event_start, {:ok, start_at}} <- {:event_start, timestamp(item["start_at"])},
         {:event_end, {:ok, end_at}} <- {:event_end, timestamp(item["end_at"])},
         {:event_duration, true} <- {:event_duration, DateTime.compare(start_at, end_at) == :lt},
         {:event_window, true} <-
           {:event_window,
            DateTime.compare(start_at, last) == :lt and DateTime.compare(end_at, first) == :gt},
         {:event_dates, true} <- {:event_dates, dates?(item)} do
      nil
    else
      error -> error
    end
  end

  defp event_error(_, _, _, _), do: {:event_fields, false}

  defp dates?(%{"is_all_day" => true} = item),
    do: valid_dates?(item["start_date"], item["end_date"])

  defp dates?(item), do: is_nil(item["start_date"]) and is_nil(item["end_date"])

  defp valid_dates?(first, last) when is_binary(first) and is_binary(last) do
    with {:ok, first} <- Date.from_iso8601(first),
         {:ok, last} <- Date.from_iso8601(last),
         do: Date.compare(first, last) == :lt,
         else: (_ -> false)
  end

  defp valid_dates?(_, _), do: false
  defp bounded_list?(items, max), do: is_list(items) and length(items) <= max
  defp text?(value), do: is_binary(value) and byte_size(value) in 1..2048
end
