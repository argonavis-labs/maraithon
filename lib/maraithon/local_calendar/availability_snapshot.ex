defmodule Maraithon.LocalCalendar.AvailabilitySnapshot do
  @moduledoc "A complete, bounded EventKit window. Never infer completeness from changed-event uploads."
  alias Maraithon.LocalCalendar.LocalEvent

  @keys ~w(version captured_at from until calendars events)
  @calendar_keys ~w(id source_id name source_name)
  @event_keys ~w(guid start_at end_at start_date end_date is_all_day source_state)

  def validate(snapshot, now) when is_map(snapshot) do
    with true <- Map.keys(snapshot) |> Enum.sort() == Enum.sort(@keys),
         true <- snapshot["version"] == 1,
         {:ok, captured} <- timestamp(snapshot["captured_at"]),
         true <- DateTime.diff(now, captured) in 0..300,
         {:ok, first} <- timestamp(snapshot["from"]),
         {:ok, last} <- timestamp(snapshot["until"]),
         true <- DateTime.diff(last, first) in 1..(60 * 86_400),
         true <- bounded_list?(snapshot["calendars"], 64),
         true <- Enum.all?(snapshot["calendars"], &calendar?/1),
         calendars = MapSet.new(snapshot["calendars"], &{&1["id"], &1["source_id"]}),
         true <- MapSet.size(calendars) == length(snapshot["calendars"]),
         true <- bounded_list?(snapshot["events"], 2_000),
         true <- Enum.all?(snapshot["events"], &event?(&1, calendars, first, last)),
         true <- byte_size(Jason.encode!(snapshot)) <= 1_048_576 do
      :ok
    else
      _ -> {:error, :invalid_calendar_availability}
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

  defp event?(item, calendars, first, last) when is_map(item) do
    with true <- Enum.all?(Map.keys(item), &(&1 in @event_keys)),
         true <- text?(item["guid"]) and is_boolean(item["is_all_day"]),
         state = item["source_state"],
         true <- LocalEvent.valid_source_state?(state),
         true <- MapSet.member?(calendars, {state["calendar_id"], state["source_id"]}),
         {:ok, start_at} <- timestamp(item["start_at"]),
         {:ok, end_at} <- timestamp(item["end_at"]),
         true <- DateTime.compare(start_at, end_at) == :lt,
         true <-
           DateTime.compare(start_at, last) == :lt and DateTime.compare(end_at, first) == :gt do
      if item["is_all_day"],
        do: valid_dates?(item["start_date"], item["end_date"]),
        else: is_nil(item["start_date"]) and is_nil(item["end_date"])
    else
      _ -> false
    end
  end

  defp event?(_, _, _, _), do: false

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
