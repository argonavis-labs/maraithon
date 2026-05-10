defmodule Maraithon.Tools do
  @moduledoc """
  Tool registry and execution.
  """

  alias Maraithon.{Capabilities, ToolPolicy}

  @doc """
  Execute a tool by name.
  """
  def execute(name, args, context \\ %{}) do
    args = if is_map(args), do: args, else: %{}

    context =
      context
      |> Map.new()
      |> Map.put_new(:surface, "internal")

    context =
      context
      |> Map.put_new(:confirmed?, read_surface(context) == "internal")
      |> Map.merge(%{
        tool_name: name,
        arguments: args,
        user_id: read_user_id(context, args),
        tool_metadata: policy_metadata_for(name)
      })

    ToolPolicy.enforce(context, fn ->
      case fetch(name) do
        {:ok, module} -> module.execute(args)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Resolve a tool module by name.
  """
  def fetch(name) when is_binary(name) do
    case Capabilities.tool_module(name) do
      nil -> {:error, "unknown_tool: #{name}"}
      module -> {:ok, module}
    end
  end

  def fetch(name), do: {:error, "unknown_tool: #{inspect(name)}"}

  @doc """
  List available tools.
  """
  def list do
    Capabilities.tool_names()
  end

  @doc """
  List tool descriptors for MCP and other discovery clients.
  """
  def describe(names \\ nil) do
    Capabilities.tool_descriptors(names)
  end

  @doc """
  Check if a tool exists.
  """
  def exists?(name) do
    Capabilities.tool_registered?(name)
  end

  @doc """
  Return policy metadata for a registered tool.
  """
  def policy_metadata_for(name) when is_binary(name) do
    Capabilities.policy_metadata_for(name)
  end

  def policy_metadata_for(_name), do: nil

  defp read_user_id(context, args) do
    Map.get(context, :user_id) || Map.get(context, "user_id") || Map.get(args, "user_id") ||
      Map.get(args, :user_id)
  end

  defp read_surface(context) do
    case Map.get(context, :surface, Map.get(context, "surface", "internal")) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> "internal"
    end
  end
end
