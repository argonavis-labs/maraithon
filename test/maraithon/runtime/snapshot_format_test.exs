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

    # Plain data structs are part of the grammar (behavior state carries LLM
    # response/usage structs); they round-trip only into existing struct modules.
    assert {:ok, envelope, _bytes} = SnapshotFormat.encode(%URI{scheme: "https"})
    assert {:ok, %URI{scheme: "https", host: nil}} = SnapshotFormat.decode(envelope)

    assert {:error, :unknown_snapshot_struct} =
             SnapshotFormat.decode(%{
               envelope
               | "value" => %{
                   "$type" => "struct",
                   "module" => "Elixir.Maraithon.NoSuchStruct",
                   "entries" => []
                 }
             })

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

  test "bounded legacy storage decoding accepts only safe uncompressed ETF and plain JSON" do
    term = %{mode: :scanning, tuple: {:ok, [1, 2, 3]}}
    legacy = %{"format" => "etf_base64", "data" => Base.encode64(:erlang.term_to_binary(term))}

    assert {:ok, ^term, :legacy_etf} = SnapshotFormat.decode_stored(legacy)

    assert {:ok, %{"plain" => [1, 2, 3]}, :legacy_json} =
             SnapshotFormat.decode_stored(%{"plain" => [1, 2, 3]})

    compressed =
      :erlang.term_to_binary(%{unsafe: String.duplicate("compressed", 10_000)}, compressed: 9)

    assert <<131, 80, _rest::binary>> = compressed

    assert {:error, :compressed_legacy_snapshot} =
             SnapshotFormat.decode_stored(%{
               "format" => "etf_base64",
               "data" => Base.encode64(compressed)
             })

    unknown_atom = "snapshot_atom_that_does_not_exist_1d8bca56"
    atom_etf = <<131, 119, byte_size(unknown_atom), unknown_atom::binary>>

    assert {:error, :invalid_legacy_snapshot} =
             SnapshotFormat.decode_stored(%{
               "format" => "etf_base64",
               "data" => Base.encode64(atom_etf)
             })

    assert {:error, :invalid_snapshot_format} =
             SnapshotFormat.decode_stored(%{"format" => "etf_base64", "data" => 123})

    too_deep = Enum.reduce(1..26, :ok, fn _index, value -> [value] end)

    assert {:error, :snapshot_too_deep} =
             SnapshotFormat.decode_stored(%{
               "format" => "etf_base64",
               "data" => Base.encode64(:erlang.term_to_binary(too_deep))
             })

    too_many_nodes = List.duplicate(Enum.to_list(1..10), 5_000)

    assert {:error, :snapshot_too_many_nodes} =
             SnapshotFormat.decode_stored(%{
               "format" => "etf_base64",
               "data" => Base.encode64(:erlang.term_to_binary(too_many_nodes))
             })
  end

  @tag :tmp_dir
  test "initial state corpus for every installed Behavior fits the closed grammar", %{
    tmp_dir: tmp_dir
  } do
    config = %{
      "user_id" => "snapshot-corpus@example.com",
      "name" => "snapshot-corpus",
      "codebase_path" => tmp_dir,
      "output_path" => Path.join(tmp_dir, "output")
    }

    assert Maraithon.Behaviors.list() != []

    Enum.each(Maraithon.Behaviors.list(), fn behavior ->
      module = Maraithon.Behaviors.get!(behavior)
      state = module.init(config)

      assert {:ok, envelope, bytes} = SnapshotFormat.encode(state),
             "#{behavior} init/1 returned an unsupported snapshot state"

      assert bytes <= SnapshotFormat.max_encoded_bytes()
      assert {:ok, ^state} = SnapshotFormat.decode(envelope)
    end)
  end
end
