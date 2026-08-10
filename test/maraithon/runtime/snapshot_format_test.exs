defmodule Maraithon.Runtime.SnapshotFormatTest do
  use ExUnit.Case, async: true

  alias Maraithon.Runtime.SnapshotFormat

  test "round-trips the closed typed grammar without collapsing symbol and string keys" do
    datetime = %DateTime{
      year: 2026,
      month: 8,
      day: 10,
      hour: 12,
      minute: 34,
      second: 56,
      microsecond: {123_456, 6},
      time_zone: "America/Los_Angeles",
      zone_abbr: "PDT",
      utc_offset: -28_800,
      std_offset: 3_600,
      calendar: Calendar.ISO
    }

    term = %{
      :same => {:ok, [1, -2, 1.25]},
      "same" => <<0, 255, 17>>,
      :calendar => %{
        date: ~D[2026-08-10],
        time: ~T[12:34:56.123456],
        naive: ~N[2026-08-10 12:34:56.123456],
        datetime: datetime
      }
    }

    assert {:ok, envelope, encoded_bytes} = SnapshotFormat.encode(term)
    assert encoded_bytes <= SnapshotFormat.max_encoded_bytes()
    assert envelope["format"] == "maraithon.agent_snapshot"
    assert envelope["format_version"] == 1
    assert {:ok, ^term} = SnapshotFormat.decode(envelope)
  end

  test "has a deterministic portable golden vector" do
    term = %{"enabled" => true, :count => 7}

    expected = %{
      "format" => "maraithon.agent_snapshot",
      "format_version" => 1,
      "value" => %{
        "$type" => "map",
        "entries" => [
          ["enabled", true],
          [%{"$type" => "symbol", "value" => "count"}, %{"$type" => "int64", "value" => "7"}]
        ]
      }
    }

    assert {:ok, ^expected, _encoded_bytes} = SnapshotFormat.encode(term)
    assert {:ok, ^term} = SnapshotFormat.decode(expected)
  end

  test "rejects values outside the closed grammar and int64 range" do
    assert {:error, :snapshot_integer_out_of_range} =
             SnapshotFormat.encode(9_223_372_036_854_775_808)

    assert {:error, :unsupported_snapshot_type} = SnapshotFormat.encode(%URI{scheme: "https"})
    assert {:error, :unsupported_snapshot_type} = SnapshotFormat.encode(self())
  end

  test "enforces scalar, depth, width, and exact encoded-byte bounds" do
    assert {:error, :snapshot_scalar_too_large} =
             SnapshotFormat.encode(String.duplicate("x", 65_537))

    too_deep = Enum.reduce(1..26, :ok, fn _index, value -> [value] end)
    assert {:error, :snapshot_too_deep} = SnapshotFormat.encode(too_deep)

    assert {:error, :snapshot_collection_too_large} =
             SnapshotFormat.encode(Enum.to_list(1..5_001))

    escaped = String.duplicate("\"\\", 32_768)
    assert byte_size(escaped) == 65_536

    assert {:error, :snapshot_too_large} =
             SnapshotFormat.encode(List.duplicate(escaped, 20))
  end

  test "unknown versions, symbols, tags, and duplicate typed keys fail closed" do
    assert {:error, :unknown_snapshot_format_version} =
             SnapshotFormat.decode(%{
               "format" => SnapshotFormat.format(),
               "format_version" => 2,
               "value" => nil
             })

    unknown_symbol = "snapshot_symbol_that_must_not_exist_7c330f82"

    assert {:error, :unknown_snapshot_symbol} =
             SnapshotFormat.decode(%{
               "format" => SnapshotFormat.format(),
               "format_version" => 1,
               "value" => %{"$type" => "symbol", "value" => unknown_symbol}
             })

    assert {:error, :invalid_snapshot_format} =
             SnapshotFormat.decode(%{
               "format" => SnapshotFormat.format(),
               "format_version" => 1,
               "value" => %{"$type" => "future"}
             })

    duplicate_map = %{
      "format" => SnapshotFormat.format(),
      "format_version" => 1,
      "value" => %{
        "$type" => "map",
        "entries" => [["key", true], ["key", false]]
      }
    }

    assert {:error, :duplicate_snapshot_map_key} = SnapshotFormat.decode(duplicate_map)
  end
end
