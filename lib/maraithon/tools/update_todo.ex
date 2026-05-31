defmodule Maraithon.Tools.UpdateTodo do
  @moduledoc """
  Patches one built-in todo by id without invoking model-level ingestion.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Todos
  alias Maraithon.Tools.TodoHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, todo_id} <- required_string(args, "todo_id") do
      case Todos.update_for_user(user_id, todo_id, args) do
        {:ok, todo} ->
          {:ok,
           %{
             source: "maraithon_todos",
             todo: TodoHelpers.serialize_todo(todo)
           }}

        {:error, :not_found} ->
          {:error, "todo_not_found"}

        {:error, :empty_update} ->
          {:error, "at least one update field is required"}

        {:error, reason} ->
          {:error, normalize_error(reason)}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: safe_error(reason)
end
