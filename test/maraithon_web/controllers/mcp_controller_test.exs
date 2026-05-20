defmodule MaraithonWeb.McpControllerTest do
  use MaraithonWeb.ConnCase, async: false

  alias Maraithon.Accounts

  setup do
    previous_api_auth = Application.get_env(:maraithon, :api_auth)

    previous_relationship_intelligence =
      Application.get_env(:maraithon, :relationship_intelligence)

    Application.put_env(:maraithon, :api_auth, bearer_token: "")

    on_exit(fn ->
      case previous_api_auth do
        nil -> Application.delete_env(:maraithon, :api_auth)
        value -> Application.put_env(:maraithon, :api_auth, value)
      end

      case previous_relationship_intelligence do
        nil -> Application.delete_env(:maraithon, :relationship_intelligence)
        value -> Application.put_env(:maraithon, :relationship_intelligence, value)
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
    assert "learn_relationship_context" in names
    assert "list_memories" in names
    assert "write_memory" in names
    assert "recall_memory" in names
    assert "forget_memory" in names
    assert "record_memory_feedback" in names
    assert "update_memory_confidence" in names

    list_todos =
      response
      |> get_in(["result", "tools"])
      |> Enum.find(&(&1["name"] == "list_todos"))

    assert get_in(list_todos, ["inputSchema", "properties", "user_id", "type"]) == "string"
    assert "user_id" in get_in(list_todos, ["inputSchema", "required"])
    assert get_in(list_todos, ["annotations", "readOnlyHint"]) == true
    assert get_in(list_todos, ["annotations", "destructiveHint"]) == false
  end

  test "filters tool discovery over MCP", %{conn: conn} do
    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 11,
        "method" => "tools/list",
        "params" => %{"names" => ["list_todos", "upsert_todos", "not_a_tool"]}
      })

    response = json_response(conn, 200)

    assert response |> get_in(["result", "tools"]) |> Enum.map(& &1["name"]) == [
             "list_todos",
             "upsert_todos"
           ]
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

    text = response |> get_in(["result", "content"]) |> hd() |> Map.fetch!("text")
    assert {:ok, _decoded} = Jason.decode(text)
    refute String.contains?(text, "\n")
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

  test "calls model-backed relationship learning over MCP", %{conn: conn} do
    user_id = "mcp-relationship-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    Application.put_env(:maraithon, :relationship_intelligence,
      llm_complete: fn _params ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "summary" => "Learned Emma school context.",
               "people" => [
                 %{
                   "person_ref" => "emma",
                   "display_name" => "Emma",
                   "relationship" => "child",
                   "communication_frequency" => "recurring school logistics",
                   "confidence" => 0.92
                 }
               ],
               "memories" => [
                 %{
                   "kind" => "relationship",
                   "title" => "Emma school logistics",
                   "content" =>
                     "School newsletters and forms about Emma should be treated as parent logistics for Kent.",
                   "tags" => ["emma", "school"],
                   "importance" => 85,
                   "confidence" => 0.9,
                   "dedupe_key" => "mcp:emma-school"
                 }
               ],
               "links" => [
                 %{
                   "person_ref" => "emma",
                   "resource_type" => "gmail_thread",
                   "resource_id" => "thread-4m",
                   "resource_source" => "gmail",
                   "title" => "4M Weekly Newsletter",
                   "relationship_note" => "The source is about Emma's school logistics."
                 }
               ]
             })
         }}
      end
    )

    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 6,
        "method" => "tools/call",
        "params" => %{
          "name" => "learn_relationship_context",
          "arguments" => %{
            "user_id" => user_id,
            "source" => "mcp_test",
            "observations" => [
              %{
                "source" => "gmail",
                "resource_type" => "gmail_thread",
                "resource_id" => "thread-4m",
                "title" => "4M Weekly Newsletter",
                "summary" => "Emma's class newsletter includes a permission form.",
                "from" => "school@example.com",
                "to" => user_id
              }
            ]
          }
        }
      })

    response = json_response(conn, 200)

    assert get_in(response, ["result", "isError"]) == false
    assert get_in(response, ["result", "structuredContent", "people_count"]) == 1
    assert get_in(response, ["result", "structuredContent", "memory_count"]) == 1
    assert get_in(response, ["result", "structuredContent", "link_count"]) == 1
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

  test "returns structured policy errors for confirmation-required MCP calls", %{conn: conn} do
    user_id = "mcp-policy-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 41,
        "method" => "tools/call",
        "params" => %{
          "name" => "gmail_send_message",
          "arguments" => %{
            "user_id" => user_id,
            "to" => "someone@example.com",
            "subject" => "Policy test",
            "body" => "This should not send."
          }
        }
      })

    response = json_response(conn, 200)

    assert get_in(response, ["error", "code"]) == -32071

    assert get_in(response, ["error", "data", "policy_decision", "reason_code"]) ==
             "confirmation_required"

    assert [entry] = Maraithon.ActionLedger.list_recent(user_id, limit: 1)
    assert entry.event_type == "tool.needs_confirmation"
    assert entry.metadata["tool_name"] == "gmail_send_message"
  end

  test "handles JSON-RPC batch calls concurrently", %{conn: conn} do
    user_id = "mcp-batch-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!([
          %{
            "jsonrpc" => "2.0",
            "id" => "todos",
            "method" => "tools/call",
            "params" => %{
              "name" => "list_todos",
              "arguments" => %{"user_id" => user_id}
            }
          },
          %{
            "jsonrpc" => "2.0",
            "id" => "people",
            "method" => "tools/call",
            "params" => %{
              "name" => "list_people",
              "arguments" => %{"user_id" => user_id}
            }
          }
        ])
      )

    response = json_response(conn, 200)

    assert [%{"id" => "todos"}, %{"id" => "people"}] = response

    assert get_in(Enum.at(response, 0), ["result", "structuredContent", "source"]) ==
             "maraithon_todos"

    assert get_in(Enum.at(response, 1), ["result", "structuredContent", "source"]) ==
             "maraithon_crm"
  end
end
