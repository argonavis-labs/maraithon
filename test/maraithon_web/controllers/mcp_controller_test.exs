defmodule MaraithonWeb.McpControllerTest do
  use MaraithonWeb.ConnCase, async: false

  alias Maraithon.{Accounts, ConnectedAccounts, Todos}

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
    assert "get_todo" in names
    assert "update_todo" in names
    assert "resolve_todo" in names
    assert "delete_todo" in names
    assert "list_connected_accounts" in names
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
    assert get_in(list_todos, ["annotations", "resourceTypes"]) == ["todo", "open_loop"]
    assert get_in(list_todos, ["annotations", "operationTags"]) == ["read", "list"]

    update_todo =
      response
      |> get_in(["result", "tools"])
      |> Enum.find(&(&1["name"] == "update_todo"))

    assert get_in(update_todo, ["annotations", "sideEffect"]) == "write"
    assert get_in(update_todo, ["annotations", "operationTags"]) == ["update", "patch"]
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

  test "supports explicit todo CRUD tools over MCP", %{conn: conn} do
    user_id = "mcp-todo-crud-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "mcp_test",
          "title" => "Review MCP CRUD",
          "summary" => "Verify todo CRUD tools work over hosted MCP.",
          "next_action" => "Read, patch, and dismiss the seeded todo.",
          "dedupe_key" => "mcp:test:crud"
        }
      ])

    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "get",
        "method" => "tools/call",
        "params" => %{
          "name" => "get_todo",
          "arguments" => %{"user_id" => user_id, "todo_id" => todo.id}
        }
      })

    response = json_response(conn, 200)

    assert get_in(response, ["result", "isError"]) == false
    assert get_in(response, ["result", "structuredContent", "todo", "id"]) == todo.id

    conn =
      build_conn()
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "update",
        "method" => "tools/call",
        "params" => %{
          "name" => "update_todo",
          "arguments" => %{
            "user_id" => user_id,
            "todo_id" => todo.id,
            "title" => "Review MCP CRUD coverage",
            "priority" => 91,
            "metadata" => %{"audit" => "mcp_crud"}
          }
        }
      })

    response = json_response(conn, 200)

    assert get_in(response, ["result", "isError"]) == false

    assert get_in(response, ["result", "structuredContent", "todo", "title"]) ==
             "Review MCP CRUD coverage"

    assert get_in(response, ["result", "structuredContent", "todo", "priority"]) == 91

    assert get_in(response, ["result", "structuredContent", "todo", "metadata", "audit"]) ==
             "mcp_crud"

    conn =
      build_conn()
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "delete-needs-confirmation",
        "method" => "tools/call",
        "params" => %{
          "name" => "delete_todo",
          "arguments" => %{"user_id" => user_id, "todo_id" => todo.id}
        }
      })

    response = json_response(conn, 200)
    assert get_in(response, ["error", "code"]) == -32071

    conn =
      build_conn()
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "delete-confirmed",
        "method" => "tools/call",
        "params" => %{
          "name" => "delete_todo",
          "confirmed" => true,
          "arguments" => %{
            "user_id" => user_id,
            "todo_id" => todo.id,
            "resolution_note" => "No longer relevant."
          }
        }
      })

    response = json_response(conn, 200)

    assert get_in(response, ["result", "isError"]) == false
    assert get_in(response, ["result", "structuredContent", "deleted"]) == true
    assert get_in(response, ["result", "structuredContent", "todo", "status"]) == "dismissed"
  end

  test "lists connected account status and tool coverage over MCP", %{conn: conn} do
    user_id = "mcp-connected-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042", "bot_token" => "secret"}
      })

    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "connected",
        "method" => "tools/call",
        "params" => %{
          "name" => "list_connected_accounts",
          "arguments" => %{"user_id" => user_id}
        }
      })

    response = json_response(conn, 200)

    assert get_in(response, ["result", "isError"]) == false

    assert get_in(response, ["result", "structuredContent", "source"]) ==
             "maraithon_connected_accounts"

    connected_accounts = get_in(response, ["result", "structuredContent", "connected_accounts"])
    assert Enum.any?(connected_accounts, &(&1["provider"] == "telegram"))

    telegram = Enum.find(connected_accounts, &(&1["provider"] == "telegram"))
    assert telegram["account_label"] == "Telegram"
    refute Map.has_key?(telegram, "external_account_id")
    refute get_in(telegram, ["metadata", "chat_id"])
    refute get_in(telegram, ["metadata", "bot_token"])

    response_text = inspect(response)
    refute response_text =~ "external_account_id"
    refute response_text =~ "6114124042"
    refute response_text =~ "bot_token"
    refute response_text =~ "oauth_scopes"

    todo_coverage =
      response
      |> get_in(["result", "structuredContent", "built_in_resources"])
      |> Enum.find(&(&1["resource"] == "todos"))

    assert "get_todo" in todo_coverage["tools"]
    assert "update_todo" in todo_coverage["tools"]
    assert "delete_todo" in todo_coverage["tools"]

    gmail_coverage =
      response
      |> get_in(["result", "structuredContent", "tool_coverage"])
      |> Enum.find(&(&1["connector_id"] == "gmail"))

    assert "gmail_drafts" in gmail_coverage["tools"]
    assert "gmail_labels" in gmail_coverage["tools"]
    assert "gmail_filters" in gmail_coverage["tools"]
    assert "gmail_drafts" in gmail_coverage["operations"]["create"]
    assert "gmail_drafts" in gmail_coverage["operations"]["delete"]
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

  test "returns display-ready policy errors for unknown MCP tools", %{conn: conn} do
    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "unknown-tool",
        "method" => "tools/call",
        "params" => %{
          "name" => "internal_secret_tool",
          "arguments" => %{}
        }
      })

    response = json_response(conn, 200)

    assert get_in(response, ["error", "code"]) == -32070
    assert get_in(response, ["error", "message"]) == "Action is not available."
    assert get_in(response, ["error", "data", "policy_decision", "reason_code"]) == "unknown_tool"
    refute get_in(response, ["error", "data", "policy_decision", "metadata", "tool_name"])
    refute Jason.encode!(response) =~ "internal_secret_tool"
    refute Jason.encode!(response) =~ "Unknown tool:"
    refute Jason.encode!(response) =~ "Tool call"
  end

  test "handles malformed MCP batch requests without exposing internals", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!([
          %{
            "jsonrpc" => "2.0",
            "id" => "bad-method",
            "method" => %{"internal" => "secret"}
          }
        ])
      )

    response = json_response(conn, 200)

    assert [
             %{
               "id" => nil,
               "error" => %{"code" => -32600, "message" => "Invalid JSON-RPC request"}
             }
           ] = response

    encoded = Jason.encode!(response)
    refute encoded =~ "Protocol.UndefinedError"
    refute encoded =~ "internal"
    refute encoded =~ "secret"
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
