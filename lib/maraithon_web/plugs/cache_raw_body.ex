defmodule MaraithonWeb.Plugs.CacheRawBody do
  @moduledoc """
  Bounded request-body reader for JSON and urlencoded endpoint parsing.

  The reader enforces cumulative compressed and inflated limits, supports only
  identity and a single gzip content encoding, and preserves the received wire
  bytes for connectors whose signatures cover those bytes.
  """

  @webhook_compressed_limit 600_000
  @webhook_inflated_limit 600_000
  @tool_compressed_limit 1_048_576
  @tool_inflated_limit 600_000
  @default_compressed_limit 8_388_608
  @default_inflated_limit 8_388_608
  @socket_read_size 64_000
  @socket_read_timeout 5_000
  @max_read_steps 4_096
  @max_inflate_steps 4_096

  @signed_wire_paths MapSet.new([
                       "/webhooks/github",
                       "/webhooks/slack",
                       "/webhooks/whatsapp",
                       "/webhooks/linear"
                     ])

  @doc false
  def webhook_compressed_limit, do: @webhook_compressed_limit

  @doc """
  Reads and optionally inflates a request body within route-specific limits.

  Oversized input returns Plug's `{:more, _, conn}` body-reader shape so
  `Plug.Parsers` consistently responds with 413. Malformed or unsupported
  encodings return `{:error, reason}` and therefore a 400.
  """
  def read_body(conn, opts) do
    {compressed_limit, inflated_limit} = limits(conn.request_path)

    case read_full_body(conn, opts, compressed_limit, [], 0, 0) do
      {:ok, wire_body, conn} ->
        with {:ok, encoding} <- content_encoding(conn),
             {:ok, body} <- decode_body(encoding, wire_body, inflated_limit) do
          raw_body = if signed_wire_path?(conn.request_path), do: wire_body, else: body
          conn = Plug.Conn.assign(conn, :raw_body, raw_body)
          {:ok, body, conn}
        else
          {:too_large, _reason} -> {:more, "", conn}
          {:error, reason} -> {:error, reason}
        end

      {:too_large, conn} ->
        {:more, "", conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_full_body(conn, _opts, _maximum, _chunks, _total, steps)
       when steps >= @max_read_steps,
       do: {:too_large, conn}

  defp read_full_body(conn, opts, maximum, chunks, total, steps) do
    remaining = maximum - total
    read_size = if remaining > 0, do: min(remaining, @socket_read_size), else: 1

    read_opts =
      opts
      |> Keyword.put(:length, read_size)
      |> Keyword.put(:read_length, read_size)
      |> Keyword.put(:read_timeout, @socket_read_timeout)

    case Plug.Conn.read_body(conn, read_opts) do
      {:ok, chunk, conn} ->
        retain_wire_chunk(chunk, conn, maximum, chunks, total, :done, opts, steps)

      {:more, chunk, conn} ->
        retain_wire_chunk(chunk, conn, maximum, chunks, total, :more, opts, steps)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retain_wire_chunk(chunk, conn, maximum, chunks, total, continuation, opts, steps)
       when is_binary(chunk) do
    size = byte_size(chunk)

    if size > maximum - total do
      {:too_large, conn}
    else
      chunks = if size == 0, do: chunks, else: [chunk | chunks]
      total = total + size

      case continuation do
        :done -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), conn}
        :more -> read_full_body(conn, opts, maximum, chunks, total, steps + 1)
      end
    end
  end

  defp content_encoding(conn) do
    case Plug.Conn.get_req_header(conn, "content-encoding") do
      [] -> {:ok, :identity}
      [value] -> parse_content_encoding(value)
      _multiple -> {:error, :unsupported_content_encoding}
    end
  end

  defp parse_content_encoding(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "identity" -> {:ok, :identity}
      "gzip" -> {:ok, :gzip}
      _unsupported_or_chain -> {:error, :unsupported_content_encoding}
    end
  end

  defp decode_body(:identity, body, maximum) do
    if byte_size(body) <= maximum,
      do: {:ok, body},
      else: {:too_large, :inflated_body_too_large}
  end

  defp decode_body(:gzip, body, maximum), do: inflate_gzip(body, maximum)

  defp inflate_gzip(body, maximum) do
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream, 31, :reset)
      drain_inflate(stream, body, maximum, [], 0)
    rescue
      ErlangError -> {:error, :invalid_gzip}
      MatchError -> {:error, :invalid_gzip}
    catch
      _kind, _reason -> {:error, :invalid_gzip}
    after
      :zlib.close(stream)
    end
  end

  defp drain_inflate(_stream, _input, _remaining, _chunks, steps)
       when steps >= @max_inflate_steps,
       do: {:error, :invalid_gzip}

  defp drain_inflate(stream, input, remaining, chunks, steps) do
    case :zlib.safeInflate(stream, input) do
      {:continue, output} ->
        with {:ok, chunks, remaining} <- retain_inflated_chunk(output, chunks, remaining) do
          drain_inflate(stream, [], remaining, chunks, steps + 1)
        end

      {:finished, output} ->
        with {:ok, chunks, _remaining} <- retain_inflated_chunk(output, chunks, remaining),
             :ok <- :zlib.inflateEnd(stream) do
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
        else
          {:too_large, reason} -> {:too_large, reason}
          _invalid -> {:error, :invalid_gzip}
        end
    end
  end

  defp retain_inflated_chunk(output, chunks, remaining) do
    size = IO.iodata_length(output)

    if size > remaining do
      {:too_large, :inflated_body_too_large}
    else
      chunks = if size == 0, do: chunks, else: [output | chunks]
      {:ok, chunks, remaining - size}
    end
  end

  defp limits(path) when is_binary(path) do
    cond do
      path == "/webhooks" or String.starts_with?(path, "/webhooks/") ->
        {@webhook_compressed_limit, @webhook_inflated_limit}

      path in ["/mcp", "/api/v1/control"] ->
        {@tool_compressed_limit, @tool_inflated_limit}

      true ->
        {@default_compressed_limit, @default_inflated_limit}
    end
  end

  defp signed_wire_path?(path), do: MapSet.member?(@signed_wire_paths, path)
end
