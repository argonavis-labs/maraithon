defmodule Maraithon.Tools.ListTodos do
  @moduledoc """
  Built-in todo list tool for MCP and runtime tool callers.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Todos
  alias Maraithon.Tools.TodoHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      opts = TodoHelpers.list_opts(args)
      statuses = TodoHelpers.status_filter(args)

      todos =
        if statuses == [] do
          Todos.list_open_for_user(user_id, opts)
        else
          Todos.list_for_user(user_id, Keyword.put(opts, :statuses, statuses))
        end

      {:ok,
       %{
         source: "maraithon_todos",
         count: length(todos),
         todos: Enum.map(todos, &TodoHelpers.serialize_todo/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
