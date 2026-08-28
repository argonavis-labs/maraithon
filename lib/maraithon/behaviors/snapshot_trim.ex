defmodule Maraithon.Behaviors.SnapshotTrim do
  @moduledoc """
  Shapes behavior state for a checkpoint snapshot.

  Transient working data (fetched source bundles, fetch telemetry) is dropped
  at every nesting level, and single strings above the snapshot scalar cap
  (raw email bodies, prompts, provider payloads) are truncated while keeping
  their type, so a checkpoint never exceeds `SnapshotFormat` limits and a
  restored state keeps its shape. Structs are walked field by field and
  rebuilt; calendar and similar value structs are left untouched.
  """

  require Logger

  @transient_keys [:source_bundle, :assistant_fetch_telemetry]
  @max_depth 24
  @scalar_limit_bytes 16_384
  @truncation_suffix "\n…[truncated for checkpoint]"
  @opaque_structs [DateTime, NaiveDateTime, Date, Time, Decimal, Regex, MapSet]

  @doc "Returns the trimmed state and logs the key paths that were truncated."
  def trim(state) when is_map(state) do
    {trimmed, paths} = walk(state, [], 0, [])

    if paths != [] do
      Logger.error("Checkpoint truncated oversized state strings",
        failure_code: "snapshot_scalar_truncated",
        paths: paths |> Enum.take(8) |> Enum.map_join(",", &Enum.join(&1, "."))
      )
    end

    trimmed
  end

  def trim(state), do: state

  defp walk(value, _path, depth, paths) when depth > @max_depth, do: {value, paths}

  defp walk(%{__struct__: module} = value, _path, _depth, paths) when module in @opaque_structs,
    do: {value, paths}

  defp walk(%{__struct__: module} = value, path, depth, paths) do
    {fields, paths} = walk(Map.from_struct(value), path, depth, paths)
    {struct(module, fields), paths}
  end

  defp walk(value, path, depth, paths) when is_map(value) do
    Enum.reduce(value, {%{}, paths}, fn
      {key, _inner}, {acc, paths} when key in @transient_keys ->
        {Map.put(acc, key, nil), paths}

      {key, inner}, {acc, paths} ->
        {stripped, paths} = walk(inner, [label(key) | path], depth + 1, paths)
        {Map.put(acc, key, stripped), paths}
    end)
  end

  defp walk(value, path, depth, paths) when is_tuple(value) do
    {items, paths} = walk(Tuple.to_list(value), path, depth, paths)
    {List.to_tuple(items), paths}
  end

  defp walk(value, path, depth, paths) when is_list(value) do
    {items, paths} =
      Enum.reduce(value, {[], paths}, fn item, {acc, paths} ->
        {stripped, paths} = walk(item, ["[]" | path], depth + 1, paths)
        {[stripped | acc], paths}
      end)

    {Enum.reverse(items), paths}
  end

  defp walk(value, path, _depth, paths)
       when is_binary(value) and byte_size(value) > @scalar_limit_bytes do
    truncated =
      value
      |> binary_part(0, @scalar_limit_bytes)
      |> valid_utf8_prefix()
      |> Kernel.<>(@truncation_suffix)

    {truncated, [Enum.reverse(path) | paths]}
  end

  defp walk(value, _path, _depth, paths), do: {value, paths}

  defp label(key) when is_atom(key), do: Atom.to_string(key)
  defp label(key) when is_binary(key), do: key
  defp label(key), do: inspect(key)

  defp valid_utf8_prefix(binary) do
    if String.valid?(binary),
      do: binary,
      else: binary |> String.chunk(:valid) |> List.first() || ""
  end
end
