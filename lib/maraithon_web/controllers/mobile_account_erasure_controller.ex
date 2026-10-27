defmodule MaraithonWeb.MobileAccountErasureController do
  use MaraithonWeb, :controller

  alias Maraithon.PrivacyErasure
  alias MaraithonWeb.MobileJSON

  def create(conn, params) do
    user_id = conn.assigns.current_user.id
    opts = idempotency_opts(conn, params)

    case PrivacyErasure.request_user(user_id, opts) do
      {:ok, request} ->
        {:ok, status} = PrivacyErasure.status(request.id)

        conn
        |> put_status(:accepted)
        |> json(%{account_erasure: status})

      {:error, :user_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(MobileJSON.error(:not_found))

      {:error, :invalid_idempotency_key} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(:invalid_idempotency_key))

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(MobileJSON.error(reason))
    end
  end

  def show(conn, _params) do
    case PrivacyErasure.status_for_user(conn.assigns.current_user.id) do
      {:ok, status} ->
        json(conn, %{account_erasure: status})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(MobileJSON.error(reason))
    end
  end

  defp idempotency_opts(conn, params) do
    key =
      List.first(get_req_header(conn, "idempotency-key")) ||
        params["idempotency_key"] ||
        get_in(params, ["account_erasure", "idempotency_key"])

    if is_binary(key) and key != "", do: [idempotency_key: key], else: []
  end
end
