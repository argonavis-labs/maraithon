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

  test "checked-in protocol schema matches runtime method set" do
    schema =
      "priv/control_protocol.schema.json"
      |> File.read!()
      |> Jason.decode!()

    assert Map.keys(schema["methods"]) |> Enum.sort() ==
             Maraithon.ControlProtocol.contract().methods |> Map.keys() |> Enum.sort()
  end
end
