defmodule Maraithon.Push.APNSTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Maraithon.Push.APNS

  defmodule OkHTTP do
    def post(url, headers, body) do
      send(self(), {:apns_request, url, headers, body})
      {:ok, 200, ""}
    end
  end

  defmodule CapturingJWTHTTP do
    def post(_url, headers, _body) do
      authorization = headers |> Map.new() |> Map.fetch!("authorization")
      Agent.update(__MODULE__, &[authorization | &1])
      {:ok, 200, ""}
    end
  end

  defmodule RacingRejectedJWTHTTP do
    def post(url, headers, _body) do
      authorization = headers |> Map.new() |> Map.fetch!("authorization")
      parent = Agent.get(__MODULE__, & &1)
      device = url |> String.split("/") |> List.last()
      send(parent, {:racing_jwt_request, device, authorization, self()})

      if device in ["old-a", "old-b"] do
        receive do
          :reject_old_token -> {:ok, 403, ~s({"reason":"InvalidProviderToken"})}
        end
      else
        {:ok, 200, ""}
      end
    end
  end

  defmodule GoneHTTP do
    def post(_url, _headers, _body), do: {:ok, 410, ~s({"reason":"Unregistered"})}
  end

  defmodule ThrottledHTTP do
    def post(_url, _headers, _body), do: {:ok, 429, ~s({"reason":"TooManyRequests"})}
  end

  defmodule StaleConnectionHTTP do
    # A closed idle HTTP/2 connection is still ambiguous once the POST was
    # attempted, so the client must not issue a second request.
    def post(url, _headers, _body) do
      case Process.get(:stale_connection_http_calls, 0) do
        0 ->
          Process.put(:stale_connection_http_calls, 1)
          {:error, %Mint.TransportError{reason: :closed}}

        calls ->
          Process.put(:stale_connection_http_calls, calls + 1)
          send(self(), {:apns_retry_request, url})
          {:ok, 200, ""}
      end
    end
  end

  defmodule BeforeSendFailureHTTP do
    def post(_url, _headers, _body) do
      Process.put(:before_send_http_calls, Process.get(:before_send_http_calls, 0) + 1)
      {:error, {:before_send, :preflight_failed}}
    end
  end

  defmodule DownHTTP do
    def post(_url, _headers, _body) do
      Process.put(:down_http_calls, Process.get(:down_http_calls, 0) + 1)
      {:error, %Mint.TransportError{reason: :closed}}
    end
  end

  setup do
    previous = Application.get_env(:maraithon, :apns, [])

    ec_key = :public_key.generate_key({:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec_key)])

    Application.put_env(:maraithon, :apns,
      team_id: "TEAM123456",
      key_id: "KEY1234567",
      private_key: pem,
      topic: "com.bliss.maraithonmobile",
      environment: "production",
      http_module: OkHTTP
    )

    APNS.reset_jwt_cache()

    on_exit(fn ->
      APNS.reset_jwt_cache()
      Application.put_env(:maraithon, :apns, previous)
    end)

    :ok
  end

  test "configured? is false without a key and true with one" do
    assert APNS.configured?()

    Application.put_env(:maraithon, :apns, team_id: "TEAM123456")
    refute APNS.configured?()
  end

  test "send posts an ES256-signed request to the device endpoint" do
    assert :ok = APNS.send("abc123token", %{"aps" => %{}}, collapse_id: "dedupe:1")

    assert_receive {:apns_request, url, headers, _body}
    assert url == "https://api.push.apple.com/3/device/abc123token"

    headers = Map.new(headers)
    assert headers["apns-topic"] == "com.bliss.maraithonmobile"
    assert headers["apns-push-type"] == "alert"
    assert {:ok, _apns_id} = Ecto.UUID.cast(headers["apns-id"])

    expected_collapse_id =
      Base.encode16(:crypto.hash(:sha256, "dedupe:1"), case: :lower)

    assert headers["apns-collapse-id"] == expected_collapse_id
    assert byte_size(headers["apns-collapse-id"]) == 64

    assert "bearer " <> jwt = headers["authorization"]
    assert [header, claims, signature] = String.split(jwt, ".")

    assert %{"alg" => "ES256", "kid" => "KEY1234567"} =
             header |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert %{"iss" => "TEAM123456", "iat" => iat} =
             claims |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert is_integer(iat)
    # JOSE ES256 signatures are raw r||s — exactly 64 bytes.
    assert byte_size(Base.url_decode64!(signature, padding: false)) == 64
  end

  test "concurrent cold-cache sends share one provider JWT" do
    start_supervised!(%{
      id: CapturingJWTHTTP,
      start: {Agent, :start_link, [fn -> [] end, [name: CapturingJWTHTTP]]}
    })

    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(Application.get_env(:maraithon, :apns), :http_module, CapturingJWTHTTP)
    )

    parent = self()

    tasks =
      for index <- 1..5 do
        Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
          send(parent, {:jwt_sender_ready, self()})

          receive do
            :send_push -> APNS.send("device-#{index}", %{"aps" => %{}})
          end
        end)
      end

    task_pids =
      for _index <- 1..5 do
        assert_receive {:jwt_sender_ready, pid}
        pid
      end

    Enum.each(task_pids, &send(&1, :send_push))
    assert Enum.map(tasks, &Task.await(&1, 5_000)) == List.duplicate(:ok, 5)

    authorizations = Agent.get(CapturingJWTHTTP, & &1)
    assert length(authorizations) == 5
    assert length(Enum.uniq(authorizations)) == 1
  end

  test "a delayed rejection for an old JWT cannot erase a newer cached generation" do
    parent = self()

    start_supervised!(%{
      id: RacingRejectedJWTHTTP,
      start: {Agent, :start_link, [fn -> parent end, [name: RacingRejectedJWTHTTP]]}
    })

    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(Application.get_env(:maraithon, :apns), :http_module, RacingRejectedJWTHTTP)
    )

    first =
      Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
        APNS.send("old-a", %{"aps" => %{}})
      end)

    second =
      Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
        APNS.send("old-b", %{"aps" => %{}})
      end)

    requests =
      for _index <- 1..2 do
        assert_receive {:racing_jwt_request, device, authorization, pid}, 1_000
        {device, authorization, pid}
      end

    assert Enum.map(requests, &elem(&1, 0)) |> MapSet.new() == MapSet.new(["old-a", "old-b"])
    assert requests |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1

    {first_device, old_authorization, first_pid} = List.first(requests)
    {_second_device, ^old_authorization, second_pid} = List.last(requests)
    send(first_pid, :reject_old_token)

    first_result = if first_device == "old-a", do: Task.await(first), else: Task.await(second)
    assert first_result == {:error, :retryable}

    assert :ok = APNS.send("mint-new", %{"aps" => %{}})
    assert_receive {:racing_jwt_request, "mint-new", new_authorization, _pid}
    refute new_authorization == old_authorization

    send(second_pid, :reject_old_token)
    second_result = if first_device == "old-a", do: Task.await(second), else: Task.await(first)
    assert second_result == {:error, :retryable}

    assert :ok = APNS.send("verify-new", %{"aps" => %{}})
    assert_receive {:racing_jwt_request, "verify-new", verified_authorization, _pid}
    assert verified_authorization == new_authorization
  end

  test "dead tokens classify as :unregistered" do
    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(Application.get_env(:maraithon, :apns), :http_module, GoneHTTP)
    )

    assert {:error, :unregistered} = APNS.send("dead", %{"aps" => %{}})
  end

  test "throttling classifies as :retryable" do
    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(Application.get_env(:maraithon, :apns), :http_module, ThrottledHTTP)
    )

    assert {:error, :retryable} = APNS.send("busy", %{"aps" => %{}})
  end

  test "a transport failure is not retried after the external-send boundary" do
    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(Application.get_env(:maraithon, :apns), :http_module, StaleConnectionHTTP)
    )

    assert {:error, :delivery_unknown} = APNS.send("stale-conn", %{"aps" => %{}})
    assert Process.get(:stale_connection_http_calls) == 1
    refute_received {:apns_retry_request, _url}
  end

  test "a failed connection preflight is definitive and does not cross the send boundary" do
    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(
        Application.get_env(:maraithon, :apns),
        :http_module,
        BeforeSendFailureHTTP
      )
    )

    assert {:error, :request_rejected} = APNS.send("preflight", %{"aps" => %{}})
    assert Process.get(:before_send_http_calls) == 1
  end

  test "a transport failure remains delivery-ambiguous after one attempt" do
    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(Application.get_env(:maraithon, :apns), :http_module, DownHTTP)
    )

    log =
      capture_log([metadata: [:failure_code, :transport_class]], fn ->
        assert {:error, :delivery_unknown} = APNS.send("down", %{"aps" => %{}})
      end)

    assert Process.get(:down_http_calls) == 1
    assert log =~ "failure_code=delivery_unknown"
    assert log =~ "transport_class=Elixir.Mint.TransportError"
  end

  test "payload carries alert, thread id, and deeplink outside aps" do
    payload =
      APNS.payload(%{
        title: "Your briefing is ready",
        body: "Thursday, July 16",
        deeplink: "maraithon://today",
        thread_id: "brief"
      })

    assert payload["aps"]["alert"]["title"] == "Your briefing is ready"
    assert payload["aps"]["alert"]["body"] == "Thursday, July 16"
    assert payload["aps"]["thread-id"] == "brief"
    assert payload["aps"]["sound"] == "default"
    assert payload["deeplink"] == "maraithon://today"
  end

  test "payload clamps oversized bodies" do
    payload = APNS.payload(%{title: "t", body: String.duplicate("x", 5_000)})
    assert String.length(payload["aps"]["alert"]["body"]) <= 900
  end

  test "escape-heavy payloads remain within the APNs JSON byte limit" do
    hostile = String.duplicate(<<1, ?", ?\\, 10>>, 2_000)

    payload =
      APNS.payload(%{
        title: hostile,
        body: hostile,
        deeplink: hostile,
        thread_id: hostile
      })

    encoded = Jason.encode!(payload)
    assert byte_size(encoded) <= 4_096
    assert String.valid?(encoded)
  end
end
