defmodule MaraithonWeb.McpControllerTest do
  use MaraithonWeb.ConnCase, async: false

  alias Maraithon.Accounts

  setup do
    previous_api_auth = Application.get_env(:maraithon, :api_auth)
    Application.put_env(:maraithon, :api_auth, bearer_token: "")

    on_exit(fn ->
      case previous_api_auth do
        nil -> Application.delete_env(:maraithon, :api_auth)
        value -> Application.put_env(:maraithon, :api_auth, value)
      end
    end)

    :ok
  end

  test "lists built-in todo tools over MCP", %{conn: conn} do
    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      })

    response = json_response(conn, 200)

    names =
      response
      |> get_in(["result", "tools"])
      |> Enum.map(& &1["name"])

    assert "list_todos" in names
    assert "upsert_todos" in names
    assert "resolve_todo" in names
    assert "get_open_loops" in names
    assert "list_people" in names
    assert "get_person" in names
    assert "upsert_person" in names
    assert "delete_person" in names
    assert "link_person_data" in names
    assert "get_relationship_context" in names
    assert "list_memories" in names
    assert "write_memory" in names
    assert "recall_memory" in names
    assert "forget_memory" in names
    assert "record_memory_feedback" in names
  end

  test "calls the built-in todo list tool over MCP", %{conn: conn} do
    user_id = "mcp-todos-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "list_todos",
          "arguments" => %{"user_id" => user_id}
        }
      })

    response = json_response(conn, 200)

    assert get_in(response, ["result", "isError"]) == false
    assert get_in(response, ["result", "structuredContent", "source"]) == "maraithon_todos"
    assert get_in(response, ["result", "structuredContent", "count"]) == 0
  end

  test "calls the built-in open-loop snapshot tool over MCP", %{conn: conn} do
    user_id = "mcp-open-loops-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "tools/call",
        "params" => %{
          "name" => "get_open_loops",
          "arguments" => %{"user_id" => user_id, "limit" => 5}
        }
      })

    response = json_response(conn, 200)

    assert get_in(response, ["result", "isError"]) == false
    assert get_in(response, ["result", "structuredContent", "source"]) == "maraithon_open_loops"
    assert get_in(response, ["result", "structuredContent", "totals", "open_todos"]) == 0
  end

  test "calls the built-in CRM list tool over MCP", %{conn: conn} do
    user_id = "mcp-people-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "list_people",
          "arguments" => %{"user_id" => user_id}
        }
      })

    response = json_response(conn, 200)

    assert get_in(response, ["result", "isError"]) == false
    assert get_in(response, ["result", "structuredContent", "source"]) == "maraithon_crm"
    assert get_in(response, ["result", "structuredContent", "count"]) == 0
  end

  test "calls the built-in memory list tool over MCP", %{conn: conn} do
    user_id = "mcp-memory-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "list_memories",
          "arguments" => %{"user_id" => user_id}
        }
      })

    response = json_response(conn, 200)

    assert get_in(response, ["result", "isError"]) == false
    assert get_in(response, ["result", "structuredContent", "source"]) == "maraithon_memory"
    assert get_in(response, ["result", "structuredContent", "count"]) == 0
  end
end
