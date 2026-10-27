defmodule Maraithon.Tools.ResolveTodo do
  @moduledoc """
  Built-in todo resolution tool for MCP and runtime tool callers.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Todos
  alias Maraithon.Tools.TodoHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, todo_id} <- required_string(args, "todo_id") do
      resolution_note = optional_string(args, "resolution_note")
      include_remaining = Map.get(args, "include_remaining") == true
      opts = TodoHelpers.list_opts(args, 5)

      result =
        case optional_string(args, "status") || "done" do
          "done" ->
            Todos.mark_done(user_id, todo_id, note: resolution_note)

          "dismissed" ->
            Todos.dismiss(user_id, todo_id, note: resolution_note)

          "snoozed" ->
            with {:ok, snooze_until} <- snooze_until(args) do
              Todos.snooze(user_id, todo_id, snooze_until, note: resolution_note)
            end

          _other ->
            {:error, "unsupported_todo_status"}
        end

      with {:ok, todo} <- result do
        remaining =
          if include_remaining do
            Todos.list_open_for_user(user_id, opts)
          else
            []
          end

        {:ok,
         %{
           source: "maraithon_todos",
           todo: TodoHelpers.serialize_todo(todo),
           remaining_count: length(remaining),
           remaining_todos: Enum.map(remaining, &TodoHelpers.serialize_todo/1)
         }}
      else
        {:error, reason} -> {:error, normalize_error(reason)}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp snooze_until(args) do
    case Map.get(args, "snooze_until") do
      %DateTime{} = value ->
        {:ok, value}

      value when is_binary(value) ->
        case DateTime.from_iso8601(String.trim(value)) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          _other -> {:error, "invalid_snooze_until"}
        end

      _other ->
        {:error, "missing_snooze_until"}
    end
  end

  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: safe_error(reason)
end
