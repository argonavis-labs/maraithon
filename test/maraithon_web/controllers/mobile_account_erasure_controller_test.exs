defmodule MaraithonWeb.MobileAccountErasureControllerTest do
  use MaraithonWeb.ConnCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Accounts.User
  alias Maraithon.Privacy.ErasureRequest
  alias Maraithon.Repo

  test "DELETE session remains logout while POST account-erasure is irreversible erasure", %{
    conn: conn
  } do
    logout_user = user_fixture("logout")
    {:ok, %{token: logout_token}} = Accounts.create_session_for_user(logout_user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{logout_token}")
      |> delete(~p"/api/mobile/session")

    assert json_response(conn, 200) == %{"ok" => true}
    assert %User{privacy_erasure_requested_at: nil} = Accounts.get_user(logout_user.id)
    logout_user_id = logout_user.id

    refute Repo.exists?(
             from(request in ErasureRequest,
               where: request.subject_user_id == ^logout_user_id
             )
           )

    erase_user = user_fixture("erase")
    {:ok, %{token: erase_token}} = Accounts.create_session_for_user(erase_user)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{erase_token}")
      |> get(~p"/api/mobile/account-erasure")

    assert json_response(conn, 200) == %{"account_erasure" => nil}

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{erase_token}")
      |> put_req_header("idempotency-key", "ios-settings-1")
      |> post(~p"/api/mobile/account-erasure")

    assert %{
             "account_erasure" => %{
               "scope" => "user",
               "state" => "requested",
               "request_id" => request_id
             }
           } = json_response(conn, 202)

    response_body = response(conn, 202)
    refute response_body =~ erase_user.email
    refute response_body =~ erase_token
    refute response_body =~ "ios-settings-1"

    assert is_binary(request_id)
    assert Accounts.get_active_session(erase_token) == nil
    assert %User{privacy_erasure_requested_at: %DateTime{}} = Accounts.get_user(erase_user.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{erase_token}")
      |> get(~p"/api/mobile/account-erasure")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "browser-session JSON API is authenticated and returns content-free status", %{conn: conn} do
    user = user_fixture("web")
    {:ok, %{token: token}} = Accounts.create_session_for_user(user)

    conn =
      conn
      |> init_test_session(%{"user_session_token" => token})
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/account-erasure")

    assert json_response(conn, 200) == %{"account_erasure" => nil}

    conn =
      build_conn()
      |> init_test_session(%{"user_session_token" => token})
      |> put_private(:plug_skip_csrf_protection, true)
      |> put_req_header("accept", "application/json")
      |> put_req_header("idempotency-key", "web-settings-1")
      |> post(~p"/api/account-erasure")

    assert %{
             "account_erasure" => %{
               "scope" => "user",
               "state" => "requested",
               "receipt" => nil,
               "request_id" => request_id
             }
           } = json_response(conn, 202)

    response_body = response(conn, 202)
    refute response_body =~ user.email
    refute response_body =~ token
    refute response_body =~ "web-settings-1"

    assert is_binary(request_id)
    assert Accounts.get_active_session(token) == nil
  end

  defp user_fixture(prefix) do
    email = "mobile-erasure-#{prefix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    user
  end
end
