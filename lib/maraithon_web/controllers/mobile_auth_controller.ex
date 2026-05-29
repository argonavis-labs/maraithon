defmodule MaraithonWeb.MobileAuthController do
  use MaraithonWeb, :controller

  alias Maraithon.Accounts
  alias Maraithon.Accounts.MagicLinkSender
  alias MaraithonWeb.MobileJSON

  @magic_link_ttl_seconds 15 * 60

  def create_magic_link(conn, params) do
    email = extract_email(params)

    case Accounts.request_magic_code(email, request_metadata(conn)) do
      {:ok, %{user: user, code: code}} ->
        case MagicLinkSender.deliver_code(user.email, code) do
          :ok ->
            delivery = %{
              email: user.email,
              expires_in_seconds: @magic_link_ttl_seconds,
              delivery: "email_code"
            }

            json(conn, %{
              magic_code: delivery,
              magic_link: delivery
            })

          {:error, reason} ->
            conn
            |> put_status(:bad_gateway)
            |> json(MobileJSON.error(reason))
        end

      {:error, :invalid_email} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(:invalid_email))

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(MobileJSON.error(reason))
    end
  end

  def consume_magic_code(conn, params) do
    code = extract_code(params)

    case Accounts.consume_magic_code(code, request_metadata(conn)) do
      {:ok, %{user: user, token: session_token, session: session}} ->
        json(conn, %{
          session_token: session_token,
          user: MobileJSON.user(user, session)
        })

      {:error, :invalid_or_expired_code} ->
        conn
        |> put_status(:unauthorized)
        |> json(MobileJSON.error(:invalid_or_expired_code))

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(MobileJSON.error(reason))
    end
  end

  def consume_magic_link(conn, %{"token" => token}) do
    case Accounts.consume_magic_link(token, request_metadata(conn)) do
      {:ok, %{user: user, token: session_token, session: session}} ->
        json(conn, %{
          session_token: session_token,
          user: MobileJSON.user(user, session)
        })

      {:error, :invalid_or_expired_link} ->
        conn
        |> put_status(:unauthorized)
        |> json(MobileJSON.error(:invalid_or_expired_link))

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(MobileJSON.error(reason))
    end
  end

  def me(conn, _params) do
    json(conn, %{
      user: MobileJSON.user(conn.assigns.current_user, conn.assigns.current_user_session)
    })
  end

  def delete(conn, _params) do
    _ = Accounts.revoke_session(conn.assigns.current_user_session_token)
    json(conn, %{ok: true})
  end

  defp extract_email(%{"magic_link" => %{"email" => email}}), do: email
  defp extract_email(%{"magic_code" => %{"email" => email}}), do: email
  defp extract_email(%{"email" => email}), do: email
  defp extract_email(_params), do: ""

  defp extract_code(%{"magic_code" => %{"code" => code}}), do: code
  defp extract_code(%{"code" => code}), do: code
  defp extract_code(_params), do: ""

  defp request_metadata(conn) do
    [
      ip: ip_to_string(conn.remote_ip),
      user_agent: List.first(get_req_header(conn, "user-agent"))
    ]
  end

  defp ip_to_string(nil), do: nil
  defp ip_to_string(ip), do: to_string(:inet.ntoa(ip))
end
