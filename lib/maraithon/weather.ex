defmodule Maraithon.Weather do
  @moduledoc """
  Daily weather acquisition for morning briefings.

  Uses the Open-Meteo public APIs (no API key). The operator's location
  resolves from briefing config first (`weather_latitude`/`weather_longitude`
  or `weather_location`), then falls back to the city segment of the
  configured IANA timezone ("America/Toronto" -> "Toronto"), so the brief
  keeps weather coverage even when no location was explicitly configured.
  """

  alias Maraithon.HTTP

  require Logger

  @geocode_url "https://geocoding-api.open-meteo.com/v1/search"
  @forecast_url "https://api.open-meteo.com/v1/forecast"

  @weather_codes %{
    0 => "clear sky",
    1 => "mainly clear",
    2 => "partly cloudy",
    3 => "overcast",
    45 => "fog",
    48 => "depositing rime fog",
    51 => "light drizzle",
    53 => "drizzle",
    55 => "heavy drizzle",
    56 => "light freezing drizzle",
    57 => "freezing drizzle",
    61 => "light rain",
    63 => "rain",
    65 => "heavy rain",
    66 => "light freezing rain",
    67 => "freezing rain",
    71 => "light snow",
    73 => "snow",
    75 => "heavy snow",
    77 => "snow grains",
    80 => "light rain showers",
    81 => "rain showers",
    82 => "violent rain showers",
    85 => "light snow showers",
    86 => "snow showers",
    95 => "thunderstorm",
    96 => "thunderstorm with light hail",
    99 => "thunderstorm with heavy hail"
  }

  def fetch_for_brief(config, now \\ DateTime.utc_now())

  def fetch_for_brief(config, now) when is_map(config) do
    if enabled?(config) do
      with {:ok, place} <- resolve_place(config),
           {:ok, forecast} <- fetch_forecast(place) do
        {:ok,
         forecast
         |> Map.put("status", "ready")
         |> Map.put("fetched_at", DateTime.to_iso8601(now))}
      end
    else
      {:ok,
       %{
         "status" => "disabled",
         "fetched_at" => DateTime.to_iso8601(now)
       }}
    end
  end

  def fetch_for_brief(_config, now), do: fetch_for_brief(%{}, now)

  defp enabled?(config) do
    case config["weather_enabled"] do
      false -> false
      "false" -> false
      "0" -> false
      _ -> true
    end
  end

  # Location resolution order: explicit coordinates, configured location name,
  # then the city implied by the IANA timezone.
  defp resolve_place(config) do
    latitude = coordinate(config["weather_latitude"])
    longitude = coordinate(config["weather_longitude"])

    cond do
      is_number(latitude) and is_number(longitude) ->
        {:ok,
         %{
           "latitude" => latitude,
           "longitude" => longitude,
           "label" => normalize_string(config["weather_location"]) || "configured location"
         }}

      location = normalize_string(config["weather_location"]) ->
        geocode(location)

      city = timezone_city(config["timezone"]) ->
        geocode(city)

      true ->
        {:error, :no_location}
    end
  end

  defp geocode(name) do
    query =
      URI.encode_query(%{"name" => name, "count" => 1, "language" => "en", "format" => "json"})

    case http_module().get("#{@geocode_url}?#{query}") do
      {:ok, %{"results" => [result | _]}} ->
        {:ok,
         %{
           "latitude" => result["latitude"],
           "longitude" => result["longitude"],
           "label" => place_label(result, name)
         }}

      {:ok, _body} ->
        {:error, {:geocode_no_match, name}}

      {:error, reason} ->
        {:error, {:geocode_failed, reason}}
    end
  end

  defp place_label(result, fallback) do
    [result["name"], result["admin1"], result["country"]]
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> fallback
      parts -> Enum.join(parts, ", ")
    end
  end

  defp fetch_forecast(place) do
    query =
      URI.encode_query(%{
        "latitude" => place["latitude"],
        "longitude" => place["longitude"],
        "current" =>
          "temperature_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m",
        "daily" =>
          "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset",
        "timezone" => "auto",
        "forecast_days" => 2
      })

    case http_module().get("#{@forecast_url}?#{query}") do
      {:ok, %{} = body} ->
        {:ok,
         %{
           "source" => "open-meteo",
           "location" => place["label"],
           "latitude" => place["latitude"],
           "longitude" => place["longitude"],
           "units" => %{"temperature" => "°C", "wind" => "km/h"},
           "current" => current_block(body),
           "today" => daily_block(body, 0),
           "tomorrow" => daily_block(body, 1)
         }}

      {:ok, body} ->
        {:error, {:unexpected_body, body |> inspect() |> String.slice(0, 120)}}

      {:error, reason} ->
        {:error, {:forecast_failed, reason}}
    end
  end

  defp current_block(%{"current" => %{} = current}) do
    %{
      "temperature_c" => current["temperature_2m"],
      "feels_like_c" => current["apparent_temperature"],
      "conditions" => describe_code(current["weather_code"]),
      "precipitation_mm" => current["precipitation"],
      "wind_kph" => current["wind_speed_10m"]
    }
    |> reject_nil_values()
  end

  defp current_block(_body), do: %{}

  defp daily_block(%{"daily" => %{} = daily}, index) do
    %{
      "conditions" => describe_code(list_at(daily, "weather_code", index)),
      "high_c" => list_at(daily, "temperature_2m_max", index),
      "low_c" => list_at(daily, "temperature_2m_min", index),
      "precipitation_chance_pct" => list_at(daily, "precipitation_probability_max", index),
      "sunrise" => list_at(daily, "sunrise", index),
      "sunset" => list_at(daily, "sunset", index)
    }
    |> reject_nil_values()
  end

  defp daily_block(_body, _index), do: %{}

  defp list_at(daily, key, index) when is_map(daily) do
    case Map.get(daily, key) do
      values when is_list(values) -> Enum.at(values, index)
      _ -> nil
    end
  end

  defp describe_code(code) when is_integer(code), do: Map.get(@weather_codes, code)

  defp describe_code(code) when is_float(code), do: describe_code(trunc(code))

  defp describe_code(_code), do: nil

  defp timezone_city(timezone) when is_binary(timezone) do
    case String.split(String.trim(timezone), "/") do
      segments when length(segments) >= 2 ->
        segments
        |> List.last()
        |> String.replace("_", " ")
        |> normalize_string()

      _ ->
        nil
    end
  end

  defp timezone_city(_timezone), do: nil

  defp coordinate(value) when is_number(value), do: value

  defp coordinate(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp coordinate(_value), do: nil

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_string(value) when is_binary(value) do
    case value |> String.replace(~r/\s+/, " ") |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp http_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:http_module, HTTP)
  end
end
