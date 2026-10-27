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
  # MET Norway is the forecast fallback: Fly's DNS resolver intermittently
  # SERVFAILs api.open-meteo.com while api.met.no (and the open-meteo
  # geocoding host) resolve fine, so production needs a second provider.
  @met_no_url "https://api.met.no/weatherapi/locationforecast/2.0/compact"
  @met_no_user_agent "Maraithon/1.0 (+https://maraithon.com)"
  @max_http_response_bytes 2_000_000

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
           {:ok, forecast} <- fetch_forecast(place, now) do
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
      valid_coordinates?(latitude, longitude) ->
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

    case http_get("#{@geocode_url}?#{query}") do
      {:ok, %{"results" => [result | _]}} when is_map(result) ->
        latitude = result["latitude"]
        longitude = result["longitude"]

        if valid_coordinates?(latitude, longitude) do
          {:ok,
           %{
             "latitude" => latitude,
             "longitude" => longitude,
             "label" => place_label(result, name)
           }}
        else
          {:error, {:geocode_no_match, name}}
        end

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

  defp fetch_forecast(place, now) do
    case fetch_open_meteo(place) do
      {:ok, forecast} ->
        {:ok, forecast}

      {:error, primary_reason} ->
        case fetch_met_no(place, now) do
          {:ok, forecast} ->
            Logger.info("Weather provider fallback used",
              provider: "met_no",
              failure_code: weather_failure_code(primary_reason)
            )

            {:ok, forecast}

          {:error, fallback_reason} = error ->
            Logger.warning("Weather forecast providers unavailable",
              provider: "met_no",
              failure_code: "weather_providers_unavailable",
              failure_codes:
                Enum.frequencies([
                  weather_failure_code(primary_reason),
                  weather_failure_code(fallback_reason)
                ])
            )

            error
        end
    end
  end

  defp fetch_open_meteo(place) do
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

    case http_get("#{@forecast_url}?#{query}") do
      {:ok, %{"current" => current, "daily" => daily} = body}
      when is_map(current) and is_map(daily) ->
        forecast = %{
          "source" => "open-meteo",
          "location" => place["label"],
          "latitude" => place["latitude"],
          "longitude" => place["longitude"],
          "units" => %{"temperature" => "°C", "wind" => "km/h"},
          "current" => current_block(body),
          "today" => daily_block(body, 0),
          "tomorrow" => daily_block(body, 1)
        }

        if usable_forecast?(forecast),
          do: {:ok, forecast},
          else: {:error, {:unexpected_body, "map"}}

      {:ok, body} ->
        {:error, {:unexpected_body, response_shape(body)}}

      {:error, reason} ->
        {:error, {:forecast_failed, reason}}
    end
  end

  defp fetch_met_no(place, now) do
    query =
      URI.encode_query(%{
        "lat" => place["latitude"],
        "lon" => place["longitude"]
      })

    case http_get("#{@met_no_url}?#{query}", [{"user-agent", @met_no_user_agent}]) do
      {:ok, %{"properties" => %{"timeseries" => timeseries}}} when is_list(timeseries) ->
        entries = met_no_entries(timeseries)

        forecast = %{
          "source" => "met.no",
          "location" => place["label"],
          "latitude" => place["latitude"],
          "longitude" => place["longitude"],
          "units" => %{"temperature" => "°C", "wind" => "km/h"},
          "current" => met_no_current_block(entries),
          "today" => met_no_window_block(entries, now, 0),
          "tomorrow" => met_no_window_block(entries, now, 24)
        }

        if usable_forecast?(forecast),
          do: {:ok, forecast},
          else: {:error, {:unexpected_body, "map"}}

      {:ok, body} ->
        {:error, {:unexpected_body, response_shape(body)}}

      {:error, reason} ->
        {:error, {:forecast_failed, reason}}
    end
  end

  defp met_no_entries(timeseries) do
    timeseries
    |> Enum.take(192)
    |> Enum.map(fn
      entry when is_map(entry) ->
        with time when is_binary(time) and byte_size(time) <= 128 <- entry["time"],
             true <- String.valid?(time),
             {:ok, datetime, _offset} <- DateTime.from_iso8601(time) do
          Map.put(entry, "parsed_time", datetime)
        else
          _ -> nil
        end

      _invalid ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp map_get_in(value, []), do: value

  defp map_get_in(map, [key | rest]) when is_map(map) and is_binary(key) do
    map
    |> Map.get(key)
    |> map_get_in(rest)
  end

  defp map_get_in(_value, _keys), do: nil

  defp met_no_current_block([entry | _rest]) do
    details =
      case map_get_in(entry, ["data", "instant", "details"]) do
        details when is_map(details) -> details
        _invalid -> %{}
      end

    %{
      "temperature_c" => weather_number(details["air_temperature"]),
      "conditions" => met_no_conditions(entry),
      "wind_kph" => met_no_wind_kph(details["wind_speed"])
    }
    |> reject_nil_values()
  end

  defp met_no_current_block(_entries), do: %{}

  # MET Norway returns an hourly series instead of daily aggregates, so the
  # "today"/"tomorrow" blocks are computed over rolling 24h windows from now.
  defp met_no_window_block(entries, now, offset_hours) do
    window_start = DateTime.add(now, offset_hours, :hour)
    window_end = DateTime.add(window_start, 24, :hour)

    window =
      Enum.filter(entries, fn entry ->
        datetime = entry["parsed_time"]

        DateTime.compare(datetime, window_start) != :lt and
          DateTime.compare(datetime, window_end) == :lt
      end)

    temperatures =
      window
      |> Enum.map(&map_get_in(&1, ["data", "instant", "details", "air_temperature"]))
      |> Enum.map(&weather_number/1)
      |> Enum.reject(&is_nil/1)

    precipitation_chances =
      window
      |> Enum.map(
        &map_get_in(&1, ["data", "next_6_hours", "details", "probability_of_precipitation"])
      )
      |> Enum.map(&weather_percentage/1)
      |> Enum.reject(&is_nil/1)

    %{
      "conditions" => window |> List.first() |> met_no_conditions(),
      "high_c" => if(temperatures != [], do: Enum.max(temperatures)),
      "low_c" => if(temperatures != [], do: Enum.min(temperatures)),
      "precipitation_chance_pct" =>
        if(precipitation_chances != [], do: Enum.max(precipitation_chances))
    }
    |> reject_nil_values()
  end

  defp met_no_conditions(entry) when is_map(entry) do
    symbol =
      map_get_in(entry, ["data", "next_6_hours", "summary", "symbol_code"]) ||
        map_get_in(entry, ["data", "next_1_hours", "summary", "symbol_code"]) ||
        map_get_in(entry, ["data", "next_12_hours", "summary", "symbol_code"])

    met_no_symbol_label(symbol)
  end

  defp met_no_conditions(_entry), do: nil

  @met_no_symbols %{
    "clearsky" => "clear sky",
    "fair" => "fair",
    "partlycloudy" => "partly cloudy",
    "cloudy" => "cloudy",
    "fog" => "fog",
    "lightrain" => "light rain",
    "lightrainshowers" => "light rain showers",
    "rain" => "rain",
    "rainshowers" => "rain showers",
    "heavyrain" => "heavy rain",
    "heavyrainshowers" => "heavy rain showers",
    "sleet" => "sleet",
    "sleetshowers" => "sleet showers",
    "lightsnow" => "light snow",
    "snow" => "snow",
    "snowshowers" => "snow showers",
    "heavysnow" => "heavy snow"
  }

  defp met_no_symbol_label(symbol)
       when is_binary(symbol) and byte_size(symbol) <= 128 do
    if String.valid?(symbol) do
      base =
        symbol
        |> String.split("_")
        |> List.first()

      Map.get(@met_no_symbols, base) ||
        base |> String.replace("andthunder", " and thunder") |> normalize_string()
    end
  end

  defp met_no_symbol_label(_symbol), do: nil

  defp met_no_wind_kph(speed_ms) do
    case weather_number(speed_ms) do
      speed when is_number(speed) -> Float.round(speed * 3.6, 1)
      _invalid -> nil
    end
  end

  defp current_block(%{"current" => %{} = current}) do
    %{
      "temperature_c" => weather_number(current["temperature_2m"]),
      "feels_like_c" => weather_number(current["apparent_temperature"]),
      "conditions" => describe_code(current["weather_code"]),
      "precipitation_mm" => weather_number(current["precipitation"]),
      "wind_kph" => weather_number(current["wind_speed_10m"])
    }
    |> reject_nil_values()
  end

  defp current_block(_body), do: %{}

  defp daily_block(%{"daily" => %{} = daily}, index) do
    %{
      "conditions" => describe_code(list_at(daily, "weather_code", index)),
      "high_c" => daily |> list_at("temperature_2m_max", index) |> weather_number(),
      "low_c" => daily |> list_at("temperature_2m_min", index) |> weather_number(),
      "precipitation_chance_pct" =>
        daily |> list_at("precipitation_probability_max", index) |> weather_percentage(),
      "sunrise" => daily |> list_at("sunrise", index) |> weather_timestamp(),
      "sunset" => daily |> list_at("sunset", index) |> weather_timestamp()
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

  defp valid_coordinates?(latitude, longitude) do
    valid_coordinate?(latitude, -90, 90) and valid_coordinate?(longitude, -180, 180)
  end

  defp valid_coordinate?(value, minimum, maximum) do
    case weather_number(value) do
      number when is_number(number) -> number >= minimum and number <= maximum
      _invalid -> false
    end
  end

  defp weather_number(value)
       when is_integer(value) and value >= -1_000_000 and value <= 1_000_000,
       do: value

  defp weather_number(value)
       when is_float(value) and value >= -1_000_000.0 and value <= 1_000_000.0,
       do: value

  defp weather_number(_value), do: nil

  defp weather_percentage(value) do
    case weather_number(value) do
      number when is_number(number) and number >= 0 and number <= 100 -> number
      _invalid -> nil
    end
  end

  defp weather_timestamp(value) when is_binary(value) and byte_size(value) <= 128 do
    if String.valid?(value), do: normalize_string(value)
  end

  defp weather_timestamp(_value), do: nil

  defp timezone_city(timezone) when is_binary(timezone) do
    case normalize_string(timezone) do
      nil ->
        nil

      normalized ->
        case String.split(normalized, "/") do
          segments when length(segments) >= 2 ->
            segments
            |> List.last()
            |> String.replace("_", " ")
            |> normalize_string()

          _ ->
            nil
        end
    end
  end

  defp timezone_city(_timezone), do: nil

  defp coordinate(value) when is_number(value), do: value

  defp coordinate(value)
       when is_binary(value) and byte_size(value) <= 64 do
    if String.valid?(value) do
      case Float.parse(String.trim(value)) do
        {parsed, ""} -> parsed
        _ -> nil
      end
    else
      nil
    end
  end

  defp coordinate(_value), do: nil

  defp usable_forecast?(forecast) when is_map(forecast) do
    Enum.any?(["current", "today", "tomorrow"], fn key ->
      case Map.get(forecast, key) do
        block when is_map(block) -> map_size(block) > 0
        _invalid -> false
      end
    end)
  end

  defp usable_forecast?(_forecast), do: false

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_string(value)
       when is_binary(value) and byte_size(value) <= 512 do
    if String.valid?(value) do
      case value |> String.replace(~r/\s+/, " ") |> String.trim() do
        "" -> nil
        normalized -> normalized
      end
    else
      nil
    end
  end

  defp normalize_string(_value), do: nil

  defp response_shape(value) when is_map(value), do: "map"
  defp response_shape(value) when is_list(value), do: "list"
  defp response_shape(value) when is_binary(value), do: "binary"
  defp response_shape(value) when is_number(value), do: "number"
  defp response_shape(_value), do: "other"

  defp weather_failure_code({:forecast_failed, {:http_status, status, _body}})
       when is_integer(status),
       do: "http_status_#{min(max(status, 0), 999)}"

  defp weather_failure_code({:forecast_failed, {:http_error, reason}}),
    do: "transport_#{Maraithon.Redaction.error_class(reason)}"

  defp weather_failure_code({:forecast_failed, reason}),
    do: Maraithon.Redaction.error_class(reason)

  defp weather_failure_code({:unexpected_body, shape})
       when shape in ["map", "list", "binary", "number", "other"],
       do: "unexpected_#{shape}"

  defp weather_failure_code(reason), do: Maraithon.Redaction.error_class(reason)

  defp http_get(url, headers \\ []) do
    module = http_module()

    cond do
      module == HTTP ->
        HTTP.get(url, headers,
          log_failures?: false,
          max_response_body_bytes: @max_http_response_bytes
        )

      headers == [] ->
        module.get(url)

      true ->
        module.get(url, headers)
    end
  end

  defp http_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:http_module, HTTP)
  end
end
