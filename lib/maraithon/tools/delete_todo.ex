defmodule Maraithon.Tools.DeleteTodo do
  @moduledoc """
  Dismisses one built-in todo as no longer relevant.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Todos
  alias Maraithon.Tools.TodoHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, todo_id} <- required_string(args, "todo_id") do
      resolution_note =
        optional_string(args, "resolution_note") || "Dismissed via MCP delete_todo."

      include_remaining = Map.get(args, "include_remaining") == true
      opts = TodoHelpers.list_opts(args, 5)

      case Todos.dismiss(user_id, todo_id, note: resolution_note) do
        {:ok, todo} ->
          remaining =
            if include_remaining do
              Todos.list_open_for_user(user_id, opts)
            else
              []
            end

          {:ok,
           %{
             source: "maraithon_todos",
             deleted: true,
             delete_mode: "dismiss_as_no_longer_relevant",
             todo: TodoHelpers.serialize_todo(todo),
             remaining_count: length(remaining),
             remaining_todos: Enum.map(remaining, &TodoHelpers.serialize_todo/1)
           }}

        {:error, :not_found} ->
          {:error, "todo_not_found"}

        {:error, reason} ->
          {:error, normalize_error(reason)}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: inspect(reason)
end
