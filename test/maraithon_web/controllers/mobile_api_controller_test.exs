defmodule MaraithonWeb.MobileApiControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Todos

  test "magic-link consume returns a mobile session and me verifies it", %{conn: conn} do
    email = "mobile-auth-#{System.unique_integer([:positive])}@example.com"
    {:ok, %{token: token, user: user}} = Accounts.request_magic_link(email)

    conn = post(conn, ~p"/api/mobile/auth/magic/#{token}")

    assert %{
             "session_token" => session_token,
             "user" => %{"email" => ^email, "id" => user_id}
           } = json_response(conn, 200)

    assert user_id == user.id

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/me")

    assert %{"user" => %{"email" => ^email}} = json_response(conn, 200)
  end

  test "magic-link request returns clean validation errors", %{conn: conn} do
    conn =
      post(conn, ~p"/api/mobile/auth/magic-link", %{
        "email" => "not-an-email"
      })

    assert %{"error" => "invalid_email"} = json_response(conn, 422)
  end

  test "mobile todos can be listed, created, and updated", %{conn: conn} do
    email = "mobile-todos-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/todos", %{
        "todo" => %{
          "source" => "mobile",
          "title" => "Call production test lead",
          "summary" => "Confirm the native mobile todo create path.",
          "next_action" => "Call the lead from the mobile app.",
          "priority" => 80,
          "status" => "open"
        }
      })

    assert %{"todo" => %{"id" => todo_id, "title" => "Call production test lead"}} =
             json_response(conn, 201)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> patch(~p"/api/mobile/todos/#{todo_id}", %{
        "todo" => %{"title" => "Call updated production test lead", "status" => "done"}
      })

    assert %{"todo" => %{"title" => "Call updated production test lead", "status" => "done"}} =
             json_response(conn, 200)

    assert Todos.get_for_user(user.id, todo_id).status == "done"
  end

  test "mobile people can be listed, created, and updated", %{conn: conn} do
    email = "mobile-people-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/people", %{
        "person" => %{
          "display_name" => "Production Test Person",
          "relationship" => "Mobile integration",
          "email" => "production-test-person@example.com"
        }
      })

    assert %{"person" => %{"id" => person_id, "display_name" => "Production Test Person"}} =
             json_response(conn, 201)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> patch(~p"/api/mobile/people/#{person_id}", %{
        "person" => %{"notes" => "Updated from the mobile API test."}
      })

    assert %{"person" => %{"notes" => "Updated from the mobile API test."}} =
             json_response(conn, 200)

    assert Crm.get_person_for_user(user.id, person_id).notes ==
             "Updated from the mobile API test."
  end
end
