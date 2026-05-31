defmodule Maraithon.Todos.PublicPayload do
  @moduledoc """
  Public todo projections for persisted chat payloads and client boundaries.

  Prompt payloads carry owner ids, source ids, rank profiles, quality scores,
  and runtime annotations. This module keeps linked todo data useful for
  clients while stripping fields that should not become product output.
  """

  alias Maraithon.Todos.{PublicMetadata, Todo, UserFacingCopy}

  @todo_fields [
    {"id", :id},
    {"source", :source},
    {"kind", :kind},
    {"attention_mode", :attention_mode},
    {"title", :title},
    {"summary", :summary},
    {"next_action", :next_action},
    {"due_at", :due_at},
    {"notes", :notes},
    {"action_plan", :action_plan},
    {"owner_label", :owner_label},
    {"priority", :priority},
    {"status", :status},
    {"snoozed_until", :snoozed_until},
    {"closed_at", :closed_at},
    {"source_account_label", :source_account_label},
    {"source_occurred_at", :source_occurred_at},
    {"inserted_at", :inserted_at},
    {"updated_at", :updated_at}
  ]

  def todo(%Todo{} = todo) do
    todo
    |> UserFacingCopy.polish_attrs()
    |> Map.from_struct()
    |> todo()
  end

  def todo(%{} = todo) do
    todo = UserFacingCopy.polish_attrs(todo)

    @todo_fields
    |> Enum.reduce(%{}, fn {key, atom_key}, acc ->
      todo
      |> read_value(key, atom_key)
      |> put_public_value(acc, key)
    end)
    |> Map.put("metadata", PublicMetadata.todo(read_value(todo, "metadata", :metadata) || %{}))
  end

  def todo(_todo), do: %{}

  defp put_public_value(nil, acc, _key), do: acc

  defp put_public_value(value, acc, key) when is_binary(value) do
    if String.trim(value) == "" do
      acc
    else
      Map.put(acc, key, value)
    end
  end

  defp put_public_value(value, acc, key), do: Map.put(acc, key, json_value(value))

  defp read_value(%Todo{} = todo, _key, atom_key), do: Map.get(todo, atom_key)

  defp read_value(map, key, atom_key) when is_map(map) do
    Map.get(map, key) || Map.get(map, atom_key)
  end

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_value(value), do: value
end
