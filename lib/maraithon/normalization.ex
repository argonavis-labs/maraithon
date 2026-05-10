defmodule Maraithon.Normalization do
  @moduledoc """
  Small normalization helpers shared by product infrastructure modules.

  These helpers keep controller/protocol/context code from growing local copies
  of the same map, scalar, and JSON-safe serialization routines.
  """

  @doc """
  Converts atom and other map keys to strings recursively.

  Structs are preserved because many Elixir structs, especially date/time
  structs, are maps internally but should not be rewritten as plain maps during
  input normalization.
  """
  def stringify_keys(%_{} = struct), do: struct

  def stringify_keys(value) when is_map(value) do
    Map.new(value, fn
      {key, nested} when is_atom(key) -> {Atom.to_string(key), stringify_keys(nested)}
      {key, nested} when is_binary(key) -> {key, stringify_keys(nested)}
      {key, nested} -> {to_string(key), stringify_keys(nested)}
    end)
  end

  def stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  def stringify_keys(value), do: value

  def read_string(attrs, key, default \\ nil)

  def read_string(attrs, key, default) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    case Map.get(attrs, to_string(key), default) do
      nil -> default
      "" -> default
      value when is_binary(value) -> value |> String.trim() |> blank_to_default(default)
      value -> value |> to_string() |> String.trim() |> blank_to_default(default)
    end
  end

  def read_string(_attrs, _key, default), do: default

  def read_map(attrs, key, default \\ %{})

  def read_map(attrs, key, default) when is_map(attrs) do
    case Map.get(stringify_keys(attrs), to_string(key), default) do
      value when is_map(value) and not is_struct(value) -> stringify_keys(value)
      _ -> default
    end
  end

  def read_map(_attrs, _key, default), do: default

  def read_list(attrs, key) when is_map(attrs) do
    attrs
    |> stringify_keys()
    |> Map.get(to_string(key))
    |> string_list()
  end

  def read_list(_attrs, _key), do: []

  def read_list_if_present(attrs, key) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    key = to_string(key)

    if Map.has_key?(attrs, key), do: read_list(attrs, key), else: nil
  end

  def read_list_if_present(_attrs, _key), do: nil

  def string_list(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def string_list(_value), do: []

  def read_integer(attrs, key) when is_map(attrs) do
    attrs
    |> stringify_keys()
    |> Map.get(to_string(key))
    |> parse_integer()
  end

  def read_integer(_attrs, _key), do: nil

  def parse_integer(value) when is_integer(value), do: value

  def parse_integer(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  def parse_integer(_value), do: nil

  def parse_datetime(nil), do: {:error, :invalid_datetime}
  def parse_datetime(%DateTime{} = datetime), do: {:ok, DateTime.truncate(datetime, :second)}

  def parse_datetime(%NaiveDateTime{} = naive) do
    naive
    |> NaiveDateTime.truncate(:second)
    |> DateTime.from_naive("Etc/UTC")
  end

  def parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.truncate(datetime, :second)}

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> parse_datetime(naive)
          _ -> {:error, :invalid_datetime}
        end
    end
  end

  def parse_datetime(_value), do: {:error, :invalid_datetime}

  def read_datetime(attrs, key, default \\ nil)

  def read_datetime(attrs, key, default) when is_map(attrs) do
    attrs
    |> stringify_keys()
    |> Map.get(to_string(key))
    |> parse_datetime()
    |> case do
      {:ok, datetime} -> datetime
      {:error, _reason} -> default
    end
  end

  def read_datetime(_attrs, _key, default), do: default

  def clamp_limit(value, default, max_value, min_value \\ 1)

  def clamp_limit(value, _default, max_value, min_value) when is_integer(value) do
    value
    |> max(min_value)
    |> min(max_value)
  end

  def clamp_limit(value, default, max_value, min_value) when is_binary(value) do
    case parse_integer(value) do
      parsed when is_integer(parsed) -> clamp_limit(parsed, default, max_value, min_value)
      nil -> default
    end
  end

  def clamp_limit(_value, default, _max_value, _min_value), do: default

  def normalize_json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize_json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def normalize_json_value(%Date{} = value), do: Date.to_iso8601(value)
  def normalize_json_value(%Time{} = value), do: Time.to_iso8601(value)
  def normalize_json_value(value) when is_atom(value), do: Atom.to_string(value)

  def normalize_json_value(value) when is_list(value),
    do: Enum.map(value, &normalize_json_value/1)

  def normalize_json_value(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_json_value()
  end

  def normalize_json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_json_value(nested)} end)
  end

  def normalize_json_value(value), do: value

  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(value), do: to_string(value)

  def compact(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def compact(_value), do: %{}

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value
end
