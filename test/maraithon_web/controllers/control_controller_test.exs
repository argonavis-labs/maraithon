defmodule MaraithonWeb.ControlControllerTest do
  use MaraithonWeb.ConnCase, async: false

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

  test "exposes checked-in control contract methods", %{conn: conn} do
    conn =
      post(conn, "/api/v1/control", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "connect",
        "params" => %{"connection_id" => "test-control"}
      })

    response = json_response(conn, 200)

    assert get_in(response, ["result", "contract", "methods", "tools.call", "scopes"]) == [
             "tools:call"
           ]
  end

  test "allows read-only tool calls without idempotency key", %{conn: conn} do
    conn =
      post(conn, "/api/v1/control", %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools.call",
        "params" => %{"name" => "time", "arguments" => %{}}
      })

    response = json_response(conn, 200)

    assert get_in(response, ["result", "is_error"]) == false
    assert is_binary(get_in(response, ["result", "result", "utc"]))
    assert get_in(response, ["result", "idempotency_replay"]) == false
  end

  test "requires idempotency and confirmation for side-effecting tools", %{conn: conn} do
    missing_key =
      post(conn, "/api/v1/control", %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools.call",
        "params" => %{
          "name" => "gmail_send_message",
          "arguments" => %{"user_id" => "control@example.com"}
        }
      })
      |> json_response(200)

    assert get_in(missing_key, ["error", "code"]) == -32072

    request = %{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "tools.call",
      "params" => %{
        "name" => "gmail_send_message",
        "idempotency_key" => "control-key-123",
        "arguments" => %{"user_id" => "control@example.com"}
      }
    }

    first = post(conn, "/api/v1/control", request) |> json_response(200)
    second = post(conn, "/api/v1/control", request) |> json_response(200)

    assert get_in(first, ["error", "code"]) == -32071
    assert get_in(first, ["error", "data", "policy_decision", "status"]) == "needs_confirmation"
    assert get_in(first, ["error", "data", "idempotency_replay"]) == false

    assert get_in(second, ["error", "code"]) == -32071
    assert get_in(second, ["error", "data", "idempotency_replay"]) == true
  end

  test "rejects reused idempotency key with different payload", %{conn: conn} do
    base = %{
      "jsonrpc" => "2.0",
      "id" => 5,
      "method" => "tools.call",
      "params" => %{
        "name" => "gmail_send_message",
        "idempotency_key" => "control-key-conflict",
        "arguments" => %{"user_id" => "control@example.com", "to" => "a@example.com"}
      }
    }

    changed = put_in(base, ["params", "arguments", "to"], "b@example.com")

    assert post(conn, "/api/v1/control", base) |> json_response(200) |> get_in(["error", "code"]) ==
             -32071

    assert post(conn, "/api/v1/control", changed)
           |> json_response(200)
           |> get_in(["error", "code"]) == -32073
  end

  test "does not expose unknown tool names in policy denial copy", %{conn: conn} do
    response =
      post(conn, "/api/v1/control", %{
        "jsonrpc" => "2.0",
        "id" => 6,
        "method" => "tools.call",
        "params" => %{
          "name" => "internal_secret_tool",
          "arguments" => %{"user_id" => "control@example.com"}
        }
      })
      |> json_response(200)

    assert get_in(response, ["error", "code"]) == -32070
    assert get_in(response, ["error", "message"]) == "Action is not available."

    assert get_in(response, ["error", "data", "policy_decision", "message"]) ==
             "Action is not available."

    refute Map.has_key?(
             get_in(response, ["error", "data", "policy_decision", "metadata"]),
             "tool_name"
           )

    refute inspect(response) =~ "internal_secret_tool"
    refute inspect(response) =~ "Tool call"
    refute inspect(response) =~ "Tool policy"
  end

  test "does not expose connector error codes from tool failures", %{conn: conn} do
    response =
      post(conn, "/api/v1/control", %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools.call",
        "params" => %{
          "name" => "gmail_list_recent",
          "arguments" => %{"user_id" => "control-gmail-missing@example.com"}
        }
      })
      |> json_response(200)

    assert get_in(response, ["result", "is_error"]) == true
    assert get_in(response, ["result", "error", "code"]) == "tool_error"

    assert get_in(response, ["result", "error", "message"]) ==
             "Connect the missing account, then try again."

    refute inspect(response) =~ "google_account_not_connected"
  end

  test "does not expose raw scheduled task failures", %{conn: conn} do
    response =
      post(conn, "/api/v1/control", %{
        "jsonrpc" => "2.0",
        "id" => 8,
        "method" => "scheduled_tasks.create",
        "params" => %{
          "user_id" => "control-scheduled@example.com",
          "idempotency_key" => "control-scheduled-#{System.unique_integer([:positive])}",
          "task" => %{
            "title" => "Review the brief",
            "command" => %{"type" => "assistant_prompt", "prompt" => "Review the brief"}
          }
        }
      })
      |> json_response(200)

    assert get_in(response, ["result", "is_error"]) == true
    assert get_in(response, ["result", "error", "code"]) == "scheduled_task_error"

    assert get_in(response, ["result", "error", "message"]) ==
             "Scheduled task needs a valid schedule."

    refute inspect(response) =~ "invalid_schedule"
    refute inspect(response) =~ "Ecto.Changeset"
  end

  test "does not expose raw mobile pairing failures", %{conn: conn} do
    response =
      post(conn, "/api/v1/control", %{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "mobile_nodes.pair",
        "params" => %{
          "user_id" => "control-mobile@example.com",
          "idempotency_key" => "control-mobile-#{System.unique_integer([:positive])}",
          "allowed_commands" => ["notify", "exec"]
        }
      })
      |> json_response(200)

    assert get_in(response, ["result", "is_error"]) == true
    assert get_in(response, ["result", "error", "code"]) == "mobile_pairing_error"

    assert get_in(response, ["result", "error", "message"]) ==
             "Pairing can only grant supported mobile commands."

    refute inspect(response) =~ "forbidden_mobile_command"
  end

  test "checked-in protocol schema matches runtime method set" do
    schema =
      "priv/control_protocol.schema.json"
      |> File.read!()
      |> Jason.decode!()

    assert Map.keys(schema["methods"]) |> Enum.sort() ==
             Maraithon.ControlProtocol.contract().methods |> Map.keys() |> Enum.sort()
  end
end
