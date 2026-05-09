defmodule Maraithon.Tools.MemoryHelpers do
  @moduledoc false

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Memory.Item

  def list_opts(args, default_limit \\ 50) when is_map(args) do
    limit =
      args
      |> optional_integer("limit")
      |> case do
        nil -> default_limit
        value -> value |> max(1) |> min(100)
      end

    []
    |> Keyword.put(:limit, limit)
    |> maybe_put(:query, optional_string(args, "query"))
    |> maybe_put(:status, optional_string(args, "status"))
    |> maybe_put(:kind, optional_string(args, "kind"))
    |> maybe_put(:scope, optional_string(args, "scope"))
    |> maybe_put(:tag, optional_string(args, "tag"))
  end

  def recall_opts(args, default_limit \\ 12) when is_map(args) do
    limit =
      args
      |> optional_integer("limit")
      |> case do
        nil -> default_limit
        value -> value |> max(1) |> min(40)
      end

    []
    |> Keyword.put(:limit, limit)
    |> maybe_put(:kind, optional_string(args, "kind"))
    |> maybe_put(:scope, optional_string(args, "scope"))
    |> maybe_put(:tag, optional_string(args, "tag"))
    |> maybe_put(:llm_complete, optional_function(args, "llm_complete"))
  end

  def memory_attrs(args) when is_map(args) do
    case Map.get(args, "memory") do
      memory when is_map(memory) -> memory
      _other -> Map.drop(args, ["user_id", "include_recall", "query"])
    end
  end

  def feedback_attrs(args) when is_map(args) do
    case Map.get(args, "feedback") do
      feedback when is_map(feedback) -> feedback
      _other -> Map.drop(args, ["user_id"])
    end
  end

  def serialize_item(%Item{} = item), do: Maraithon.Memory.serialize_item(item)
  def serialize_item(%{} = item), do: Maraithon.Memory.serialize_item(item)

  defp optional_function(args, key) when is_map(args) do
    case Map.get(args, key) || Map.get(args, :llm_complete) do
      fun when is_function(fun, 1) -> fun
      _other -> nil
    end
  end
end
