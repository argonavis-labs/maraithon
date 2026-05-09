defmodule Maraithon.Tools.GetOpenLoops do
  @moduledoc """
  Built-in open-loop snapshot tool for MCP and runtime tool callers.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.OpenLoops

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      {:ok, OpenLoops.snapshot(user_id, snapshot_opts(args))}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp snapshot_opts(args) do
    []
    |> maybe_put(:query, optional_string(args, "query"))
    |> maybe_put(:limit, optional_integer(args, "limit"))
  end
end
