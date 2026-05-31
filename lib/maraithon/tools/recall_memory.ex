defmodule Maraithon.Tools.RecallMemory do
  @moduledoc """
  Recall relevant durable memories for a user query.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Memory
  alias Maraithon.Tools.MemoryHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      query = optional_string(args, "query") || optional_string(args, "text") || ""

      case Memory.recall(user_id, query, MemoryHelpers.recall_opts(args)) do
        {:ok, result} ->
          {:ok,
           %{
             source: "maraithon_memory",
             query: result.query,
             count: result.count,
             summary: result.summary,
             memories: result.memories
           }}

        {:error, reason} ->
          {:error, normalize_error(reason)}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: safe_error(reason)
end
