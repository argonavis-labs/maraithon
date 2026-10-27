defmodule MaraithonWeb.LifeContextController do
  use MaraithonWeb, :controller
  alias Maraithon.LifeContext
  alias Maraithon.Crm.Confirmations

  def index(conn, _params),
    do: json(conn, %{notes: Enum.map(LifeContext.list(user_id(conn)), &LifeContext.serialize/1)})

  def create(conn, params) do
    case LifeContext.capture(user_id(conn), params) do
      {:ok, note} -> conn |> put_status(:accepted) |> json(%{note: LifeContext.serialize(note)})
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, %{"id" => id}) do
    case LifeContext.get(user_id(conn), id) do
      nil -> error(conn, :not_found)
      note -> json(conn, %{note: LifeContext.serialize(note)})
    end
  end

  def confirm(conn, %{"id" => id} = params),
    do: note_result(conn, LifeContext.confirm(user_id(conn), id, params))

  def retry(conn, %{"id" => id}), do: note_result(conn, LifeContext.retry(user_id(conn), id))
  def archive(conn, %{"id" => id}), do: note_result(conn, LifeContext.archive(user_id(conn), id))

  def person(conn, params) do
    case Confirmations.review(user_id(conn), params) do
      {:ok, person} -> json(conn, %{person: person})
      {:error, reason} -> error(conn, reason)
    end
  end

  def confirm_person(conn, params) do
    case Confirmations.confirm(user_id(conn), params) do
      {:ok, person} -> json(conn, %{person: person})
      {:error, reason} -> error(conn, reason)
    end
  end

  defp note_result(conn, {:ok, note}), do: json(conn, %{note: LifeContext.serialize(note)})
  defp note_result(conn, {:error, reason}), do: error(conn, reason)
  defp user_id(conn), do: conn.assigns.current_user.id

  defp error(conn, :not_found), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})

  defp error(conn, reason) do
    message =
      case reason do
        :ambiguous_contacts ->
          "These contact details match different people. Open the correct person from People."

        :request_conflict ->
          "This note changed. Save it as a new note."

        :not_ready ->
          "Wait for the interpretation before confirming it."

        :invalid_contact_details ->
          "Check the email addresses and phone numbers, then try again."

        _ ->
          "Check the details and try again."
      end

    conn |> put_status(:unprocessable_entity) |> json(%{error: message})
  end
end
