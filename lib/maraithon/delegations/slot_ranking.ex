defmodule Maraithon.Delegations.SlotRanking do
  @moduledoc "Ranks computed slots in local time without relaxing availability constraints."
  alias Maraithon.Delegations.Preferences

  @fields [
    %{
      key: "time_preference",
      label: "Preferred time of day",
      options: [
        %{value: "any", label: "No preference"},
        %{value: "morning", label: "Mornings"},
        %{value: "afternoon", label: "Afternoons"}
      ]
    },
    %{
      key: "day_preference",
      label: "Preferred days",
      options: [
        %{value: "earliest", label: "Soonest available"},
        %{value: "early_week", label: "Earlier in the week"},
        %{value: "late_week", label: "Later in the week"}
      ]
    }
  ]

  def fields, do: @fields
  def keys, do: Enum.map(@fields, & &1.key)

  def valid?(values) when is_map(values) do
    Enum.all?(@fields, fn field ->
      not Map.has_key?(values, field.key) or
        Enum.any?(field.options, &(&1.value == values[field.key]))
    end)
  end

  def valid?(_), do: false

  def preferences(prefs, request),
    do: Map.merge(Map.take(prefs, keys()), Map.get(request, :slot_preferences, %{}))

  def select(slots, prefs, request) do
    preferred = preferences(prefs, request)

    slots
    |> Enum.map(fn slot ->
      {:ok, first, _} = DateTime.from_iso8601(slot["start_at"])
      {:ok, last, _} = DateTime.from_iso8601(slot["end_at"])
      local = Preferences.local_time(first, prefs)
      finish = Preferences.local_time(last, prefs)
      time = time_rank(preferred["time_preference"], local, finish)
      day = day_rank(preferred["day_preference"], Date.day_of_week(local))
      {slot, DateTime.to_date(local), {time, day, DateTime.to_unix(first)}}
    end)
    |> Enum.sort_by(&elem(&1, 2))
    |> Enum.reduce_while({[], %{}}, fn {slot, date, _rank}, {selected, counts} ->
      count = Map.get(counts, date, 0)

      cond do
        length(selected) == 8 -> {:halt, {selected, counts}}
        count == 3 -> {:cont, {selected, counts}}
        true -> {:cont, {[slot | selected], Map.put(counts, date, count + 1)}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp time_rank("morning", _first, last),
    do: if(Time.compare(DateTime.to_time(last), ~T[12:00:00]) != :gt, do: 0, else: 1)

  defp time_rank("afternoon", first, _last), do: if(first.hour >= 12, do: 0, else: 1)
  defp time_rank(_, _, _), do: 0
  defp day_rank("early_week", weekday), do: weekday
  defp day_rank("late_week", weekday), do: -weekday
  defp day_rank(_, _), do: 0
end
