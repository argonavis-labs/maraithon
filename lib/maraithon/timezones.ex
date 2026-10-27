defmodule Maraithon.Timezones do
  @moduledoc """
  Small product-facing timezone helper for briefing schedules.

  The app deliberately avoids a full timezone database today, but briefing
  schedules still need to respect the North American daylight-saving regions
  exposed in the UI. Unknown regions fall back to fixed UTC offsets.
  """

  @zones [
    %{
      name: "America/Toronto",
      aliases: [
        "america/new_york",
        "america/toronto",
        "us/eastern",
        "eastern",
        "eastern time",
        "et"
      ],
      label: "Eastern Time",
      short_label: "ET",
      standard_offset: -5,
      daylight_offset: -4
    },
    %{
      name: "America/Chicago",
      aliases: ["america/chicago", "us/central", "central", "central time", "ct"],
      label: "Central Time",
      short_label: "CT",
      standard_offset: -6,
      daylight_offset: -5
    },
    %{
      name: "America/Denver",
      aliases: ["america/denver", "us/mountain", "mountain", "mountain time", "mt"],
      label: "Mountain Time",
      short_label: "MT",
      standard_offset: -7,
      daylight_offset: -6
    },
    %{
      name: "America/Los_Angeles",
      aliases: ["america/los_angeles", "us/pacific", "pacific", "pacific time", "pt"],
      label: "Pacific Time",
      short_label: "PT",
      standard_offset: -8,
      daylight_offset: -7
    }
  ]

  @utc_zone %{
    name: "UTC",
    aliases: ["utc", "etc/utc", "z"],
    label: "UTC",
    short_label: "UTC",
    standard_offset: 0,
    daylight_offset: 0
  }

  def options do
    named =
      [@utc_zone | @zones]
      |> Enum.map(fn zone ->
        %{
          value: zone.name,
          label: "#{zone.label} (#{zone.short_label})"
        }
      end)

    fixed =
      -12..14
      |> Enum.map(fn offset ->
        %{
          value: fixed_offset_value(offset),
          label: "#{offset_label(offset)} fixed"
        }
      end)

    named ++ fixed
  end

  def normalize(value) when is_binary(value) do
    trimmed = String.trim(value)
    normalized = String.downcase(trimmed)

    cond do
      trimmed == "" ->
        nil

      String.starts_with?(normalized, "offset:") ->
        normalized

      true ->
        all_zones()
        |> Enum.find(fn zone ->
          normalized == String.downcase(zone.name) or normalized in zone.aliases
        end)
        |> case do
          nil -> nil
          zone -> zone.name
        end
    end
  end

  def normalize(_value), do: nil

  def config_updates(value) when is_binary(value) do
    case normalize(value) do
      nil ->
        %{}

      "offset:" <> offset ->
        case Integer.parse(offset) do
          {parsed, ""} when parsed in -12..14 ->
            %{
              "timezone" => nil,
              "timezone_name" => nil,
              "timezone_offset_hours" => parsed
            }

          _ ->
            %{}
        end

      timezone ->
        %{
          "timezone" => timezone,
          "timezone_name" => timezone,
          "timezone_offset_hours" => standard_offset(timezone)
        }
    end
  end

  def config_updates(_value), do: %{}

  def selected_value(timezone_name, offset_hours) do
    case normalize(to_string(timezone_name || "")) do
      nil -> fixed_offset_value(normalize_offset(offset_hours))
      timezone -> timezone
    end
  end

  def standard_offset(timezone_name, fallback \\ -5) do
    case zone_for(timezone_name) do
      nil -> normalize_offset(fallback)
      zone -> zone.standard_offset
    end
  end

  def offset_at(timezone_name, %DateTime{} = utc_datetime, fallback) do
    case zone_for(timezone_name) do
      nil ->
        normalize_offset(fallback)

      %{name: "UTC"} ->
        0

      zone ->
        if us_dst_active_utc?(utc_datetime, zone.standard_offset, zone.daylight_offset) do
          zone.daylight_offset
        else
          zone.standard_offset
        end
    end
  end

  def offset_at(_timezone_name, _datetime, fallback), do: normalize_offset(fallback)

  def offset_for_local(timezone_name, %DateTime{} = local_datetime, fallback) do
    case zone_for(timezone_name) do
      nil ->
        normalize_offset(fallback)

      %{name: "UTC"} ->
        0

      zone ->
        if us_dst_active_local?(local_datetime),
          do: zone.daylight_offset,
          else: zone.standard_offset
    end
  end

  def offset_for_local(_timezone_name, _datetime, fallback), do: normalize_offset(fallback)

  def label(timezone_name, fallback_offset \\ -5) do
    case zone_for(timezone_name) do
      nil -> offset_label(normalize_offset(fallback_offset))
      zone -> zone.short_label
    end
  end

  def long_label(timezone_name, fallback_offset \\ -5) do
    case zone_for(timezone_name) do
      nil -> offset_label(normalize_offset(fallback_offset))
      zone -> "#{zone.label} (#{zone.short_label})"
    end
  end

  def offset_label(offset) when is_integer(offset) do
    sign = if offset < 0, do: "-", else: "+"
    hours = offset |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
    "UTC#{sign}#{hours}:00"
  end

  def offset_label(_offset), do: "UTC-05:00"

  def fixed_offset_value(offset) when is_integer(offset), do: "offset:#{offset}"
  def fixed_offset_value(_offset), do: "offset:-5"

  def normalize_offset(offset) when is_integer(offset) and offset in -12..14, do: offset
  def normalize_offset(offset) when is_integer(offset) and offset < -12, do: -12
  def normalize_offset(offset) when is_integer(offset) and offset > 14, do: 14

  def normalize_offset(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> normalize_offset(parsed)
      _ -> -5
    end
  end

  def normalize_offset(_value), do: -5

  defp zone_for(timezone_name) do
    case normalize(to_string(timezone_name || "")) do
      nil -> nil
      normalized -> Enum.find(all_zones(), &(&1.name == normalized))
    end
  end

  defp all_zones, do: [@utc_zone | @zones]

  defp us_dst_active_utc?(%DateTime{} = utc_datetime, standard_offset, daylight_offset) do
    year = utc_datetime.year
    starts_at = us_dst_boundary_utc(year, 3, :second, standard_offset)
    ends_at = us_dst_boundary_utc(year, 11, :first, daylight_offset)

    DateTime.compare(utc_datetime, starts_at) != :lt and
      DateTime.compare(utc_datetime, ends_at) == :lt
  end

  defp us_dst_active_local?(%DateTime{} = local_datetime) do
    year = local_datetime.year
    starts_at = us_dst_boundary_local(year, 3, :second)
    ends_at = us_dst_boundary_local(year, 11, :first)

    DateTime.compare(local_datetime, starts_at) != :lt and
      DateTime.compare(local_datetime, ends_at) == :lt
  end

  defp us_dst_boundary_utc(year, month, ordinal, offset_hours) do
    year
    |> us_dst_boundary_local(month, ordinal)
    |> DateTime.add(-offset_hours, :hour)
  end

  defp us_dst_boundary_local(year, month, ordinal) do
    year
    |> nth_sunday(month, ordinal)
    |> DateTime.new!(~T[02:00:00], "Etc/UTC")
  end

  defp nth_sunday(year, month, ordinal) do
    first = Date.new!(year, month, 1)
    days_until_sunday = rem(7 - Date.day_of_week(first), 7)
    first_sunday = Date.add(first, days_until_sunday)

    case ordinal do
      :first -> first_sunday
      :second -> Date.add(first_sunday, 7)
    end
  end
end
