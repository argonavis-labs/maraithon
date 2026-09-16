defmodule MaraithonWeb.DelegationController do
  use MaraithonWeb, :controller
  alias Maraithon.Delegations
  alias MaraithonWeb.DelegationCopy

  def settings(conn, params),
    do:
      json(conn, %{
        settings: MaraithonWeb.AssistantSettings.load(conn.assigns.current_user.id, params)
      })

  def update_identity(conn, params) do
    case MaraithonWeb.AssistantSettings.save_identity(conn.assigns.current_user.id, params) do
      {:ok, _} -> settings(conn, %{})
      error -> respond(conn, error)
    end
  end

  def update_preferences(conn, params) do
    case MaraithonWeb.AssistantSettings.save_preferences(conn.assigns.current_user.id, params) do
      {:ok, _} -> settings(conn, %{})
      error -> respond(conn, error)
    end
  end

  def preview(conn, %{"id" => todo_id, "async" => true} = params) do
    case Maraithon.Delegations.Preflight.preview(conn.assigns.current_user.id, todo_id, params) do
      {:ok, response} -> json(conn, response)
      error -> respond(conn, error)
    end
  end

  def preview(conn, %{"id" => todo_id} = params) do
    case Delegations.preview(conn.assigns.current_user.id, todo_id, params) do
      {:ok, scope} -> json(conn, %{scope: scope})
      error -> respond(conn, error)
    end
  end

  def create(conn, %{"id" => todo_id} = params),
    do: respond(conn, Delegations.delegate(conn.assigns.current_user.id, todo_id, params))

  def show(conn, %{"id" => id}),
    do: respond(conn, {:ok, Delegations.get(conn.assigns.current_user.id, id)})

  def history(conn, %{"id" => id} = params) do
    case Delegations.History.fetch(conn.assigns.current_user.id, id, params["before"]) do
      {:ok, history} ->
        json(conn, %{history: history})

      {:error, :not_found} ->
        respond(conn, {:ok, nil})

      {:error, :invalid_history_cursor} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Refresh the conversation history, then try again."})
    end
  end

  def control(conn, %{"id" => id, "action" => action} = params) do
    user_id = conn.assigns.current_user.id

    respond(conn, Delegations.control(user_id, id, action, params))
  end

  defp respond(conn, {:ok, nil}),
    do: conn |> put_status(:not_found) |> json(%{error: "Conversation not found."})

  defp respond(conn, {:ok, delegation}),
    do: json(conn, %{delegation: Delegations.summary(delegation)})

  defp respond(conn, {:error, {:conflict, current} = reason}),
    do:
      conn
      |> put_status(:conflict)
      |> json(%{error: DelegationCopy.error(reason), delegation: current})

  defp respond(conn, {:error, reason}),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: DelegationCopy.error(reason)})
end
