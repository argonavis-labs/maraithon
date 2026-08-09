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

    test "five MiB high-entropy Companion M4A payload succeeds under OTP 26" do
      audio_size = 5 * 1_024 * 1_024

      # A deterministic AES-CTR keystream models already-compressed M4A bytes.
      # Unlike repeated text, its base64 form cannot collapse below the former
      # four-MiB compressed request ceiling.
      audio =
        :crypto.crypto_one_time(
          :aes_256_ctr,
          :binary.copy(<<0x42>>, 32),
          <<0::128>>,
          :binary.copy(<<0>>, audio_size),
          true
        )

      body =
        Jason.encode!(%{
          "device_id" => "companion-body-limit-test",
          "source" => "voice_memos",
          "voice_memos" => [
            %{
              "guid" => "deterministic-five-mib-m4a",
              "audio_mime" => "audio/m4a",
              "audio_bytes" => Base.encode64(audio)
            }
          ]
        })

      wire_body = :zlib.gzip(body)
      assert byte_size(audio) == audio_size
      assert byte_size(wire_body) > 4 * 1_024 * 1_024
      assert byte_size(wire_body) < 8 * 1_024 * 1_024
      assert byte_size(body) < 8 * 1_024 * 1_024

      conn =
        :post
        |> conn("/api/v1/companion/voice-memos", wire_body)
        |> put_req_header("content-encoding", "gzip")

      assert {:ok, ^body, conn} = CacheRawBody.read_body(conn, [])
      assert conn.assigns.raw_body == body
    end
  end
end
