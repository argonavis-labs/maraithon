defmodule Maraithon.AssistantHarness.PromptStability do
  @moduledoc """
  Deterministic JSON encoding so the assistant prompt cache stays warm.

  Jason encodes map keys in iteration order, which for runtime-built maps is
  effectively undefined. That means two semantically-identical context
  snapshots can serialize to different bytes and miss the Anthropic prompt
  cache. This module walks the value tree, sorts every map by string-cast
  key, normalizes structs/datetimes/refs, and produces a stable JSON string.

  Inspired by openclaw's `prompt-cache-stability.ts`.
  """

  @doc """
  Encode a value as JSON with all maps sorted by key. Lists stay in their
  original order — callers who care about list stability should sort the
  list themselves before passing it in.
  """
  def encode!(value) do
    value
    |> normalize()
    |> Jason.encode!()
  end

  @doc false
  def normalize(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), normalize(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def normalize(%Date{} = value), do: Date.to_iso8601(value)
  def normalize(%Time{} = value), do: Time.to_iso8601(value)

  def normalize(%_{} = struct) do
    struct |> Map.from_struct() |> normalize()
  end

  def normalize(value) when is_tuple(value), do: inspect(value)
  def normalize(value) when is_pid(value), do: inspect(value)
  def normalize(value) when is_reference(value), do: inspect(value)
  def normalize(value) when is_function(value), do: inspect(value)
  def normalize(value), do: value
end
