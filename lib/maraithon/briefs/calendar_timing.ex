defmodule Maraithon.Briefs.CalendarTiming do
  @moduledoc """
  End instants for timed calendar rows in a saved brief. Unknown or ambiguous
  rows stay emphasized; rendering never changes the brief or calls a provider.
  """
  alias Maraithon.Briefs.Markdown
  alias Maraithon.Timezones

  @range ~r/^(?<sh>\d{1,2})(?::(?<sm>\d{2}))?\s*(?<sp>AM|PM)?\s*(?:[-–—]|to)\s*(?<eh>\d{1,2})(?::(?<em>\d{2}))?\s*(?<ep>AM|PM)?\b\s*(?<zone>ET|CT|MT|PT|EST|EDT|CST|CDT|MST|MDT|PST|PDT|UTC(?:[+-]\d{2}:00)?)?(?=\s*[-–—:(]|$)/i
  @fixed %{
    "EST" => -5,
    "EDT" => -4,
    "CST" => -6,
    "CDT" => -5,
    "MST" => -7,
    "MDT" => -6,
    "PST" => -8,
    "PDT" => -7,
    "UTC" => 0
  }

  def end_times(brief) do
    input = get_in(brief.metadata || %{}, ["brief_input"]) || %{}

    {_, times} =
      Enum.reduce(Markdown.parse(brief.body), {false, %{}}, fn
        {:heading, heading}, {_, times} ->
          name = heading |> String.downcase() |> String.replace("’", "'")
          {name in ["calendar", "schedule", "today's schedule"], times}

        block, {true, times} ->
          rows =
            case block do
              {:list, items} -> items
              {:paragraph, text} -> [text]
            end

          {true,
           Enum.reduce(rows, times, fn text, acc ->
             case ends_at(text, input) do
               %DateTime{} = at -> Map.put(acc, text, DateTime.to_iso8601(at))
               _ -> acc
             end
           end)}

        _, state ->
          state
      end)

    times
  end

  defp ends_at(text, input) do
    clean = text |> String.replace("**", "") |> String.trim()

    with parts when is_map(parts) <- Regex.named_captures(@range, clean),
         {:ok, date} <- Date.from_iso8601(input["date"] || ""),
         {:ok, start} <- minutes(parts["sh"], parts["sm"], nonempty(parts["sp"]) || parts["ep"]),
         {:ok, finish} <- minutes(parts["eh"], parts["em"], parts["ep"]),
         # A missing meridiem may borrow the end's, e.g. 11:30–12:00 PM.
         start <-
           if(parts["sp"] == "" and parts["ep"] != "" and start > finish and start >= 720,
             do: start - 720,
             else: start
           ),
         local <- DateTime.new!(Date.add(date, if(finish < start, do: 1, else: 0)), ~T[00:00:00]),
         local <- DateTime.add(local, finish * 60, :second),
         offset when is_integer(offset) and offset in -12..14 <-
           offset(parts["zone"], input, local) do
      DateTime.add(local, -offset * 3600, :second)
    else
      _ -> nil
    end
  end

  defp minutes(hour, minute, period) do
    hour = String.to_integer(hour)
    minute = String.to_integer(nonempty(minute) || "0")
    period = String.upcase(period)

    cond do
      minute > 59 ->
        :error

      period in ["AM", "PM"] and hour in 1..12 ->
        {:ok, (rem(hour, 12) + if(period == "PM", do: 12, else: 0)) * 60 + minute}

      period == "" and hour in 0..23 ->
        {:ok, hour * 60 + minute}

      true ->
        :error
    end
  end

  defp offset(zone, input, local) do
    zone = String.upcase(nonempty(zone) || input["timezone"] || "")

    cond do
      Map.has_key?(@fixed, zone) ->
        @fixed[zone]

      Regex.match?(~r/^UTC[+-]\d{2}:00$/, zone) ->
        zone |> String.slice(3, 3) |> String.to_integer()

      Timezones.normalize(zone) != nil ->
        Timezones.offset_for_local(zone, local, 0)

      zone == "" and is_integer(input["timezone_offset_hours"]) ->
        input["timezone_offset_hours"]

      true ->
        nil
    end
  end

  defp nonempty(""), do: nil
  defp nonempty(value), do: value
end
