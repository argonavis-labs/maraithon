defmodule MaraithonWeb.MobileTodoController do
  use MaraithonWeb, :controller

  alias Maraithon.Todos
  alias MaraithonWeb.MobileJSON

  def index(conn, params) do
    user_id = conn.assigns.current_user.id

    todos =
      Todos.list_for_user(user_id,
        limit: limit(params),
        statuses: status_filter(params),
        query: text_param(params, "q"),
        sort_by: text_param(params, "sort") || "updated",
        sort_dir: text_param(params, "dir") || "desc"
      )

    json(conn, %{todos: Enum.map(todos, &MobileJSON.todo/1)})
  end

  def create(conn, params) do
    user_id = conn.assigns.current_user.id
    attrs = todo_params(params)

    case Todos.upsert_many(user_id, [attrs]) do
      {:ok, [todo]} ->
        conn
        |> put_status(:created)
        |> json(%{todo: MobileJSON.todo(todo)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(reason))
    end
  end

  def update(conn, %{"id" => todo_id} = params) do
    user_id = conn.assigns.current_user.id

    case Todos.update_for_user(user_id, todo_id, todo_params(params)) do
      {:ok, todo} ->
        json(conn, %{todo: MobileJSON.todo(todo)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(reason))
    end
  end

  defp todo_params(%{"todo" => todo}) when is_map(todo), do: todo
  defp todo_params(params), do: Map.drop(params, ["id"])

  defp status_filter(%{"status" => "all"}), do: nil
  defp status_filter(%{"status" => status}) when is_binary(status), do: status
  defp status_filter(_params), do: nil

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
