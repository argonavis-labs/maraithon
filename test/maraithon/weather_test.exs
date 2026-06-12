defmodule Maraithon.WeatherTest do
  use ExUnit.Case, async: false

  alias Maraithon.Weather

  defmodule HTTPStub do
    def get("https://geocoding-api.open-meteo.com/v1/search?" <> query) do
      params = URI.decode_query(query)
      send(self(), {:geocode, params["name"]})

      {:ok,
       %{
         "results" => [
           %{
             "name" => "Toronto",
             "admin1" => "Ontario",
             "country" => "Canada",
             "latitude" => 43.7,
             "longitude" => -79.42
           }
         ]
       }}
    end

    def get("https://api.open-meteo.com/v1/forecast?" <> query) do
      params = URI.decode_query(query)
      send(self(), {:forecast, params["latitude"], params["longitude"]})

      {:ok,
       %{
         "current" => %{
           "temperature_2m" => 21.4,
           "apparent_temperature" => 22.1,
           "precipitation" => 0.0,
           "weather_code" => 2,
           "wind_speed_10m" => 14.2
         },
         "daily" => %{
           "weather_code" => [61, 3],
           "temperature_2m_max" => [24.0, 26.1],
           "temperature_2m_min" => [15.2, 16.0],
           "precipitation_probability_max" => [40, 10],
           "sunrise" => ["2026-06-12T05:35", "2026-06-13T05:35"],
           "sunset" => ["2026-06-12T20:59", "2026-06-13T21:00"]
         }
       }}
    end
  end

  setup do
    original = Application.get_env(:maraithon, Weather)
    Application.put_env(:maraithon, Weather, http_module: HTTPStub)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:maraithon, Weather)
        config -> Application.put_env(:maraithon, Weather, config)
      end
    end)

    :ok
  end

  test "falls back to the timezone city when no location is configured" do
    assert {:ok, weather} = Weather.fetch_for_brief(%{"timezone" => "America/Toronto"})

    assert_received {:geocode, "Toronto"}
    assert weather["status"] == "ready"
    assert weather["location"] == "Toronto, Ontario, Canada"
    assert weather["current"]["temperature_c"] == 21.4
    assert weather["current"]["conditions"] == "partly cloudy"
    assert weather["today"]["high_c"] == 24.0
    assert weather["today"]["low_c"] == 15.2
    assert weather["today"]["precipitation_chance_pct"] == 40
    assert weather["today"]["conditions"] == "light rain"
    assert weather["tomorrow"]["conditions"] == "overcast"
  end

  test "uses the configured location name over the timezone" do
    assert {:ok, _weather} =
             Weather.fetch_for_brief(%{
               "weather_location" => "Kingston",
               "timezone" => "America/Toronto"
             })

    assert_received {:geocode, "Kingston"}
  end

  test "uses explicit coordinates without geocoding" do
    assert {:ok, weather} =
             Weather.fetch_for_brief(%{
               "weather_latitude" => 43.7,
               "weather_longitude" => -79.42,
               "weather_location" => "Home"
             })

    refute_received {:geocode, _name}
    assert_received {:forecast, "43.7", "-79.42"}
    assert weather["location"] == "Home"
  end

  test "returns disabled status without fetching when weather is disabled" do
    assert {:ok, %{"status" => "disabled"}} =
             Weather.fetch_for_brief(%{
               "weather_enabled" => false,
               "timezone" => "America/Toronto"
             })

    refute_received {:geocode, _name}
  end

  test "errors when no location can be resolved" do
    assert {:error, :no_location} = Weather.fetch_for_brief(%{})
    assert {:error, :no_location} = Weather.fetch_for_brief(%{"timezone" => "UTC"})
  end
end
