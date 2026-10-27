defmodule MaraithonWeb.LocalTime do
  @moduledoc """
  Product-facing local time formatting for operator UI surfaces.
  """

  alias Maraithon.{BriefingSchedules, Timezones}

  @default_timezone_info %{name: nil, offset_hours: -5}

  def default_timezone_info, do: @default_timezone_info

  def timezone_info_for_user(user_id) when is_binary(user_id) do
    case BriefingSchedules.summarize_for_prompt(user_id) do
      %{timezone_name: timezone_name, timezone_offset_hours: offset_hours} ->
        normalize_timezone_info(%{name: timezone_name, offset_hours: offset_hours})

      _other ->
        default_timezone_info()
    end
  rescue
    _exception -> default_timezone_info()
  end

  def timezone_info_for_user(_user_id), do: default_timezone_info()

  def format_datetime(nil, fallback, _timezone_info), do: fallback

  def format_datetime(value, fallback, timezone_info) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> format_datetime(datetime, fallback, timezone_info)
      _other -> value
    end
  end

  def format_datetime(%DateTime{} = datetime, _fallback, timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)
    offset = Timezones.offset_at(timezone_info.name, datetime, timezone_info.offset_hours)
    label = Timezones.label(timezone_info.name, offset)

    datetime
    |> DateTime.add(offset, :hour)
    |> Calendar.strftime("%b %-d, %Y at %-I:%M %p #{label}")
  end

  def format_datetime(%NaiveDateTime{} = datetime, _fallback, timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)
    label = Timezones.label(timezone_info.name, timezone_info.offset_hours)

    Calendar.strftime(datetime, "%b %-d, %Y at %-I:%M %p #{label}")
  end

  def format_datetime(value, _fallback, _timezone_info), do: to_string(value)

  defp normalize_timezone_info(%{name: name, offset_hours: offset_hours}) do
    %{name: name, offset_hours: Timezones.normalize_offset(offset_hours)}
  end

  defp normalize_timezone_info(_timezone_info), do: default_timezone_info()
end
