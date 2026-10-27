defmodule Maraithon.BoundedJSON do
  @moduledoc false

  @default_max_depth 10
  @default_max_nodes 20_000
  @default_max_map_entries 2_000
  @default_max_list_items 2_000
  @default_max_binary_bytes 64_000
  @max_configured_limit 2_000_000

  def valid?(value, max_bytes, opts \\ [])

  def valid?(value, max_bytes, opts)
      when is_integer(max_bytes) and max_bytes > 0 and is_list(opts) do
    limits = %{
      max_bytes: min(max_bytes, @max_configured_limit),
      max_binary_bytes: limit(opts[:max_binary_bytes], @default_max_binary_bytes),
      max_depth: limit(opts[:max_depth], @default_max_depth),
      max_nodes: limit(opts[:max_nodes], @default_max_nodes),
      max_map_entries: limit(opts[:max_map_entries], @default_max_map_entries),
      max_list_items: limit(opts[:max_list_items], @default_max_list_items)
    }

    match?({:ok, _nodes, _bytes}, preflight(value, 0, 0, 0, limits))
  end

  def valid?(_value, _max_bytes, _opts), do: false

  defp limit(value, _default) when is_integer(value) and value > 0,
    do: min(value, @max_configured_limit)

  defp limit(_value, default), do: default

  defp preflight(_value, _depth, nodes, _bytes, %{max_nodes: max_nodes})
       when nodes >= max_nodes,
       do: :error

  defp preflight(_value, depth, _nodes, _bytes, %{max_depth: max_depth})
       when depth > max_depth,
       do: :error

  defp preflight(%module{}, _depth, nodes, bytes, limits)
       when module in [DateTime, NaiveDateTime, Date, Time],
       do: add_cost(nodes, bytes, 64, limits)

  defp preflight(value, _depth, nodes, bytes, limits) when is_binary(value) do
    if byte_size(value) <= limits.max_binary_bytes and String.valid?(value) and
         :binary.match(value, <<0>>) == :nomatch,
       do: add_cost(nodes, bytes, byte_size(value) + 2, limits),
       else: :error
  end

  defp preflight(value, _depth, nodes, bytes, limits)
       when is_integer(value) and value >= -9_223_372_036_854_775_808 and
              value <= 9_223_372_036_854_775_807,
       do: add_cost(nodes, bytes, 32, limits)

  defp preflight(value, _depth, nodes, bytes, limits) when is_float(value) do
    if value == value and abs(value) <= 1.797_693_134_862_315_7e308,
      do: add_cost(nodes, bytes, 32, limits),
      else: :error
  end

  defp preflight(value, _depth, nodes, bytes, limits)
       when is_boolean(value) or is_nil(value),
       do: add_cost(nodes, bytes, 32, limits)

  defp preflight(value, depth, nodes, bytes, limits) when is_map(value) do
    if map_size(value) > limits.max_map_entries or not unique_json_keys?(value) do
      :error
    else
      with {:ok, next_nodes, next_bytes} <- add_cost(nodes, bytes, 2, limits) do
        Enum.reduce_while(value, {:ok, next_nodes, next_bytes}, fn {key, nested},
                                                                   {:ok, count, size} ->
          with {:ok, key_cost} <- json_key_cost(key),
               {:ok, key_nodes, key_bytes} <- add_cost(count, size, key_cost, limits),
               {:ok, nested_nodes, nested_bytes} <-
                 preflight(nested, depth + 1, key_nodes, key_bytes, limits) do
            {:cont, {:ok, nested_nodes, nested_bytes}}
          else
            _error -> {:halt, :error}
          end
        end)
      end
    end
  end

  defp preflight(value, depth, nodes, bytes, limits) when is_list(value) do
    with {:ok, next_nodes, next_bytes} <- add_cost(nodes, bytes, 2, limits) do
      preflight_list(value, depth, next_nodes, next_bytes, 0, limits)
    end
  end

  defp preflight(_value, _depth, _nodes, _bytes, _limits), do: :error

  defp preflight_list([], _depth, nodes, bytes, _items, _limits),
    do: {:ok, nodes, bytes}

  defp preflight_list(_list, _depth, _nodes, _bytes, items, %{max_list_items: max_items})
       when items >= max_items,
       do: :error

  defp preflight_list([head | tail], depth, nodes, bytes, items, limits) do
    case preflight(head, depth + 1, nodes, bytes, limits) do
      {:ok, next_nodes, next_bytes} ->
        preflight_list(tail, depth, next_nodes, next_bytes, items + 1, limits)

      :error ->
        :error
    end
  end

  defp preflight_list(_improper, _depth, _nodes, _bytes, _items, _limits), do: :error

  defp unique_json_keys?(value) do
    value
    |> Enum.reduce_while(MapSet.new(), fn {key, _nested}, seen ->
      case json_key_identity(key) do
        {:ok, identity} ->
          if MapSet.member?(seen, identity),
            do: {:halt, :duplicate},
            else: {:cont, MapSet.put(seen, identity)}

        :error ->
          {:halt, :duplicate}
      end
    end)
    |> is_struct(MapSet)
  rescue
    _error -> false
  end

  defp json_key_identity(key) when is_binary(key) and byte_size(key) <= 255 do
    if String.valid?(key) and :binary.match(key, <<0>>) == :nomatch,
      do: {:ok, key},
      else: :error
  end

  defp json_key_identity(key) when is_atom(key), do: json_key_identity(Atom.to_string(key))

  defp json_key_identity(key)
       when is_integer(key) and key >= -9_223_372_036_854_775_808 and
              key <= 9_223_372_036_854_775_807,
       do: {:ok, Integer.to_string(key)}

  defp json_key_identity(_key), do: :error

  defp add_cost(nodes, bytes, cost, limits) do
    if nodes + 1 <= limits.max_nodes and bytes + cost <= limits.max_bytes,
      do: {:ok, nodes + 1, bytes + cost},
      else: :error
  end

  defp json_key_cost(key) when is_binary(key) and byte_size(key) <= 255 do
    if String.valid?(key) and :binary.match(key, <<0>>) == :nomatch,
      do: {:ok, byte_size(key) + 3},
      else: :error
  end

  defp json_key_cost(key) when is_atom(key), do: json_key_cost(Atom.to_string(key))

  defp json_key_cost(key)
       when is_integer(key) and key >= -9_223_372_036_854_775_808 and
              key <= 9_223_372_036_854_775_807,
       do: {:ok, 32}

  defp json_key_cost(_key), do: :error
end
