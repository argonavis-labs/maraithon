defmodule Maraithon.Tools.UpdateMemoryConfidence do
  @moduledoc """
  Update the confidence score for one durable deep memory item.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Memory
  alias Maraithon.Tools.MemoryHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, memory_id} <- required_string(args, "memory_id"),
         {:ok, confidence} <- confidence(args) do
      case Memory.update_confidence(user_id, memory_id, confidence,
             source: "mcp",
             reason: optional_string(args, "reason")
           ) do
        {:ok, item} ->
          {:ok,
           %{
             source: "maraithon_memory",
             memory: MemoryHelpers.serialize_item(item)
           }}

        {:error, reason} ->
          {:error, normalize_error(reason)}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp confidence(args) do
    case Map.get(args, "confidence") || Map.get(args, :confidence) do
      value when is_float(value) and value >= 0.0 and value <= 1.0 -> {:ok, value}
      value when is_integer(value) and value >= 0 and value <= 1 -> {:ok, value / 1}
      value when is_binary(value) -> parse_confidence(value)
      _other -> {:error, "confidence must be between 0.0 and 1.0"}
    end
  end

  defp parse_confidence(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0.0 and parsed <= 1.0 -> {:ok, parsed}
      _other -> {:error, "confidence must be between 0.0 and 1.0"}
    end
  end

  defp normalize_error(:memory_not_found), do: "memory_not_found"
  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: inspect(reason)
end
