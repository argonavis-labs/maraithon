defmodule Maraithon.PeopleNetwork.Detail do
  @moduledoc "Bounded source evidence and open work for one projected person."
  import Ecto.Query
  alias Maraithon.Crm.{Observation, Person, PersonLink}
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.PeopleNetwork
  alias Maraithon.Repo
  alias Maraithon.Todos.Todo

  def fetch(user_id, node_id, opts \\ []) do
    with {:ok, profile} <- PeopleNetwork.person(user_id, node_id, opts) do
      person_id = profile["person_id"]
      person = if person_id, do: Repo.get_by(Person, id: person_id, user_id: user_id)
      history = hydrate_history(user_id, profile["history"] || [])

      {:ok,
       profile
       |> Map.put("history", history)
       |> Map.put("notes", if(person, do: person.notes))
       |> Map.put("todos", todos(user_id, person_id))}
    end
  end

  defp todos(_user_id, nil), do: []

  defp todos(user_id, person_id) do
    links =
      from l in PersonLink,
        where: l.user_id == ^user_id and l.person_id == ^person_id and l.resource_type == "todo",
        select: l.resource_id

    Repo.all(
      from t in Todo,
        where: t.user_id == ^user_id and t.status in ["open", "snoozed"],
        where:
          t.counterparty_person_id == ^person_id or fragment("?::text", t.id) in subquery(links),
        order_by: [asc_nulls_last: t.due_at, desc: t.inserted_at],
        limit: 12,
        select: %{id: t.id, title: t.title, next_action: t.next_action, due_at: t.due_at}
    )
  end

  defp hydrate_history(user_id, history) do
    observation_ids = ids_for(history, "observation")
    message_ids = ids_for(history, "message")

    observations =
      Repo.all(
        from o in Observation,
          where: o.user_id == ^user_id and o.id in ^observation_ids,
          select: {o.id, fragment("left(?, 700)", o.excerpt)}
      )
      |> Map.new()

    messages =
      Repo.all(
        from m in LocalMessage,
          where:
            m.user_id == ^user_id and m.id in ^message_ids and
              m.encrypted_with_device_key == false,
          select: {m.id, fragment("left(?, 700)", m.text)}
      )
      |> Map.new()

    Enum.map(history, fn event ->
      excerpt =
        case event["type"] do
          "message" -> Map.get(messages, event["id"])
          "observation" -> Map.get(observations, event["id"])
          _ -> nil
        end

      Map.put(event, "excerpt", excerpt)
    end)
  end

  defp ids_for(history, type) do
    history |> Enum.filter(&(&1["type"] == type)) |> Enum.map(& &1["id"]) |> Enum.take(8)
  end
end
