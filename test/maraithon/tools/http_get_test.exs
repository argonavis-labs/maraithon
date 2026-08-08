defmodule Maraithon.Tools.HttpGetTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.HttpGet

  @public_ipv4 {93, 184, 216, 34}
  @public_ipv6 {0x2606, 0x2800, 0x0220, 0x0001, 0x0248, 0x1893, 0x25C8, 0x1946}
  @fetch_error "Could not fetch that URL. Check the address and try again."

  describe "execute/1" do
    test "returns error when url is missing" do
      assert {:error, "url is required"} = HttpGet.execute(%{})
    end

    test "returns error when url is empty string" do
      assert {:error, "url is required"} = HttpGet.execute(%{"url" => "   "})
    end

    test "returns error when url is nil" do
      assert {:error, "url is required"} = HttpGet.execute(%{"url" => nil})
    end

    test "checks the byte cap and UTF-8 validity before parsing the URL" do
      assert {:error, "url is too long"} =
               HttpGet.execute(%{"url" => :binary.copy("a", 2_049)})

      assert {:error, "url must be valid UTF-8"} =
               HttpGet.execute(%{"url" => <<"http://example.com/", 0xFF>>})
    end

    test "rejects control and backslash URL ambiguities after byte and UTF-8 validation" do
      assert {:error, "url contains invalid characters"} =
               HttpGet.execute(%{"url" => "http://example.com\\@127.0.0.1/"})

      assert {:error, "url contains invalid characters"} =
               HttpGet.execute(%{"url" => "http://example.com/path\nnext"})
    end

    test "returns errors for invalid URL forms" do
      assert {:error, "url scheme must be http or https"} =
               HttpGet.execute(%{"url" => "ftp://example.com/file.txt"})

      assert {:error, "url must include scheme (http or https)"} =
               HttpGet.execute(%{"url" => "example.com/path"})

      assert {:error, "url must not include credentials"} =
               HttpGet.execute(%{"url" => "http://user:pass@example.com/private"})

      assert {:error, "url host is required"} = HttpGet.execute(%{"url" => "http:///path"})

      assert {:error, "url is invalid"} =
               HttpGet.execute(%{"url" => "http://example.com:abc/path"})

      assert {:error, "url is invalid"} =
               HttpGet.execute(%{"url" => "http://[2606:4700:4700::1111]junk/path"})

      assert {:error, "url is invalid"} =
               HttpGet.execute(%{"url" => "http://example.com/%zz"})

      assert {:error, "url is invalid"} =
               HttpGet.execute(%{"url" => "http://example.com/path?value=%zz"})

      assert {:error, "url is invalid"} =
               HttpGet.execute(%{"url" => "http://exa%mple.com/path"})

      assert {:error, "url host must not end with a dot"} =
               HttpGet.execute(%{"url" => "https://example.com./path"})
    end

    test "pins a deterministic validated address while preserving the original hostname" do
      test_pid = self()

      resolver = fn hostname, deadline, clock ->
        send(test_pid, {:resolved, hostname, deadline, clock.()})
        {:ok, [@public_ipv6, @public_ipv4]}
      end

      transport = fn request, deadline, clock ->
        send(test_pid, {:request, request, deadline, clock.()})
        {:ok, %{status: 200, body: "Hello World", truncated?: false}}
      end

      assert {:ok, result} =
               HttpGet.execute(
                 %{"url" => "http://Example.COM:8080/test?q=ok#ignored"},
                 resolver: resolver,
                 transport: transport,
                 clock: fn -> 100 end,
                 deadline_ms: 500
               )

      assert result == %{
               status: 200,
               body: "Hello World",
               url: "http://Example.COM:8080/test"
             }

      assert_received {:resolved, "Example.COM", 600, 100}
      assert_received {:request, request, 600, 100}
      assert request.address == @public_ipv4
      assert request.hostname == "Example.COM"
      assert request.scheme == :http
      assert request.port == 8080
      assert request.target == "/test?q=ok"
    end

    test "rejects every result when any resolved address is non-global" do
      resolver = fn _hostname, _deadline, _clock ->
        {:ok, [@public_ipv4, {127, 0, 0, 1}]}
      end

      test_pid = self()

      transport = fn _request, _deadline, _clock ->
        send(test_pid, :transport_called)
        {:ok, %{status: 200, body: "unexpected", truncated?: false}}
      end

      assert {:error, @fetch_error} =
               HttpGet.execute(%{"url" => "https://example.com"},
                 resolver: resolver,
                 transport: transport
               )

      refute_received :transport_called
    end

    test "rejects representative non-global IPv4 and IPv6 destinations" do
      addresses = [
        {0, 0, 0, 0},
        {10, 0, 0, 1},
        {100, 64, 0, 1},
        {127, 0, 0, 1},
        {169, 254, 169, 254},
        {172, 16, 0, 1},
        {192, 168, 0, 1},
        {224, 0, 0, 1},
        {0, 0, 0, 0, 0, 0, 0, 1},
        {0xFC00, 0, 0, 0, 0, 0, 0, 1},
        {0xFE80, 0, 0, 0, 0, 0, 0, 1}
      ]

      for address <- addresses do
        resolver = fn _hostname, _deadline, _clock -> {:ok, [address]} end
        test_pid = self()

        assert {:error, @fetch_error} =
                 HttpGet.execute(%{"url" => "http://example.com"},
                   resolver: resolver,
                   transport: fn _request, _deadline, _clock ->
                     send(test_pid, {:transport_called, address})
                     {:ok, %{status: 200, body: "unexpected", truncated?: false}}
                   end
                 )

        refute_received {:transport_called, ^address}
      end
    end

    test "fails closed on DNS errors" do
      resolver = fn _hostname, _deadline, _clock -> {:error, :dns_timeout} end

      assert {:error, @fetch_error} =
               HttpGet.execute(%{"url" => "https://example.com"}, resolver: resolver)
    end

    test "stops the owner watcher after a successful transport" do
      test_pid = self()

      _caller =
        start_supervised!(
          {Task,
           fn ->
             result =
               HttpGet.execute(%{"url" => "https://example.com"},
                 resolver: public_resolver(),
                 transport: fn _request, _deadline, _clock ->
                   send(test_pid, {:transport_waiting, self()})

                   receive do
                     :release_transport ->
                       {:ok, %{status: 200, body: "ok", truncated?: false}}
                   end
                 end,
                 watcher_observer: test_pid
               )

             send(test_pid, {:http_result, result})
           end}
        )

      assert_receive {:transport_watcher_started, watcher}
      assert_receive {:transport_waiting, transport_worker}
      watcher_ref = Process.monitor(watcher)
      send(transport_worker, :release_transport)

      assert_receive {:http_result, {:ok, _result}}
      assert_receive {:DOWN, ^watcher_ref, :process, ^watcher, :normal}
    end

    test "enforces the absolute deadline around transport cleanup" do
      started_at = System.monotonic_time(:millisecond)

      transport = fn _request, _deadline, _clock ->
        receive do
          :never -> {:error, :unexpected}
        after
          5_000 -> {:error, :transport_timeout}
        end
      end

      assert {:error, @fetch_error} =
               HttpGet.execute(%{"url" => "https://example.com"},
                 resolver: public_resolver(),
                 transport: transport,
                 deadline_ms: 25
               )

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert elapsed_ms < 500
    end

    test "redacts every query value and drops fragments from the returned URL" do
      assert {:ok, result} =
               execute_with_response(
                 "http://example.com/test?X-Amz-Signature=query-secret&visible=ok#access_token=fragment-secret",
                 %{status: 200, body: "Hello World", truncated?: false}
               )

      assert result.url == "http://example.com/test"

      refute inspect(result) =~ "query-secret"
      refute inspect(result) =~ "fragment-secret"

      assert {:ok, opaque_result} =
               execute_with_response(
                 "http://example.com/test?super-secret-capability",
                 %{status: 200, body: "Hello World", truncated?: false}
               )

      assert opaque_result.url == "http://example.com/test"
      refute inspect(opaque_result) =~ "super-secret-capability"
    end

    test "rejects status codes outside the RFC range" do
      for status <- [99, 600, 999] do
        assert {:error, @fetch_error} =
                 execute_with_response("http://example.com/status", %{
                   status: status,
                   body: "invalid",
                   truncated?: false
                 })
      end
    end

    test "returns non-200 and redirect responses without another request" do
      test_pid = self()

      transport = fn request, _deadline, _clock ->
        send(test_pid, {:request_target, request.target})
        {:ok, %{status: 302, body: "Moved", truncated?: false}}
      end

      assert {:ok, %{status: 302, body: "Moved"}} =
               HttpGet.execute(%{"url" => "http://example.com/redirect"},
                 resolver: public_resolver(),
                 transport: transport
               )

      assert_received {:request_target, "/redirect"}
      refute_received {:request_target, _other_target}
    end

    test "truncates long response text" do
      assert {:ok, result} =
               execute_with_response("http://example.com/long", %{
                 status: 200,
                 body: String.duplicate("a", 6_000),
                 truncated?: false
               })

      assert result.status == 200
      assert String.ends_with?(result.body, "... (truncated)")
      assert String.length(result.body) < 6_000
    end

    test "rejects an oversized or invalid transport body before text processing" do
      assert {:error, @fetch_error} =
               execute_with_response("http://example.com/large", %{
                 status: 200,
                 body: :binary.copy("a", 20_001),
                 truncated?: false
               })

      assert {:error, @fetch_error} =
               execute_with_response("http://example.com/binary", %{
                 status: 200,
                 body: <<"safe", 0xFF, "token=secret">>,
                 truncated?: false
               })
    end

    test "accepts only a valid UTF-8 prefix when the byte-capped body ends mid-codepoint" do
      assert {:ok, result} =
               execute_with_response("http://example.com/truncated", %{
                 status: 200,
                 body: <<"safe", 0xF0, 0x9F>>,
                 truncated?: true
               })

      assert result.body == "safe... (truncated)"
    end

    test "redacts sensitive fields in response body text" do
      assert {:ok, result} =
               execute_with_response("http://example.com/secret", %{
                 status: 200,
                 body: ~s({"access_token":"secret-token","ok":true}),
                 truncated?: false
               })

      assert result.body =~ "access_token"
      assert result.body =~ "[redacted]"
      refute result.body =~ "secret-token"
    end

    test "keeps JSON response bodies as bounded text" do
      assert {:ok, result} =
               execute_with_response("https://example.com/json", %{
                 status: 200,
                 body: ~s({"key":"value"}),
                 truncated?: false
               })

      assert result.body == ~s({"key":"value"})
    end
  end

  defp execute_with_response(url, response) do
    HttpGet.execute(%{"url" => url},
      resolver: public_resolver(),
      transport: fn _request, _deadline, _clock -> {:ok, response} end,
      clock: fn -> 0 end
    )
  end

  defp public_resolver do
    fn _hostname, _deadline, _clock -> {:ok, [@public_ipv4]} end
  end
end
