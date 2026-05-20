defmodule Maraithon.Crm.Serializer do
  @moduledoc """
  Compact CRM person renderers for chat surfaces.
  """

  alias Maraithon.Crm
  alias Maraithon.Crm.{Person, PersonLink}
  alias Maraithon.Todos.Todo

  def telegram_card(person_or_context, opts \\ [])

  def telegram_card(%Person{} = person, opts) do
    context =
      case person.user_id do
        user_id when is_binary(user_id) ->
          case Crm.relationship_context(user_id, %{
                 "person_id" => person.id,
                 "link_limit" => Keyword.get(opts, :link_limit, 5)
               }) do
            {:ok, context} -> context
            {:error, _reason} -> %{person: person, links: [], todos: [], open_todo_count: 0}
          end

        _other ->
          %{person: person, links: [], todos: [], open_todo_count: 0}
      end

    telegram_card(context, opts)
  end

  def telegram_card(%{person: %Person{} = person} = context, _opts) do
    links = Map.get(context, :links, [])
    todos = Map.get(context, :todos, [])
    open_todo_count = Map.get(context, :open_todo_count) || count_open_todos(todos)

    [
      "*#{person.display_name}*",
      labeled("Relationship", person.relationship),
      labeled("Preferred", preferred_channel(person, links)),
      labeled("Last touch", format_date(person.last_interaction_at)),
      "Open loops: #{open_todo_count}",
      labeled("Sources", source_summary(links))
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  def telegram_card(_value, _opts), do: ""

  defp preferred_channel(%Person{preferred_communication_method: preferred}, _links)
       when is_binary(preferred) and preferred != "" do
    preferred
  end

  defp preferred_channel(_person, links) do
    links
    |> Enum.map(&link_source/1)
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_source, count} -> count end, fn -> nil end)
    |> case do
      {source, _count} -> source
      nil -> nil
    end
  end

  defp source_summary(links) do
    links
    |> Enum.map(&link_source/1)
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {source, count} -> {-count, source} end)
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {source, count} -> "#{source} (#{count})" end)
  end

  defp link_source(%PersonLink{} = link) do
    link.source_system || link.resource_source || link.resource_type
  end

  defp link_source(_link), do: nil

  defp count_open_todos(todos) do
    Enum.count(todos, fn
      %Todo{status: status} -> status in ["open", "snoozed"]
      _other -> false
    end)
  end

  defp labeled(_label, nil), do: nil
  defp labeled(_label, ""), do: nil
  defp labeled(label, value), do: "#{label}: #{value}"

  defp format_date(nil), do: nil

  defp format_date(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d")
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
