defmodule Maraithon.Tools.ListMemories do
  @moduledoc """
  List durable deep memory items for a user.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Memory
  alias Maraithon.Tools.MemoryHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      memories =
        user_id
        |> Memory.list_items(MemoryHelpers.list_opts(args))
        |> Enum.map(&MemoryHelpers.serialize_item/1)

      {:ok,
       %{
         source: "maraithon_memory",
         count: length(memories),
         memories: memories
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
