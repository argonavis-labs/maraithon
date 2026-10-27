defmodule Maraithon.Tools.HttpGet.TransportTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.HttpGet.Transport

  test "connects to the exact tuple in passive mode with the original hostname" do
    test_pid = self()
    request = request()

    connect = fn scheme, address, port, opts ->
      send(test_pid, {:connect, scheme, address, port, opts})
      {:ok, :connection}
    end

    request_fun = fn connection, method, target, headers, body ->
      send(test_pid, {:request, connection, method, target, headers, body})
      {:ok, connection, :request_ref}
    end

    recv = fn connection, byte_count, timeout ->
      send(test_pid, {:recv, connection, byte_count, timeout})

      {:ok, connection,
       [
         {:status, :request_ref, 200},
         {:headers, :request_ref, []},
         {:data, :request_ref, "hello"},
         {:done, :request_ref}
       ]}
    end

    close = fn connection ->
      send(test_pid, {:close, connection})
      {:ok, connection}
    end

    assert {:ok, %{status: 200, body: "hello", truncated?: false}} =
             Transport.get(request, 100, fn -> 0 end,
               connect: connect,
               request: request_fun,
               recv: recv,
               close: close
             )

    assert_received {:connect, :https, {93, 184, 216, 34}, 443, connect_opts}
    assert connect_opts[:hostname] == "Original.Example"
    assert connect_opts[:mode] == :passive
    assert connect_opts[:protocols] == [:http1]
    assert connect_opts[:max_header_list_size] == 256
    assert connect_opts[:transport_opts][:timeout] == 25
    assert connect_opts[:transport_opts][:send_timeout] == 25
    assert connect_opts[:transport_opts][:send_timeout_close] == true
    assert connect_opts[:transport_opts][:inet6] == false
    assert connect_opts[:transport_opts][:inet4] == true

    assert_received {:request, :connection, "GET", "/path?q=1", headers, nil}
    assert {"host", "Original.Example"} in headers
    assert {"accept-encoding", "identity"} in headers
    assert {"connection", "close"} in headers
    assert_received {:recv, :connection, 0, 30}
    assert_received {:close, :connection}
  end

  test "uses IPv6 socket options without IPv4 fallback for an IPv6 tuple" do
    test_pid = self()
    ipv6 = {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

    connect = fn _scheme, address, _port, opts ->
      send(test_pid, {:connect, address, opts})
      {:error, :stopped_after_connect_options}
    end

    assert {:error, :stopped_after_connect_options} =
             Transport.get(request(address: ipv6), 100, fn -> 0 end, connect: connect)

    assert_received {:connect, ^ipv6, opts}
    assert opts[:transport_opts][:inet6] == true
    assert opts[:transport_opts][:inet4] == false
  end

  test "brackets an IPv6 literal in Host and includes a non-default port" do
    ipv6 = {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}
    test_pid = self()

    responses = [
      {:status, :ref, 204},
      {:headers, :ref, []},
      {:done, :ref}
    ]

    assert {:ok, %{status: 204, body: "", truncated?: false}} =
             fake_response(
               request(
                 address: ipv6,
                 hostname: "2606:4700:4700::1111",
                 port: 8_443
               ),
               responses,
               fn headers -> send(test_pid, {:headers, headers}) end
             )

    assert_received {:headers, headers}
    assert {"host", "[2606:4700:4700::1111]:8443"} in headers
  end

  test "caps response bytes before accumulating the body" do
    responses = [
      {:status, :ref, 200},
      {:data, :ref, "abc"},
      {:data, :ref, "defgh"},
      {:done, :ref}
    ]

    assert {:ok, %{status: 200, body: "abcde", truncated?: true}} =
             fake_response(request(max_body_bytes: 5), responses)
  end

  test "caps body chunks even when many arrive in one socket receive" do
    responses = [
      {:status, :ref, 200},
      {:data, :ref, "a"},
      {:data, :ref, "b"},
      {:data, :ref, "c"},
      {:done, :ref}
    ]

    assert {:ok, %{status: 200, body: "ab", truncated?: true}} =
             fake_response(request(max_body_chunks: 2), responses)
  end

  test "caps response events and passive receive calls" do
    event_overflow = [
      {:status, :ref, 200},
      {:headers, :ref, []},
      {:headers, :ref, []}
    ]

    assert {:error, :too_many_response_events} =
             fake_response(request(max_response_events: 2), event_overflow)

    test_pid = self()

    recv = fn connection, 0, _timeout ->
      send(test_pid, :recv_called)
      {:ok, connection, []}
    end

    assert {:error, :too_many_receive_calls} =
             Transport.get(request(max_receive_calls: 2), 100, fn -> 0 end,
               connect: fn _scheme, _address, _port, _opts -> {:ok, :connection} end,
               request: fn connection, "GET", _target, _headers, nil ->
                 {:ok, connection, :ref}
               end,
               recv: recv,
               close: fn connection -> {:ok, connection} end
             )

    assert_received :recv_called
    assert_received :recv_called
    refute_received :recv_called
  end

  test "does no work after the absolute deadline expires" do
    test_pid = self()

    connect = fn _scheme, _address, _port, _opts ->
      send(test_pid, :connect_called)
      {:ok, :connection}
    end

    assert {:error, :deadline_exceeded} =
             Transport.get(request(), 10, fn -> 10 end, connect: connect)

    refute_received :connect_called
  end

  test "returns a redirect response without following its Location" do
    test_pid = self()

    responses = [
      {:status, :ref, 302},
      {:headers, :ref, [{"location", "http://127.0.0.1/private"}]},
      {:data, :ref, "Moved"},
      {:done, :ref}
    ]

    assert {:ok, %{status: 302, body: "Moved", truncated?: false}} =
             fake_response(request(), responses, fn _headers ->
               send(test_pid, :request_sent)
             end)

    assert_received :request_sent
    refute_received :request_sent
  end

  test "the Mint transport reaches a pinned socket while sending the hostname in Host" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/pinned", fn conn ->
      assert Plug.Conn.get_req_header(conn, "host") == ["public.example:#{bypass.port}"]
      assert conn.query_string == "visible=yes"
      Plug.Conn.resp(conn, 200, "pinned response")
    end)

    deadline = System.monotonic_time(:millisecond) + 2_000

    assert {:ok, %{status: 200, body: "pinned response", truncated?: false}} =
             Transport.get(
               request(
                 scheme: :http,
                 address: {127, 0, 0, 1},
                 hostname: "public.example",
                 port: bypass.port,
                 target: "/pinned?visible=yes",
                 connect_timeout_ms: 1_000,
                 receive_timeout_ms: 1_000
               ),
               deadline,
               fn -> System.monotonic_time(:millisecond) end
             )
  end

  test "rejects excessive response header counts and bytes" do
    too_many_headers =
      for index <- 1..9 do
        {"x-header-#{index}", "ok"}
      end

    assert {:error, :too_many_response_headers} =
             fake_response(
               request(),
               [
                 {:status, :ref, 200},
                 {:headers, :ref, too_many_headers},
                 {:done, :ref}
               ]
             )

    assert {:error, :response_headers_too_large} =
             fake_response(
               request(),
               [
                 {:status, :ref, 200},
                 {:headers, :ref, [{"x-large", String.duplicate("x", 256)}]},
                 {:done, :ref}
               ]
             )
  end

  defp fake_response(request, responses, on_request \\ fn _headers -> :ok end) do
    Transport.get(request, 100, fn -> 0 end,
      connect: fn _scheme, _address, _port, _opts -> {:ok, :connection} end,
      request: fn connection, "GET", _target, headers, nil ->
        on_request.(headers)
        {:ok, connection, :ref}
      end,
      recv: fn connection, 0, _timeout -> {:ok, connection, responses} end,
      close: fn connection -> {:ok, connection} end
    )
  end

  defp request(overrides \\ []) do
    Map.merge(
      %{
        scheme: :https,
        address: {93, 184, 216, 34},
        hostname: "Original.Example",
        port: 443,
        target: "/path?q=1",
        connect_timeout_ms: 25,
        receive_timeout_ms: 30,
        max_body_bytes: 100,
        max_body_chunks: 8,
        max_receive_calls: 8,
        max_response_events: 16,
        max_response_headers: 8,
        max_response_header_bytes: 256
      },
      Map.new(overrides)
    )
  end
end
