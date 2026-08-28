defmodule Maraithon.Behaviors.SnapshotBudget do
  @moduledoc """
  Measures behavior state using the exact durable snapshot encoding.

  The returned byte count is the encoded JSON envelope size written for the
  behavior state. Encoding failures include paths to oversized scalar values
  when those paths can be identified.
  """

  alias Maraithon.Runtime.SnapshotFormat

  @max_depth 24
  @max_scalar_bytes 65_536
  @opaque_structs [DateTime, NaiveDateTime, Date, Time, Decimal, Regex, MapSet]

  @type path :: [String.t()]
  @type error :: {atom(), [path()]}

  @spec check(term()) :: {:ok, non_neg_integer()} | {:error, error()}
  def check(state) do
    case SnapshotFormat.encode(state) do
      {:ok, _encoded, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {reason, violation_paths(state)}}
    end
  end

  defp violation_paths(state) do
    {_state, paths} = walk(state, [], 0, [])
    paths |> Enum.reverse() |> Enum.take(20)
  end

  defp walk(value, _path, depth, paths) when depth > @max_depth, do: {value, paths}

  defp walk(%{__struct__: module} = value, _path, _depth, paths) when module in @opaque_structs,
    do: {value, paths}

  defp walk(%{__struct__: _module} = value, path, depth, paths),
    do: walk(Map.from_struct(value), path, depth, paths)

  defp walk(value, path, depth, paths) when is_map(value) do
    Enum.reduce(value, {value, paths}, fn {key, inner}, {state, paths} ->
      {_inner, paths} = walk(inner, [label(key) | path], depth + 1, paths)
      {state, paths}
    end)
  end

  defp walk(value, path, depth, paths) when is_tuple(value),
    do: walk(Tuple.to_list(value), path, depth, paths)

  defp walk(value, path, depth, paths) when is_list(value) do
    Enum.reduce(value, {value, paths}, fn inner, {state, paths} ->
      {_inner, paths} = walk(inner, ["[]" | path], depth + 1, paths)
      {state, paths}
    end)
  end

  defp walk(value, path, _depth, paths)
       when is_binary(value) and byte_size(value) > @max_scalar_bytes,
       do: {value, [Enum.reverse(path) | paths]}

  defp walk(value, _path, _depth, paths), do: {value, paths}

  defp label(key) when is_atom(key), do: Atom.to_string(key)
  defp label(key) when is_binary(key), do: key
  defp label(key), do: inspect(key)
end
