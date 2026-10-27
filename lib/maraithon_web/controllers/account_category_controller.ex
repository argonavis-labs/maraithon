defmodule MaraithonWeb.AccountCategoryController do
  use MaraithonWeb, :controller
  alias Maraithon.AccountCategories

  def index(conn, _params),
    do: json(conn, %{accounts: AccountCategories.list(conn.assigns.current_user.id)})

  def update(conn, %{"id" => id, "category" => category}) do
    with {id, ""} <- Integer.parse(to_string(id)),
         {:ok, _} <- AccountCategories.update(conn.assigns.current_user.id, id, category) do
      index(conn, %{})
    else
      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Account category could not be saved."})
    end
  end

  def update(conn, _),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "Choose an account and category."})
end
