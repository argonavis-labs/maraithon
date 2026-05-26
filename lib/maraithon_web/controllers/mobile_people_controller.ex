defmodule MaraithonWeb.MobilePeopleController do
  use MaraithonWeb, :controller

  alias Maraithon.Crm
  alias Maraithon.Crm.Person
  alias MaraithonWeb.MobileJSON

  def index(conn, params) do
    user_id = conn.assigns.current_user.id

    people =
      Crm.list_people(user_id,
        limit: limit(params),
        query: text_param(params, "q"),
        status: text_param(params, "status") || "active"
      )

    json(conn, %{people: Enum.map(people, &MobileJSON.person/1)})
  end

  def create(conn, params) do
    user_id = conn.assigns.current_user.id

    case Crm.create_person(user_id, person_params(params)) do
      {:ok, person} ->
        conn
        |> put_status(:created)
        |> json(%{person: MobileJSON.person(person)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(reason))
    end
  end

  def update(conn, %{"id" => person_id} = params) do
    user_id = conn.assigns.current_user.id

    case Crm.get_person_for_user(user_id, person_id) do
      %Person{} = person ->
        case Crm.update_person(person, person_params(params)) do
          {:ok, person} ->
            json(conn, %{person: MobileJSON.person(person)})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(MobileJSON.error(reason))
        end

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end

  defp person_params(%{"person" => person}) when is_map(person), do: person
  defp person_params(params), do: Map.drop(params, ["id"])

  defp limit(params) do
    case Integer.parse(to_string(Map.get(params, "limit", "200"))) do
      {value, ""} -> value |> max(1) |> min(500)
      _ -> 200
    end
  end

  defp text_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end
end
