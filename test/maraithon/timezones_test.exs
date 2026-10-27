defmodule Maraithon.TimezonesTest do
  use ExUnit.Case, async: true

  alias Maraithon.Timezones

  test "named eastern timezone follows daylight saving time" do
    assert Timezones.offset_at("America/Toronto", ~U[2026-01-15 14:00:00Z], -5) == -5
    assert Timezones.offset_at("America/Toronto", ~U[2026-05-15 14:00:00Z], -5) == -4
    assert Timezones.normalize("Eastern Time") == "America/Toronto"
    assert Timezones.label("America/Toronto", -5) == "ET"
  end

  test "fixed offsets stay fixed" do
    assert Timezones.config_updates("OFFSET:1") == %{
             "timezone" => nil,
             "timezone_name" => nil,
             "timezone_offset_hours" => 1
           }

    assert Timezones.selected_value(nil, 1) == "offset:1"
    assert Timezones.label(nil, 1) == "UTC+01:00"
  end
end
