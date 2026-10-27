defmodule MaraithonWeb.PeopleNetworkController do
  use MaraithonWeb, :controller
  alias Maraithon.PeopleNetwork

  def index(conn, params) do
    payload =
      PeopleNetwork.view(conn.assigns.current_user.id,
        days: params["days"],
        query: params["q"],
        focus: params["focus"]
      )

    conn |> put_resp_header("cache-control", "private, max-age=30") |> json(payload)
  end

  def show(conn, %{"node_id" => id} = params) do
    case PeopleNetwork.Detail.fetch(conn.assigns.current_user.id, id, days: params["days"]) do
      {:ok, profile} -> json(conn, %{person: profile})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end
end
