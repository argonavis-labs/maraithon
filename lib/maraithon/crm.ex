defmodule Maraithon.Crm do
  @moduledoc """
  Context for user-scoped CRM people and their links to Maraithon data.
  """

  import Ecto.Query

  alias Maraithon.Crm.{Person, PersonLink}
  alias Maraithon.Repo
  alias Maraithon.Todos

  @default_people_limit 25
  @default_link_limit 25

  def list_people(user_id, opts \\ [])

  def list_people(user_id, opts) when is_binary(user_id) do
    limit = opts |> Keyword.get(:limit, @default_people_limit) |> clamp_limit(1, 100)
    query_text = normalize_string(Keyword.get(opts, :query))
    relationship = normalize_string(Keyword.get(opts, :relationship))
    method = normalize_string(Keyword.get(opts, :preferred_communication_method))
    frequency = normalize_string(Keyword.get(opts, :communication_frequency))
    contact_kind = normalize_string(Keyword.get(opts, :contact_kind))
    contact_value = normalize_string(Keyword.get(opts, :contact_value))

    Person
    |> where([person], person.user_id == ^user_id)
    |> maybe_filter_people_query(query_text)
    |> maybe_filter_text(:relationship, relationship)
    |> maybe_filter_text(:preferred_communication_method, method)
    |> maybe_filter_text(:communication_frequency, frequency)
    |> maybe_filter_contact(contact_kind, contact_value)
    |> order_by([person], asc: fragment("lower(?)", person.display_name), desc: person.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_people(_user_id, _opts), do: []

  def get_person_for_user(user_id, person_id, opts \\ [])

  def get_person_for_user(user_id, person_id, opts)
      when is_binary(user_id) and is_binary(person_id) do
    preload = Keyword.get(opts, :preload, [])

    Person
    |> where([person], person.user_id == ^user_id and person.id == ^person_id)
    |> Repo.one()
    |> Repo.preload(preload)
  end

  def get_person_for_user(_user_id, _person_id, _opts), do: nil

  def create_person(user_id, attrs \\ %{})

  def create_person(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    %Person{user_id: user_id}
    |> Person.changeset(attrs)
    |> Repo.insert()
  end

  def create_person(_user_id, _attrs), do: {:error, :invalid_person_attrs}

  def update_person(%Person{} = person, attrs) when is_map(attrs) do
    person
    |> Person.changeset(attrs)
    |> Repo.update()
  end

  def update_person(_person, _attrs), do: {:error, :invalid_person_attrs}

  def upsert_person(user_id, attrs \\ %{})

  def upsert_person(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs = stringify_keys(attrs)

    case person_id_from_attrs(attrs) do
      person_id when is_binary(person_id) ->
        case get_person_for_user(user_id, person_id) do
          %Person{} = person -> update_person(person, attrs)
          nil -> {:error, :person_not_found}
        end

      nil ->
        case find_existing_person(user_id, attrs) do
          %Person{} = person -> update_person(person, attrs)
          nil -> create_person(user_id, attrs)
        end
    end
  end

  def upsert_person(_user_id, _attrs), do: {:error, :invalid_person_attrs}

  def delete_person(user_id, person_id)
      when is_binary(user_id) and is_binary(person_id) do
    case get_person_for_user(user_id, person_id) do
      %Person{} = person -> Repo.delete(person)
      nil -> {:error, :person_not_found}
    end
  end

  def delete_person(_user_id, _person_id), do: {:error, :person_not_found}

  def list_links_for_person(user_id, person_id, opts \\ [])

  def list_links_for_person(user_id, person_id, opts)
      when is_binary(user_id) and is_binary(person_id) do
    limit = opts |> Keyword.get(:limit, @default_link_limit) |> clamp_limit(1, 100)
    resource_type = normalize_string(Keyword.get(opts, :resource_type))

    PersonLink
    |> where([link], link.user_id == ^user_id and link.person_id == ^person_id)
    |> maybe_filter_link_resource_type(resource_type)
    |> order_by([link], desc: link.updated_at, desc: link.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_links_for_person(_user_id, _person_id, _opts), do: []

  def attach_resource(user_id, person_id, attrs \\ %{})

  def attach_resource(user_id, person_id, attrs)
      when is_binary(user_id) and is_binary(person_id) and is_map(attrs) do
    attrs = normalize_link_attrs(attrs)

    with %Person{} = _person <- get_person_for_user(user_id, person_id),
         {:ok, attrs} <- require_link_identity(attrs) do
      case get_existing_link(user_id, person_id, attrs) do
        %PersonLink{} = link ->
          link
          |> PersonLink.changeset(attrs)
          |> Repo.update()

        nil ->
          %PersonLink{user_id: user_id, person_id: person_id}
          |> PersonLink.changeset(attrs)
          |> Repo.insert()
      end
    else
      nil -> {:error, :person_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def attach_resource(_user_id, _person_id, _attrs), do: {:error, :invalid_person_link_attrs}

  def detach_resource(user_id, person_id, attrs \\ %{})

  def detach_resource(user_id, person_id, attrs)
      when is_binary(user_id) and is_binary(person_id) and is_map(attrs) do
    attrs = normalize_link_attrs(attrs)

    link =
      case normalize_string(Map.get(attrs, "link_id")) do
        link_id when is_binary(link_id) ->
          Repo.get_by(PersonLink, id: link_id, user_id: user_id, person_id: person_id)

        nil ->
          with {:ok, attrs} <- require_link_identity(attrs) do
            get_existing_link(user_id, person_id, attrs)
          else
            {:error, _reason} -> nil
          end
      end

    case link do
      %PersonLink{} = link -> Repo.delete(link)
      nil -> {:error, :person_link_not_found}
    end
  end

  def detach_resource(_user_id, _person_id, _attrs), do: {:error, :person_link_not_found}

  def relationship_context(user_id, attrs \\ %{})

  def relationship_context(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs = stringify_keys(attrs)
    link_limit = attrs |> Map.get("link_limit", Map.get(attrs, "limit")) |> clamp_limit(1, 100)

    case resolve_person(user_id, attrs) do
      %Person{} = person ->
        links = list_links_for_person(user_id, person.id, limit: link_limit)
        todos = linked_todos(user_id, links)

        {:ok,
         %{
           person: person,
           links: links,
           todos: todos,
           open_todo_count: Enum.count(todos, &(&1.status in ["open", "snoozed"]))
         }}

      nil ->
        {:error, :person_not_found}
    end
  end

  def relationship_context(_user_id, _attrs), do: {:error, :person_not_found}

  def summarize_for_prompt(user_id, limit \\ 12)

  def summarize_for_prompt(user_id, limit) when is_binary(user_id) do
    user_id
    |> list_people(limit: limit)
    |> Enum.map(&serialize_for_prompt/1)
  end

  def summarize_for_prompt(_user_id, _limit), do: []

  def serialize_for_prompt(%Person{} = person) do
    %{
      id: person.id,
      first_name: person.first_name,
      last_name: person.last_name,
      display_name: person.display_name,
      preferred_communication_method: person.preferred_communication_method,
      relationship: person.relationship,
      communication_frequency: person.communication_frequency,
      contact_details: compact_contact_details(person.contact_details || %{}),
      notes: person.notes
    }
  end

  defp resolve_person(user_id, attrs) do
    case person_id_from_attrs(attrs) do
      person_id when is_binary(person_id) ->
        get_person_for_user(user_id, person_id)

      nil ->
        contact_kind = normalize_string(Map.get(attrs, "contact_kind"))
        contact_value = normalize_string(Map.get(attrs, "contact_value"))
        query_text = normalize_string(Map.get(attrs, "query"))

        cond do
          is_binary(contact_value) ->
            list_people(user_id,
              contact_kind: contact_kind,
              contact_value: contact_value,
              limit: 1
            )
            |> List.first()

          is_binary(query_text) ->
            list_people(user_id, query: query_text, limit: 1)
            |> List.first()

          true ->
            nil
        end
    end
  end

  defp find_existing_person(user_id, attrs) do
    identifiers = contact_identifiers(attrs)
    display_name = normalize_display_name(attrs)

    cond do
      identifiers != [] ->
        contact_match =
          Enum.reduce(identifiers, dynamic(false), fn value, dynamic ->
            pattern = "%#{value}%"

            dynamic(
              [person],
              ^dynamic or fragment("?::text ILIKE ?", person.contact_details, ^pattern)
            )
          end)

        Person
        |> where([person], person.user_id == ^user_id)
        |> where(^contact_match)
        |> order_by([person], desc: person.updated_at)
        |> limit(1)
        |> Repo.one()

      is_binary(display_name) ->
        Person
        |> where([person], person.user_id == ^user_id)
        |> where(
          [person],
          fragment("lower(?)", person.display_name) == ^String.downcase(display_name)
        )
        |> limit(1)
        |> Repo.one()

      true ->
        nil
    end
  end

  defp contact_identifiers(attrs) do
    contact_details =
      %Person{}
      |> Person.changeset(
        Map.take(
          attrs,
          ~w(contact_details contacts email emails phone phone_number phones slack_id slack_ids telegram_id telegram_ids)
        )
      )
      |> Ecto.Changeset.get_change(:contact_details, %{})

    contact_details
    |> Map.take(~w(emails phones slack_ids telegram_ids))
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_display_name(attrs) do
    %Person{}
    |> Person.changeset(attrs)
    |> Ecto.Changeset.get_change(:display_name)
    |> normalize_string()
  end

  defp linked_todos(user_id, links) do
    todo_ids =
      links
      |> Enum.filter(&(&1.resource_type == "todo"))
      |> Enum.map(& &1.resource_id)
      |> Enum.uniq()

    Todos.list_by_ids(user_id, todo_ids)
  end

  defp get_existing_link(user_id, person_id, attrs) do
    Repo.get_by(PersonLink,
      user_id: user_id,
      person_id: person_id,
      resource_type: Map.get(attrs, "resource_type"),
      resource_id: Map.get(attrs, "resource_id")
    )
  end

  defp require_link_identity(attrs) do
    resource_type = normalize_string(Map.get(attrs, "resource_type"))
    resource_id = normalize_string(Map.get(attrs, "resource_id"))

    cond do
      is_nil(resource_type) ->
        {:error, :missing_resource_type}

      is_nil(resource_id) ->
        {:error, :missing_resource_id}

      true ->
        {:ok, Map.merge(attrs, %{"resource_type" => resource_type, "resource_id" => resource_id})}
    end
  end

  defp normalize_link_attrs(attrs) do
    attrs
    |> stringify_keys()
    |> case do
      %{"todo_id" => todo_id} = attrs when is_binary(todo_id) ->
        attrs
        |> Map.put_new("resource_type", "todo")
        |> Map.put_new("resource_id", String.trim(todo_id))

      attrs ->
        attrs
    end
  end

  defp person_id_from_attrs(attrs) do
    normalize_string(Map.get(attrs, "person_id") || Map.get(attrs, "id"))
  end

  defp maybe_filter_people_query(query, nil), do: query

  defp maybe_filter_people_query(query, query_text) do
    pattern = "%#{query_text}%"

    where(
      query,
      [person],
      ilike(person.first_name, ^pattern) or ilike(person.last_name, ^pattern) or
        ilike(person.display_name, ^pattern) or ilike(person.relationship, ^pattern) or
        ilike(person.notes, ^pattern) or
        fragment("?::text ILIKE ?", person.contact_details, ^pattern)
    )
  end

  defp maybe_filter_text(query, _field, nil), do: query

  defp maybe_filter_text(query, field, value) do
    where(query, [person], fragment("lower(?)", field(person, ^field)) == ^String.downcase(value))
  end

  defp maybe_filter_contact(query, _kind, nil), do: query

  defp maybe_filter_contact(query, nil, contact_value) do
    pattern = "%#{contact_value}%"
    where(query, [person], fragment("?::text ILIKE ?", person.contact_details, ^pattern))
  end

  defp maybe_filter_contact(query, kind, contact_value) do
    pattern = "%#{contact_value}%"

    where(
      query,
      [person],
      fragment(
        "(? -> ?)::text ILIKE ?",
        person.contact_details,
        ^normalize_contact_kind(kind),
        ^pattern
      ) or
        fragment("?::text ILIKE ?", person.contact_details, ^pattern)
    )
  end

  defp maybe_filter_link_resource_type(query, nil), do: query

  defp maybe_filter_link_resource_type(query, resource_type) do
    where(query, [link], link.resource_type == ^resource_type)
  end

  defp normalize_contact_kind("email"), do: "emails"
  defp normalize_contact_kind("phone"), do: "phones"
  defp normalize_contact_kind("phone_number"), do: "phones"
  defp normalize_contact_kind("slack"), do: "slack_ids"
  defp normalize_contact_kind("slack_id"), do: "slack_ids"
  defp normalize_contact_kind("telegram"), do: "telegram_ids"
  defp normalize_contact_kind("telegram_id"), do: "telegram_ids"
  defp normalize_contact_kind(kind), do: kind

  defp compact_contact_details(contact_details) when is_map(contact_details) do
    Map.take(contact_details, ~w(emails phones slack_ids telegram_ids))
  end

  defp compact_contact_details(_contact_details), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp clamp_limit(value, min_value, max_value) when is_integer(value) do
    value |> max(min_value) |> min(max_value)
  end

  defp clamp_limit(value, min_value, max_value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> clamp_limit(parsed, min_value, max_value)
      _ -> min_value
    end
  end

  defp clamp_limit(_value, min_value, _max_value), do: min_value
end
