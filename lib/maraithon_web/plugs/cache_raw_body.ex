defmodule MaraithonWeb.Plugs.CacheRawBody do
  @moduledoc """
  Custom body reader that caches the raw request body for signature
  verification and transparently gunzips bodies sent with
  `Content-Encoding: gzip`.

  Webhook signature verification requires the exact bytes received, not a
  re-encoded version. The macOS companion app, by contrast, gzips every
  ingest payload to cut bandwidth, and expects the server to decompress
  before parsing. Doing both jobs in one body reader keeps the endpoint
  pipeline at the single `Plug.Parsers` plug it already has — and means
  the `:raw_body` assign is always the bytes the JSON parser actually
  sees, so signature verification on a gzipped payload would still match
  what callers signed against the inflated body.

  ## Usage

  Configure Plug.Parsers in your endpoint:

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        body_reader: {MaraithonWeb.Plugs.CacheRawBody, :read_body, []},
        json_decoder: Phoenix.json_library()

  Then access the raw body in controllers:

      raw_body = conn.assigns[:raw_body]
  """

  @doc """
  Reads the request body, inflates it if `Content-Encoding: gzip` is set,
  and caches the (post-inflate) bytes in `conn.assigns[:raw_body]`.

  This function is designed to be used with Plug.Parsers' :body_reader option.
  """
  def read_body(conn, opts) do
    case read_full_body(conn, opts, "") do
      {:ok, body, conn} ->
        case maybe_gunzip(conn, body) do
          {:ok, inflated} ->
            conn = Plug.Conn.assign(conn, :raw_body, inflated)
            {:ok, inflated, conn}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_full_body(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, acc <> body, conn}
      {:more, partial, conn} -> read_full_body(conn, opts, acc <> partial)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_gunzip(conn, body) do
    if gzip_encoded?(conn) and body != "" do
      try do
        {:ok, :zlib.gunzip(body)}
      rescue
        ErlangError -> {:error, :invalid_gzip}
      end
    else
      {:ok, body}
    end
  end

  defp gzip_encoded?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-encoding")
    |> Enum.any?(fn value ->
      value
      |> String.downcase()
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.member?("gzip")
    end)
  end
end
