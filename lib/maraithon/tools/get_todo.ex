defmodule Maraithon.Tools.GetTodo do
  @moduledoc """
  Reads one built-in todo by id, with a query fallback for MCP clients.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Todos
  alias Maraithon.Tools.TodoHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, todo} <- find_todo(user_id, args) do
      {:ok,
       %{
         source: "maraithon_todos",
         todo: TodoHelpers.serialize_todo(todo)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp find_todo(user_id, args) do
    case optional_string(args, "todo_id") || optional_string(args, "id") do
      todo_id when is_binary(todo_id) ->
        case Todos.get_for_user(user_id, todo_id) do
          nil -> {:error, "todo_not_found"}
          todo -> {:ok, todo}
        end

      nil ->
        find_by_query(user_id, args)
    end
  end

  defp find_by_query(user_id, args) do
    case optional_string(args, "query") do
      nil ->
        {:error, "todo_id or query is required"}

      query ->
        case Todos.list_for_user(user_id, limit: 1, query: query) do
          [todo | _rest] -> {:ok, todo}
          [] -> {:error, "todo_not_found"}
        end
    end
  end
end
