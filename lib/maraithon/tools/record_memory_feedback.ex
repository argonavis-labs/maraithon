defmodule Maraithon.Tools.RecordMemoryFeedback do
  @moduledoc """
  Record durable relevance feedback as memory.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Memory
  alias Maraithon.Tools.MemoryHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      case Memory.record_relevance_feedback(user_id, MemoryHelpers.feedback_attrs(args),
             source: "mcp"
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

  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: safe_error(reason)
end
