defmodule MaraithonWeb.MobilePeopleController do
  use MaraithonWeb, :controller

  alias Maraithon.Crm
  alias Maraithon.Crm.Person
  alias MaraithonWeb.MobileJSON
  alias MaraithonWeb.MobileParams

  @person_param_keys ~w(
    first_name last_name display_name contact_details contacts email emails phone phone_number
    phones slack_id slack_ids telegram_id telegram_ids preferred_communication_method
    relationship communication_frequency notes metadata status last_interaction_at last_contacted_at
  )

  def index(conn, params) do
    user_id = conn.assigns.current_user.id
    limit = limit(params)
    offset = offset(params)

    people =
      Crm.list_people(user_id,
        limit: limit,
        offset: offset,
        query: text_param(params, "q"),
        status: text_param(params, "status") || "active"
      )

    json(conn, %{
      people: Enum.map(people, &MobileJSON.person/1),
      pagination: %{
        limit: limit,
        offset: offset,
        count: length(people),
        next_offset: next_offset(people, limit, offset)
      }
    })
  end

  def reconnect(conn, params) do
    user_id = conn.assigns.current_user.id

    suggestions = Crm.reconnect_suggestions(user_id, limit: reconnect_limit(params))

    json(conn, %{
      suggestions: Enum.map(suggestions, &MobileJSON.reconnect_suggestion/1)
    })
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

  def show(conn, %{"id" => person_id}) do
    user_id = conn.assigns.current_user.id

    case Crm.get_person_for_user(user_id, person_id) do
      %Person{} = person ->
        json(conn, %{person: MobileJSON.person(person)})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(MobileJSON.error(:not_found))
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
        |> json(MobileJSON.error(:not_found))
    end
  end

  def delete(conn, %{"id" => person_id}) do
    user_id = conn.assigns.current_user.id

    case Crm.delete_person(user_id, person_id) do
      {:ok, _person} ->
        json(conn, %{ok: true, deleted_person_id: person_id})

      {:error, :person_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(MobileJSON.error(:not_found))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(reason))
    end
  end

  def merge(conn, %{"id" => surviving_id} = params) do
    user_id = conn.assigns.current_user.id

    case merge_person_id(params) do
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(:missing_duplicate))

      merged_id ->
        case Crm.merge_people(user_id, surviving_id, merged_id, merge_attrs(params)) do
          {:ok, result} ->
            json(conn, %{
              merge: %{
                surviving_person: MobileJSON.person(result.surviving_person),
                merged_person: MobileJSON.person(result.merged_person),
                repointed_link_count: result.repointed_link_count,
                collapsed_link_count: result.collapsed_link_count
              }
            })

          {:error, :person_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(MobileJSON.error(:not_found))

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(MobileJSON.error(reason))
        end
    end
  end

  defp person_params(%{"person" => person}) when is_map(person) do
    person
    |> MobileParams.sanitize(@person_param_keys)
    |> sanitize_person_metadata()
  end

  defp person_params(params) do
    params
    |> MobileParams.sanitize(@person_param_keys)
    |> sanitize_person_metadata()
  end

  defp sanitize_person_metadata(%{"metadata" => metadata} = params) do
    Map.put(params, "metadata", MobileJSON.public_person_metadata(metadata))
  end

  defp sanitize_person_metadata(params), do: params

  defp merge_person_id(%{"merge" => %{} = merge_params}), do: merge_person_id(merge_params)

  defp merge_person_id(params) do
    text_param(params, "merged_person_id") ||
      text_param(params, "duplicate_person_id") ||
      text_param(params, "person_id")
  end

  defp merge_attrs(%{"merge" => %{} = merge_params}), do: merge_attrs(merge_params)

  defp merge_attrs(params) do
    %{
      "performed_by" => "mobile",
      "evidence" => text_param(params, "evidence") || "Merged from mobile.",
      "model_rationale" =>
        text_param(params, "model_rationale") ||
          text_param(params, "rationale") ||
          "Kept one person record and merged the duplicate from mobile."
    }
  end

  defp limit(params) do
    case Integer.parse(to_string(Map.get(params, "limit", "200"))) do
      {value, ""} -> value |> max(1) |> min(500)
      _ -> 200
    end
  end

  defp offset(params) do
    case Integer.parse(to_string(Map.get(params, "offset", "0"))) do
      {value, ""} -> max(value, 0)
      _ -> 0
    end
  end

  defp reconnect_limit(params) do
    case Integer.parse(to_string(Map.get(params, "limit", "12"))) do
      {value, ""} -> value |> max(1) |> min(50)
      _ -> 12
    end
  end

  defp next_offset(people, limit, offset) do
    if length(people) == limit, do: offset + limit, else: nil
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
