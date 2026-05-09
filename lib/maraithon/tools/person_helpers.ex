defmodule Maraithon.Tools.PersonHelpers do
  @moduledoc false

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Crm.Person
  alias Maraithon.Crm.PersonLink
  alias Maraithon.Tools.TodoHelpers
  alias Maraithon.Todos.Todo

  def people_list_opts(args, default_limit \\ 50) when is_map(args) do
    limit =
      args
      |> optional_integer("limit")
      |> case do
        nil -> default_limit
        value -> value |> max(1) |> min(100)
      end

    []
    |> Keyword.put(:limit, limit)
    |> maybe_put(:query, optional_string(args, "query"))
    |> maybe_put(:relationship, optional_string(args, "relationship"))
    |> maybe_put(:preferred_communication_method, preferred_method(args))
    |> maybe_put(:communication_frequency, optional_string(args, "communication_frequency"))
    |> maybe_put(:contact_kind, optional_string(args, "contact_kind"))
    |> maybe_put(:contact_value, optional_string(args, "contact_value"))
  end

  def link_list_opts(args, default_limit \\ 25) when is_map(args) do
    limit =
      args
      |> optional_integer("link_limit")
      |> case do
        nil -> optional_integer(args, "limit") || default_limit
        value -> value
      end
      |> max(1)
      |> min(100)

    []
    |> Keyword.put(:limit, limit)
    |> maybe_put(:resource_type, optional_string(args, "resource_type"))
  end

  def person_attrs(args) when is_map(args) do
    case Map.get(args, "person") do
      person when is_map(person) -> person
      _other -> Map.drop(args, ["user_id", "include_links", "include_relationship_context"])
    end
  end

  def link_attrs(args) when is_map(args) do
    case Map.get(args, "link") do
      link when is_map(link) -> link
      _other -> Map.drop(args, ["user_id", "person_id", "operation", "include_context"])
    end
  end

  def serialize_person(%Person{} = person) do
    %{
      id: person.id,
      first_name: person.first_name,
      last_name: person.last_name,
      display_name: person.display_name,
      contact_details: person.contact_details || %{},
      preferred_communication_method: person.preferred_communication_method,
      relationship: person.relationship,
      communication_frequency: person.communication_frequency,
      interaction_count: person.interaction_count,
      relationship_strength: person.relationship_strength,
      affinity_score: person.affinity_score,
      last_interaction_at: person.last_interaction_at,
      notes: person.notes,
      metadata: person.metadata || %{},
      inserted_at: person.inserted_at,
      updated_at: person.updated_at
    }
  end

  def serialize_link(%PersonLink{} = link) do
    %{
      id: link.id,
      person_id: link.person_id,
      resource_type: link.resource_type,
      resource_id: link.resource_id,
      resource_source: link.resource_source,
      title: link.title,
      summary: link.summary,
      relationship_note: link.relationship_note,
      metadata: link.metadata || %{},
      inserted_at: link.inserted_at,
      updated_at: link.updated_at
    }
  end

  def serialize_relationship_context(%{
        person: %Person{} = person,
        links: links,
        todos: todos,
        open_todo_count: open_todo_count
      }) do
    %{
      person: serialize_person(person),
      link_count: length(links),
      links: Enum.map(links, &serialize_link/1),
      todo_count: length(todos),
      open_todo_count: open_todo_count,
      todos: Enum.map(todos, &serialize_todo/1)
    }
  end

  defp serialize_todo(%Todo{} = todo), do: TodoHelpers.serialize_todo(todo)

  defp preferred_method(args) do
    optional_string(args, "preferred_communication_method") ||
      optional_string(args, "preferred_method") ||
      optional_string(args, "preferred_method_of_communication")
  end
end
