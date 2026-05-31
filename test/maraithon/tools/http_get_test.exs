defmodule Maraithon.Tools.HttpGetTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.HttpGet

  describe "execute/1" do
    test "returns error when url is missing" do
      {:error, message} = HttpGet.execute(%{})

      assert message == "url is required"
    end

    test "returns error when url is empty string" do
      {:error, message} = HttpGet.execute(%{"url" => "   "})

      assert message == "url is required"
    end

    test "returns error when url is nil" do
      {:error, message} = HttpGet.execute(%{"url" => nil})

      assert message == "url is required"
    end

    test "returns error for unsupported scheme" do
      {:error, message} = HttpGet.execute(%{"url" => "ftp://example.com/file.txt"})

      assert message == "url scheme must be http or https"
    end

    test "returns error when scheme is missing" do
      {:error, message} = HttpGet.execute(%{"url" => "example.com/path"})

      assert message == "url must include scheme (http or https)"
    end

    test "returns error when credentials are included in url" do
      {:error, message} = HttpGet.execute(%{"url" => "http://user:pass@example.com/private"})

      assert message == "url must not include credentials"
    end

    test "fetches URL successfully" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 200, "Hello World")
      end)

      {:ok, result} = HttpGet.execute(%{"url" => "http://localhost:#{bypass.port}/test"})

      assert result.status == 200
      assert result.body == "Hello World"
      assert result.url == "http://localhost:#{bypass.port}/test"
    end

    test "redacts sensitive query parameters in returned url" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        assert conn.query_string == "token=secret-token&visible=ok"
        Plug.Conn.resp(conn, 200, "Hello World")
      end)

      {:ok, result} =
        HttpGet.execute(%{
          "url" => "http://localhost:#{bypass.port}/test?token=secret-token&visible=ok"
        })

      assert result.url == "http://localhost:#{bypass.port}/test?token=redacted&visible=ok"
      refute inspect(result) =~ "secret-token"
    end

    test "handles non-200 status codes" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/not-found", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      {:ok, result} = HttpGet.execute(%{"url" => "http://localhost:#{bypass.port}/not-found"})

      assert result.status == 404
      assert result.body == "Not Found"
    end

    test "truncates long response body" do
      bypass = Bypass.open()

      # Create a body longer than 5000 characters
      long_body = String.duplicate("a", 6000)

      Bypass.expect_once(bypass, "GET", "/long", fn conn ->
        Plug.Conn.resp(conn, 200, long_body)
      end)

      {:ok, result} = HttpGet.execute(%{"url" => "http://localhost:#{bypass.port}/long"})

      assert result.status == 200
      assert String.ends_with?(result.body, "... (truncated)")
      assert String.length(result.body) < 6000
    end

    test "returns error for connection failure" do
      # Use a port that's definitely not listening
      {:error, reason} =
        HttpGet.execute(%{"url" => "http://localhost:1/test?token=secret-token"})

      assert reason == "Could not fetch that URL. Check the address and try again."
      refute reason =~ "secret-token"
      refute reason =~ "Req."
    end

    test "redacts sensitive fields in response body text" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/secret", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"access_token":"secret-token","ok":true}))
      end)

      {:ok, result} = HttpGet.execute(%{"url" => "http://localhost:#{bypass.port}/secret"})

      assert result.body =~ "access_token"
      assert result.body =~ "[redacted]"
      refute result.body =~ "secret-token"
    end

    test "handles JSON response body" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"key": "value"}))
      end)

      {:ok, result} = HttpGet.execute(%{"url" => "http://localhost:#{bypass.port}/json"})

      assert result.status == 200
      # Body could be string or map depending on how Req parses it
      assert result.body != nil
    end
  end
end
