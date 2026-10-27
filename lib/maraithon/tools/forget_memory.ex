defmodule Maraithon.Tools.ForgetMemory do
  @moduledoc """
  Archive, supersede, or reject one durable memory item.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Memory
  alias Maraithon.Tools.MemoryHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, memory_ref} <- memory_ref(args) do
      status = optional_string(args, "status") || "archived"

      case Memory.forget(user_id, memory_ref, source: "mcp", status: status) do
        {:ok, item} ->
          {:ok,
           %{
             source: "maraithon_memory",
             forgotten: true,
             memory: MemoryHelpers.serialize_item(item)
           }}

        {:error, reason} ->
          {:error, normalize_error(reason)}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp memory_ref(args) do
    case optional_string(args, "memory_id") || optional_string(args, "query") do
      nil -> {:error, "memory_id or query is required"}
      value -> {:ok, value}
    end
  end

  defp normalize_error(:memory_not_found), do: "memory_not_found"
  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: safe_error(reason)
end
