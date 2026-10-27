defmodule MaraithonWeb.MobileConditional do
  @moduledoc """
  Conditional GET (ETag / 304) support for mobile collection index actions.

  Controllers compute a cheap collection version (one aggregate query per
  user collection) before running the expensive list query + serialization.
  When the client's `if-none-match` matches, we short-circuit with a 304 and
  never touch the list query.
  """

  import Plug.Conn

  @doc """
  Builds a strong quoted ETag from a `{count, max_updated_at}` collection
  version tuple, e.g. `"todos-42-1753900000000000"`. Deterministic for an
  unchanged collection; any row insert/update/delete changes count or
  max(updated_at) and therefore the tag. `nil` max (empty collection) hashes
  to 0.
  """
  def collection_etag(prefix, {count, max_updated_at}) when is_binary(prefix) do
    ~s("#{prefix}-#{count || 0}-#{version_micros(max_updated_at)}")
  end

  @doc """
  Responds 304 with an empty body when the request's `if-none-match` equals
  `etag`; otherwise sets the ETag response headers and calls `fun` with the
  conn to render the full response. 304 responses never run `fun`.
  """
  def with_collection_etag(conn, etag, fun) when is_binary(etag) and is_function(fun, 1) do
    conn =
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", "private, no-cache")

    if etag_matches?(conn, etag) do
      send_resp(conn, :not_modified, "")
    else
      fun.(conn)
    end
  end

  defp etag_matches?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.any?(&(&1 == etag))
  end

  defp version_micros(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp version_micros(_nil), do: 0
end
