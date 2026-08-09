defmodule MaraithonWeb.Plugs.CacheRawBodyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias MaraithonWeb.Plugs.CacheRawBody

  describe "read_body/2" do
    test "caches identity bodies and consumes multiple socket chunks" do
      body = String.duplicate("x", 200_000)
      conn = conn(:post, "/api/v1/companion/notes", body)

      assert {:ok, ^body, conn} = CacheRawBody.read_body(conn, [])
      assert conn.assigns.raw_body == body
    end

    test "returns the Plug 413 shape on cumulative compressed overflow" do
      body = String.duplicate("x", CacheRawBody.webhook_compressed_limit() + 1)
      conn = conn(:post, "/webhooks/github", body)

      assert {:more, "", _conn} = CacheRawBody.read_body(conn, [])
    end

    test "applies the inflated ceiling to identity bodies" do
      conn = conn(:post, "/mcp", String.duplicate("x", 600_001))
      assert {:more, "", _conn} = CacheRawBody.read_body(conn, [])
    end

    test "bounds streaming gzip inflation before retaining a zip bomb" do
      inflated = String.duplicate("x", 600_001)
      gzipped = :zlib.gzip(inflated)
      assert byte_size(gzipped) < CacheRawBody.webhook_compressed_limit()

      conn =
        :post
        |> conn("/webhooks/github", gzipped)
        |> put_req_header("content-encoding", "gzip")

      assert {:more, "", _conn} = CacheRawBody.read_body(conn, [])
    end

    test "rejects truncated gzip trailers" do
      gzipped = :zlib.gzip(~s({"hello":"world"}))
      truncated = binary_part(gzipped, 0, byte_size(gzipped) - 2)

      conn =
        :post
        |> conn("/webhooks/github", truncated)
        |> put_req_header("content-encoding", "gzip")

      assert {:error, :invalid_gzip} = CacheRawBody.read_body(conn, [])
    end

    test "rejects malformed gzip and unsupported encoding chains" do
      malformed =
        :post
        |> conn("/webhooks/github", <<0, 1, 2, 3>>)
        |> put_req_header("content-encoding", "gzip")

      assert {:error, :invalid_gzip} = CacheRawBody.read_body(malformed, [])

      for encoding <- ["br", "gzip, identity"] do
        unsupported =
          :post
          |> conn("/webhooks/github", "body")
          |> put_req_header("content-encoding", encoding)

        assert {:error, :unsupported_content_encoding} =
                 CacheRawBody.read_body(unsupported, [])
      end
    end

    test "signed connector cache retains gzip wire bytes while parser receives JSON" do
      body = ~s({"action":"opened"})
      wire_body = :zlib.gzip(body)

      conn =
        :post
        |> conn("/webhooks/github", wire_body)
        |> put_req_header("content-encoding", "gzip")

      assert {:ok, ^body, conn} = CacheRawBody.read_body(conn, [])
      assert conn.assigns.raw_body == wire_body
    end

    test "five MiB inflated Companion payload succeeds under OTP 26" do
      body = Jason.encode!(%{"notes" => [String.duplicate("x", 5 * 1_024 * 1_024)]})
      wire_body = :zlib.gzip(body)

      conn =
        :post
        |> conn("/api/v1/companion/notes", wire_body)
        |> put_req_header("content-encoding", "gzip")

      assert {:ok, ^body, conn} = CacheRawBody.read_body(conn, [])
      assert conn.assigns.raw_body == body
    end
  end
end
