defmodule Maraithon.TestSupport.BoundedHTTPTimeout do
  @moduledoc false

  @request_timeout_ms 750
  @chunk_interval_ms 25
  @max_chunks 120

  def expect_once(bypass, path) do
    Bypass.expect_once(bypass, "GET", path, fn conn ->
      Bypass.pass(bypass)

      conn
      |> Plug.Conn.send_chunked(200)
      |> stream_until_closed(@max_chunks)
    end)
  end

  def get(bypass, path) do
    Maraithon.HTTP.get("http://localhost:#{bypass.port}#{path}", [],
      receive_timeout: 5_000,
      request_timeout: @request_timeout_ms,
      log_failures?: false
    )
  end

  defp stream_until_closed(conn, 0), do: conn

  defp stream_until_closed(conn, remaining) do
    receive do
    after
      @chunk_interval_ms -> :ok
    end

    case chunk(conn) do
      {:ok, conn} -> stream_until_closed(conn, remaining - 1)
      :closed -> conn
    end
  end

  defp chunk(conn) do
    case Plug.Conn.chunk(conn, ".") do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> :closed
    end
  catch
    :exit, _reason -> :closed
  end
end
