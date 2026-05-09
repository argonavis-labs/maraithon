defmodule Maraithon.Tools.TodoHelpers do
  @moduledoc false

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Todos.Todo

  def list_opts(args, default_limit \\ 50) when is_map(args) do
    limit =
      args
      |> optional_integer("limit")
      |> case do
        nil -> default_limit
        value -> value |> max(1) |> min(100)
      end

    []
    |> Keyword.put(:limit, limit)
    |> maybe_put(:source, optional_string(args, "source"))
    |> maybe_put(:source_account_id, optional_integer(args, "source_account_id"))
    |> maybe_put(:kind, optional_string(args, "kind"))
    |> maybe_put(:attention_mode, optional_string(args, "attention_mode"))
    |> maybe_put(:owner_user_id, optional_string(args, "owner_user_id"))
    |> maybe_put(:due_before, optional_string(args, "due_before"))
    |> maybe_put(:due_after, optional_string(args, "due_after"))
    |> maybe_put(:query, optional_string(args, "query"))
  end

  def status_filter(args) when is_map(args) do
    case Map.get(args, "statuses") do
      statuses when is_list(statuses) -> statuses
      status when is_binary(status) -> [status]
      _other -> optional_csv(args, "status")
    end
  end

  def serialize_todo(%Todo{} = todo) do
    %{
      id: todo.id,
      source: todo.source,
      source_account_id: todo.source_account_id,
      source_account_label: todo.source_account_label,
      kind: todo.kind,
      attention_mode: todo.attention_mode,
      status: todo.status,
      title: todo.title,
      summary: todo.summary,
      next_action: todo.next_action,
      due_at: todo.due_at,
      notes: todo.notes,
      action_plan: todo.action_plan,
      action_draft: todo.action_draft || %{},
      owner_user_id: todo.owner_user_id,
      owner_label: todo.owner_label,
      priority: todo.priority,
      source_item_id: todo.source_item_id,
      source_occurred_at: todo.source_occurred_at,
      metadata: todo.metadata || %{},
      updated_at: todo.updated_at
    }
  end
end
