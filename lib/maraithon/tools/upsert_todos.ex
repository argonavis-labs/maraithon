defmodule Maraithon.Tools.UpsertTodos do
  @moduledoc """
  Built-in model-backed todo ingestion tool for MCP and runtime tool callers.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.OpenLoops
  alias Maraithon.Tools.TodoHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      todos = Map.get(args, "todos", [])

      cond do
        not is_list(todos) ->
          {:error, "todos is required"}

        true ->
          candidates =
            todos
            |> Enum.filter(&is_map/1)
            |> Enum.map(&mark_explicit_user_request(&1, "mcp"))

          case OpenLoops.ingest_todos(user_id, candidates, source: "mcp") do
            {:ok, result} ->
              {:ok,
               %{
                 source: "maraithon_todos",
                 count: length(result.todos),
                 skipped_count: result.skipped_count,
                 summary: result.summary,
                 decisions: result.decisions,
                 enrichment: result.enrichment,
                 todos: Enum.map(result.todos, &TodoHelpers.serialize_todo/1)
               }}

            {:error, reason} ->
              {:error, normalize_error(reason)}
          end
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp mark_explicit_user_request(todo, source) do
    todo = Map.new(todo, fn {key, value} -> {to_string(key), value} end)

    metadata =
      todo
      |> Map.get("metadata", %{})
      |> then(fn value -> if is_map(value), do: value, else: %{} end)

    todo
    |> Map.put("source", source)
    |> Map.put("metadata", Map.put(metadata, "explicit_user_request", true))
  end

  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: safe_error(reason)
end
