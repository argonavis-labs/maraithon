defmodule Maraithon.Runtime.SnapshotFormat do
  require Logger

  @moduledoc """
  Closed, bounded, versioned JSON encoding for durable Agent snapshots.

  The wire grammar is language-neutral and preserves the distinctions behavior
  state depends on: symbols versus strings, tuples versus lists, typed map keys,
  calendar values, and arbitrary bytes. Unknown tags and versions fail closed.
  """

  @format "maraithon.agent_snapshot"
  @legacy_format "etf_base64"
  @format_version 1
  @max_encoded_bytes 1_048_576
  # The historical writer emitted uncompressed ETF. Keep the temporary reader
  # byte-bounded before `binary_to_term/2`; the closed v1 encoder then enforces
  # the stricter depth/node/type grammar before a legacy value is accepted.
  @max_legacy_etf_bytes @max_encoded_bytes
  @max_scalar_bytes 65_536
  @max_depth 24
  @max_nodes 50_000
  @max_map_entries 2_000
  @max_collection_items 5_000
  @max_symbol_bytes 255
  @min_int64 -9_223_372_036_854_775_808
  @max_int64 9_223_372_036_854_775_807

  @type envelope :: map()

  @spec encode(term()) :: {:ok, envelope(), non_neg_integer()} | {:error, atom()}
  def encode(term) do
    with {:ok, encoded, _nodes} <- encode_node(term, 0, 0),
         envelope = %{
           "format" => @format,
           "format_version" => @format_version,
           "value" => encoded
         },
         {:ok, json} <- Jason.encode(envelope),
         true <- byte_size(json) <= @max_encoded_bytes do
      {:ok, envelope, byte_size(json)}
    else
      false ->
        Logger.warning("Snapshot exceeds the encoded size cap",
          failure_code: "snapshot_too_large",
          snapshot_bytes: encoded_size(term)
        )

        {:error, :snapshot_too_large}

      {:error, %Jason.EncodeError{}} ->
        {:error, :unsupported_snapshot_type}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _other ->
        {:error, :unsupported_snapshot_type}
    end
  rescue
    _error -> {:error, :unsupported_snapshot_type}
  end

  @spec decode(envelope()) :: {:ok, term()} | {:error, atom()}
  def decode(
        %{
          "format" => @format,
          "format_version" => @format_version,
          "value" => value
        } = envelope
      )
      when map_size(envelope) == 3 do
    with {:ok, json} <- Jason.encode(envelope),
         true <- byte_size(json) <= @max_encoded_bytes,
         {:ok, decoded, _nodes} <- decode_node(value, 0, 0) do
      {:ok, decoded}
    else
      false -> {:error, :snapshot_too_large}
      {:error, %Jason.EncodeError{}} -> {:error, :invalid_snapshot_format}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :invalid_snapshot_format}
    end
  rescue
    _error -> {:error, :invalid_snapshot_format}
  end

  def decode(%{"format" => @format}), do: {:error, :unknown_snapshot_format_version}
  def decode(_other), do: {:error, :invalid_snapshot_format}

  @doc """
  Decode one value as stored in a snapshot JSONB column.

  Tagged v1 is the only write format. The two `:legacy_*` results exist solely
  for the bounded online migration and can be removed after the tagged-v1
  constraint is validated in production.
  """
  @spec decode_stored(term()) ::
          {:ok, term(), :tagged_v1 | :legacy_etf | :legacy_json} | {:error, atom()}
  def decode_stored(%{"format" => @format} = envelope) do
    with {:ok, term} <- decode(envelope) do
      {:ok, term, :tagged_v1}
    end
  end

  def decode_stored(%{"format" => @legacy_format, "data" => data} = envelope)
      when map_size(envelope) == 2 and is_binary(data) do
    decode_legacy_etf(data)
  end

  # The legacy and current wrapper names are reserved. A malformed wrapper
  # must fail closed rather than being mistaken for a pre-wrapper plain-JSON
  # behavior state.
  def decode_stored(%{"format" => format}) when format in [@format, @legacy_format],
    do: {:error, :invalid_snapshot_format}

  def decode_stored(other) do
    with true <-
           Maraithon.BoundedJSON.valid?(other, @max_encoded_bytes,
             max_binary_bytes: @max_scalar_bytes,
             max_depth: @max_depth,
             max_nodes: @max_nodes,
             max_map_entries: @max_map_entries,
             max_list_items: @max_collection_items
           ),
         {:ok, json} <- Jason.encode(other),
         true <- byte_size(json) <= @max_encoded_bytes,
         {:ok, _envelope, _bytes} <- encode(other) do
      {:ok, other, :legacy_json}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :invalid_legacy_snapshot}
    end
  rescue
    _error -> {:error, :invalid_legacy_snapshot}
  end

  def format, do: @format
  def version, do: @format_version
  def max_encoded_bytes, do: @max_encoded_bytes

  # Includes base64 expansion and the small JSON wrapper overhead. Database
  # batch readers use this to avoid transferring an unbounded legacy JSONB
  # value into the BEAM before the decoder can reject it.
  def max_legacy_stored_bytes,
    do: div((@max_legacy_etf_bytes + 2) * 4, 3) + 128

  defp decode_legacy_etf(data) do
    max_base64_bytes = div((@max_legacy_etf_bytes + 2) * 4, 3)

    with true <- byte_size(data) <= max_base64_bytes,
         {:ok, binary} <- Base.decode64(data),
         true <- byte_size(binary) <= @max_legacy_etf_bytes,
         :ok <- uncompressed_etf(binary),
         {:ok, term} <- safe_binary_to_term(binary),
         {:ok, _envelope, _bytes} <- encode(term) do
      {:ok, term, :legacy_etf}
    else
      false -> {:error, :legacy_snapshot_too_large}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :invalid_legacy_snapshot}
    end
  end

  defp uncompressed_etf(<<131, 80, _rest::binary>>),
    do: {:error, :compressed_legacy_snapshot}

  defp uncompressed_etf(<<131, _rest::binary>>), do: :ok
  defp uncompressed_etf(_binary), do: {:error, :invalid_legacy_snapshot}

  defp safe_binary_to_term(binary) do
    case :erlang.binary_to_term(binary, [:safe, :used]) do
      {term, used} when used == byte_size(binary) -> {:ok, term}
      _other -> {:error, :invalid_legacy_snapshot}
    end
  rescue
    _error -> {:error, :invalid_legacy_snapshot}
  end

  defp encode_node(_term, depth, _nodes) when depth > @max_depth,
    do: {:error, :snapshot_too_deep}

  defp encode_node(_term, _depth, nodes) when nodes >= @max_nodes,
    do: {:error, :snapshot_too_many_nodes}

  defp encode_node(nil, _depth, nodes), do: {:ok, nil, nodes + 1}
  defp encode_node(value, _depth, nodes) when is_boolean(value), do: {:ok, value, nodes + 1}

  defp encode_node(value, _depth, nodes)
       when is_integer(value) and value >= @min_int64 and value <= @max_int64 do
    {:ok, %{"$type" => "int64", "value" => Integer.to_string(value)}, nodes + 1}
  end

  defp encode_node(value, _depth, _nodes) when is_integer(value),
    do: {:error, :snapshot_integer_out_of_range}

  defp encode_node(value, _depth, nodes) when is_float(value) do
    encoded = :erlang.float_to_binary(value, [:short])

    case Jason.encode(value) do
      {:ok, _json} -> {:ok, %{"$type" => "float64", "value" => encoded}, nodes + 1}
      _other -> {:error, :unsupported_snapshot_type}
    end
  end

  defp encode_node(value, _depth, nodes) when is_binary(value) do
    cond do
      byte_size(value) > @max_scalar_bytes ->
        {:error, :snapshot_scalar_too_large}

      String.valid?(value) ->
        {:ok, value, nodes + 1}

      true ->
        {:ok,
         %{
           "$type" => "bytes",
           "encoding" => "base64url",
           "value" => Base.url_encode64(value, padding: false)
         }, nodes + 1}
    end
  end

  defp encode_node(value, _depth, nodes) when is_atom(value) do
    symbol = Atom.to_string(value)

    if byte_size(symbol) <= @max_symbol_bytes and String.valid?(symbol),
      do: {:ok, %{"$type" => "symbol", "value" => symbol}, nodes + 1},
      else: {:error, :snapshot_scalar_too_large}
  end

  defp encode_node(%DateTime{calendar: Calendar.ISO} = value, _depth, nodes) do
    {:ok,
     %{
       "$type" => "datetime",
       "naive" => value |> DateTime.to_naive() |> NaiveDateTime.to_iso8601(),
       "time_zone" => value.time_zone,
       "zone_abbr" => value.zone_abbr,
       "utc_offset" => Integer.to_string(value.utc_offset),
       "std_offset" => Integer.to_string(value.std_offset)
     }, nodes + 1}
  end

  defp encode_node(%NaiveDateTime{calendar: Calendar.ISO} = value, _depth, nodes),
    do:
      {:ok, %{"$type" => "naive_datetime", "value" => NaiveDateTime.to_iso8601(value)}, nodes + 1}

  defp encode_node(%Date{calendar: Calendar.ISO} = value, _depth, nodes),
    do: {:ok, %{"$type" => "date", "value" => Date.to_iso8601(value)}, nodes + 1}

  defp encode_node(%Time{calendar: Calendar.ISO} = value, _depth, nodes),
    do: {:ok, %{"$type" => "time", "value" => Time.to_iso8601(value)}, nodes + 1}

  # Plain data structs (behavior state routinely holds LLM response, usage,
  # and similar structs) round-trip as their fields plus the module name.
  # Decoding only rebuilds modules that already exist and define a struct.
  defp encode_node(%{__struct__: module} = value, depth, nodes) when is_atom(module) do
    fields = Map.from_struct(value)

    with true <- map_size(fields) <= @max_map_entries,
         {:ok, entries, nodes} <- encode_map(fields, depth + 1, nodes + 1) do
      entries = Enum.sort_by(entries, &encoded_key/1)

      {:ok, %{"$type" => "struct", "module" => Atom.to_string(module), "entries" => entries},
       nodes}
    else
      false -> {:error, :snapshot_map_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp encode_node(value, depth, nodes) when is_tuple(value) do
    items = Tuple.to_list(value)

    with true <- bounded_collection?(items),
         {:ok, encoded, nodes} <- encode_many(items, depth + 1, nodes + 1) do
      {:ok, %{"$type" => "tuple", "items" => encoded}, nodes}
    else
      false -> {:error, :snapshot_collection_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp encode_node(value, depth, nodes) when is_list(value) do
    if bounded_collection?(value),
      do: encode_many(value, depth + 1, nodes + 1),
      else: {:error, :snapshot_collection_too_large}
  end

  defp encode_node(value, depth, nodes) when is_map(value) do
    with true <- map_size(value) <= @max_map_entries,
         {:ok, entries, nodes} <- encode_map(value, depth + 1, nodes + 1) do
      entries = Enum.sort_by(entries, &encoded_key/1)
      {:ok, %{"$type" => "map", "entries" => entries}, nodes}
    else
      false -> {:error, :snapshot_map_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp encode_node(value, _depth, _nodes) do
    Logger.warning("Snapshot value type is not encodable",
      failure_code: "unsupported_snapshot_type:" <> erlang_type(value)
    )

    {:error, :unsupported_snapshot_type}
  end

  defp erlang_type(value) when is_pid(value), do: "pid"
  defp erlang_type(value) when is_reference(value), do: "reference"
  defp erlang_type(value) when is_function(value), do: "function"
  defp erlang_type(value) when is_port(value), do: "port"
  defp erlang_type(_value), do: "unknown"

  defp encode_many(values, depth, nodes) do
    Enum.reduce_while(values, {:ok, [], nodes}, fn value, {:ok, encoded, count} ->
      case encode_node(value, depth, count) do
        {:ok, item, next_count} -> {:cont, {:ok, [item | encoded], next_count}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp encode_map(map, depth, nodes) do
    Enum.reduce_while(map, {:ok, [], nodes}, fn {key, value}, {:ok, encoded, count} ->
      with {:ok, encoded_key, count} <- encode_node(key, depth, count),
           {:ok, encoded_value, count} <- encode_node(value, depth, count) do
        {:cont, {:ok, [[encoded_key, encoded_value] | encoded], count}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp reverse_result({:ok, values, count}), do: {:ok, Enum.reverse(values), count}
  defp reverse_result({:error, _reason} = error), do: error

  defp encoded_key([key, _value]), do: key |> Jason.encode_to_iodata!() |> IO.iodata_to_binary()

  defp decode_node(_value, depth, _nodes) when depth > @max_depth,
    do: {:error, :snapshot_too_deep}

  defp decode_node(_value, _depth, nodes) when nodes >= @max_nodes,
    do: {:error, :snapshot_too_many_nodes}

  defp decode_node(nil, _depth, nodes), do: {:ok, nil, nodes + 1}
  defp decode_node(value, _depth, nodes) when is_boolean(value), do: {:ok, value, nodes + 1}

  defp decode_node(value, _depth, nodes) when is_binary(value) do
    if byte_size(value) <= @max_scalar_bytes and String.valid?(value),
      do: {:ok, value, nodes + 1},
      else: {:error, :invalid_snapshot_format}
  end

  defp decode_node(%{"$type" => "int64", "value" => value} = node, _depth, nodes)
       when map_size(node) == 2 and is_binary(value) do
    with {integer, ""} <- Integer.parse(value),
         true <- integer >= @min_int64 and integer <= @max_int64,
         true <- Integer.to_string(integer) == value do
      {:ok, integer, nodes + 1}
    else
      _other -> {:error, :invalid_snapshot_format}
    end
  end

  defp decode_node(%{"$type" => "float64", "value" => value} = node, _depth, nodes)
       when map_size(node) == 2 and is_binary(value) do
    with {float, ""} <- Float.parse(value),
         true <- :erlang.float_to_binary(float, [:short]) == value,
         {:ok, _json} <- Jason.encode(float) do
      {:ok, float, nodes + 1}
    else
      _other -> {:error, :invalid_snapshot_format}
    end
  end

  defp decode_node(
         %{"$type" => "bytes", "encoding" => "base64url", "value" => value} = node,
         _depth,
         nodes
       )
       when map_size(node) == 3 and is_binary(value) do
    with true <- byte_size(value) <= encoded_scalar_limit(),
         {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- byte_size(decoded) <= @max_scalar_bytes do
      {:ok, decoded, nodes + 1}
    else
      _other -> {:error, :invalid_snapshot_format}
    end
  end

  defp decode_node(%{"$type" => "symbol", "value" => value} = node, _depth, nodes)
       when map_size(node) == 2 and is_binary(value) and byte_size(value) <= @max_symbol_bytes do
    try do
      {:ok, String.to_existing_atom(value), nodes + 1}
    rescue
      ArgumentError -> {:error, :unknown_snapshot_symbol}
    end
  end

  defp decode_node(
         %{"$type" => "struct", "module" => module_name, "entries" => entries} = node,
         depth,
         nodes
       )
       when map_size(node) == 3 and is_binary(module_name) and
              byte_size(module_name) <= @max_symbol_bytes and is_list(entries) do
    with {:ok, module} <- existing_struct_module(module_name),
         true <- bounded_map?(entries),
         {:ok, fields, nodes} <- decode_map(entries, depth + 1, nodes + 1) do
      {:ok, struct(module, fields), nodes}
    else
      false -> {:error, :snapshot_map_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp decode_node(%{"$type" => "tuple", "items" => items} = node, depth, nodes)
       when map_size(node) == 2 and is_list(items) do
    with true <- bounded_collection?(items),
         {:ok, decoded, nodes} <- decode_many(items, depth + 1, nodes + 1) do
      {:ok, List.to_tuple(decoded), nodes}
    else
      false -> {:error, :snapshot_collection_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp decode_node(%{"$type" => "map", "entries" => entries} = node, depth, nodes)
       when map_size(node) == 2 and is_list(entries) do
    if bounded_map?(entries),
      do: decode_map(entries, depth + 1, nodes + 1),
      else: {:error, :snapshot_map_too_large}
  end

  defp decode_node(%{"$type" => "date", "value" => value} = node, _depth, nodes)
       when map_size(node) == 2 and is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date, nodes + 1}
      _other -> {:error, :invalid_snapshot_format}
    end
  end

  defp decode_node(%{"$type" => "time", "value" => value} = node, _depth, nodes)
       when map_size(node) == 2 and is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, time, nodes + 1}
      _other -> {:error, :invalid_snapshot_format}
    end
  end

  defp decode_node(
         %{"$type" => "naive_datetime", "value" => value} = node,
         _depth,
         nodes
       )
       when map_size(node) == 2 and is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} -> {:ok, datetime, nodes + 1}
      _other -> {:error, :invalid_snapshot_format}
    end
  end

  defp decode_node(
         %{
           "$type" => "datetime",
           "naive" => naive,
           "time_zone" => time_zone,
           "zone_abbr" => zone_abbr,
           "utc_offset" => utc_offset,
           "std_offset" => std_offset
         } = node,
         _depth,
         nodes
       )
       when map_size(node) == 6 and is_binary(naive) and is_binary(time_zone) and
              is_binary(zone_abbr) and is_binary(utc_offset) and is_binary(std_offset) do
    with true <- valid_zone_string?(time_zone),
         true <- valid_zone_string?(zone_abbr),
         {:ok, naive} <- NaiveDateTime.from_iso8601(naive),
         {:ok, utc_offset} <- parse_offset(utc_offset),
         {:ok, std_offset} <- parse_offset(std_offset) do
      {:ok, datetime_from_parts(naive, time_zone, zone_abbr, utc_offset, std_offset), nodes + 1}
    else
      _other -> {:error, :invalid_snapshot_format}
    end
  end

  defp decode_node(value, depth, nodes) when is_list(value) do
    if bounded_collection?(value),
      do: decode_many(value, depth + 1, nodes + 1),
      else: {:error, :snapshot_collection_too_large}
  end

  defp decode_node(_value, _depth, _nodes), do: {:error, :invalid_snapshot_format}

  defp decode_many(values, depth, nodes) do
    Enum.reduce_while(values, {:ok, [], nodes}, fn value, {:ok, decoded, count} ->
      case decode_node(value, depth, count) do
        {:ok, item, next_count} -> {:cont, {:ok, [item | decoded], next_count}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp decode_map(entries, depth, nodes) do
    Enum.reduce_while(entries, {:ok, %{}, nodes}, fn
      [encoded_key, encoded_value], {:ok, decoded, count} ->
        with {:ok, key, count} <- decode_node(encoded_key, depth, count),
             {:ok, value, count} <- decode_node(encoded_value, depth, count),
             false <- Map.has_key?(decoded, key) do
          {:cont, {:ok, Map.put(decoded, key, value), count}}
        else
          true -> {:halt, {:error, :duplicate_snapshot_map_key}}
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid_entry, _acc ->
        {:halt, {:error, :invalid_snapshot_format}}
    end)
  end

  defp encoded_size(term) do
    case encode_node(term, 0, 0) do
      {:ok, encoded, _nodes} -> encoded |> Jason.encode!() |> byte_size()
      _error -> nil
    end
  rescue
    _error -> nil
  end

  defp existing_struct_module(name) do
    module = String.to_existing_atom(name)

    if Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0),
      do: {:ok, module},
      else: {:error, :unknown_snapshot_struct}
  rescue
    ArgumentError -> {:error, :unknown_snapshot_struct}
  end

  defp bounded_collection?(values),
    do: values |> Enum.take(@max_collection_items + 1) |> length() <= @max_collection_items

  defp bounded_map?(entries),
    do: entries |> Enum.take(@max_map_entries + 1) |> length() <= @max_map_entries

  defp encoded_scalar_limit, do: div((@max_scalar_bytes + 2) * 4, 3)

  defp valid_zone_string?(value),
    do: byte_size(value) in 1..255 and String.valid?(value) and not String.contains?(value, <<0>>)

  defp parse_offset(value) do
    case Integer.parse(value) do
      {offset, ""} when offset in -86_400..86_400 ->
        if Integer.to_string(offset) == value,
          do: {:ok, offset},
          else: {:error, :invalid_offset}

      _other ->
        {:error, :invalid_offset}
    end
  end

  defp datetime_from_parts(naive, time_zone, zone_abbr, utc_offset, std_offset) do
    %DateTime{
      year: naive.year,
      month: naive.month,
      day: naive.day,
      hour: naive.hour,
      minute: naive.minute,
      second: naive.second,
      microsecond: naive.microsecond,
      time_zone: time_zone,
      zone_abbr: zone_abbr,
      utc_offset: utc_offset,
      std_offset: std_offset,
      calendar: Calendar.ISO
    }
  end
end
