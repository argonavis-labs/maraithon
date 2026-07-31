defmodule Maraithon.Push.APNSTest do
  use ExUnit.Case, async: false

  alias Maraithon.Push.APNS

  defmodule OkHTTP do
    def post(url, headers, body) do
      send(self(), {:apns_request, url, headers, body})
      {:ok, 200, ""}
    end
  end

  defmodule GoneHTTP do
    def post(_url, _headers, _body), do: {:ok, 410, ~s({"reason":"Unregistered"})}
  end

  defmodule ThrottledHTTP do
    def post(_url, _headers, _body), do: {:ok, 429, ~s({"reason":"TooManyRequests"})}
  end

  defmodule StaleConnectionHTTP do
    # First request fails at the transport layer (idle HTTP/2 connection was
    # closed under us); the retry lands on a fresh connection and succeeds.
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
    assert headers["apns-collapse-id"] == "dedupe:1"

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

  test "a transport failure is retried once on a fresh connection" do
    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(Application.get_env(:maraithon, :apns), :http_module, StaleConnectionHTTP)
    )

    assert :ok = APNS.send("stale-conn", %{"aps" => %{}})
    assert Process.get(:stale_connection_http_calls) == 2
    assert_receive {:apns_retry_request, _url}
  end

  test "a persistent transport failure classifies as :retryable after one retry" do
    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(Application.get_env(:maraithon, :apns), :http_module, DownHTTP)
    )

    assert {:error, :retryable} = APNS.send("down", %{"aps" => %{}})
    assert Process.get(:down_http_calls) == 2
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
end
