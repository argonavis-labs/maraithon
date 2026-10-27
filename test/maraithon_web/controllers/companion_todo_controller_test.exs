defmodule MaraithonWeb.CompanionTodoControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Companion.Devices
  alias Maraithon.Todos

  defp pair_device(email) do
    {:ok, user} = Accounts.get_or_create_user_by_email(email)

    {:ok, %{token: token}} =
      Devices.register(user.id, Ecto.UUID.generate(), device_name: "Todo test Mac")

    %{user: user, token: token}
  end

  defp put_device_token(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp create_todo(user, title) do
    {:ok, [todo]} =
      Todos.upsert_many(user.id, [
        %{
          "source" => "companion_test",
          "title" => title,
          "summary" => "Verify the paired Mac Todo contract.",
          "next_action" => "Complete this Todo from the Mac.",
          "priority" => 90,
          "status" => "open"
        }
      ])

    todo
  end

  test "paired device lists only its user's Todos", %{conn: conn} do
    %{user: user, token: token} =
      pair_device("companion-todos-#{System.unique_integer([:positive])}@example.com")

    %{user: other_user} =
      pair_device("companion-todos-other-#{System.unique_integer([:positive])}@example.com")

    todo = create_todo(user, "Finish the companion Todo surface")
    _other_todo = create_todo(other_user, "This Todo belongs to another user")

    conn =
      conn
      |> put_device_token(token)
      |> get("/api/v1/companion/todos?status=all&include_cards=false")

    assert %{
             "todos" => [%{"id" => todo_id, "status" => "open"}],
             "pagination" => %{"count" => 1}
           } = json_response(conn, 200)

    assert todo_id == todo.id
  end

  test "paired device completes and reopens its Todo", %{conn: conn} do
    %{user: user, token: token} =
      pair_device("companion-todo-actions-#{System.unique_integer([:positive])}@example.com")

    todo = create_todo(user, "Complete this Todo on the Mac")

    conn =
      conn
      |> put_device_token(token)
      |> post("/api/v1/companion/todos/#{todo.id}/actions/done")

    assert %{"action" => "done", "todo" => %{"id" => todo_id, "status" => "done"}} =
             json_response(conn, 200)

    assert todo_id == todo.id
    assert Todos.get_for_user(user.id, todo.id).status == "done"

    conn =
      build_conn()
      |> put_device_token(token)
      |> post("/api/v1/companion/todos/#{todo.id}/actions/reopen")

    assert %{
             "action" => "reopen",
             "todo" => %{"id" => ^todo_id, "status" => "open"}
           } = json_response(conn, 200)

    assert Todos.get_for_user(user.id, todo.id).status == "open"
  end

  test "paired device cannot read or change another user's Todo", %{conn: conn} do
    %{token: token} =
      pair_device("companion-todo-owner-#{System.unique_integer([:positive])}@example.com")

    %{user: other_user} =
      pair_device("companion-todo-owner-other-#{System.unique_integer([:positive])}@example.com")

    other_todo = create_todo(other_user, "Private Todo")

    conn =
      conn
      |> put_device_token(token)
      |> get("/api/v1/companion/todos/#{other_todo.id}")

    assert %{"error" => "not_found"} = json_response(conn, 404)

    conn =
      build_conn()
      |> put_device_token(token)
      |> post("/api/v1/companion/todos/#{other_todo.id}/actions/done")

    assert %{"error" => "not_found"} = json_response(conn, 404)
    assert Todos.get_for_user(other_user.id, other_todo.id).status == "open"
  end

  test "Todo routes reject missing and revoked device tokens", %{conn: conn} do
    conn = get(conn, "/api/v1/companion/todos")
    assert %{"error" => "unauthorized"} = json_response(conn, 401)

    %{user: user, token: token} =
      pair_device("companion-todo-revoked-#{System.unique_integer([:positive])}@example.com")

    [device] = Devices.list_for_user(user.id)
    {:ok, _device} = Devices.revoke(user.id, device.id)

    conn =
      build_conn()
      |> put_device_token(token)
      |> get("/api/v1/companion/todos")

    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end
end
