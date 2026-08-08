defmodule Maraithon.Push.APNS.HTTP do
  @moduledoc """
  Bounded Finch HTTP/2 transport for APNs, injectable for tests.

  APNs and intermediary NATs can silently discard a long-idle HTTP/2 socket.
  Finch keeps that socket while Mint still considers it writable, so the next
  request can consume its entire timeout before discovering the dead path.
  APNs sends are at-most-once and cannot be retried after that boundary.

  Keep bursts efficient, but serialize them per Apple destination and recycle
  a connection after one minute without a successful HTTP response. This is a
  conservative Finch 0.20 workaround until a reviewed HTTP/2 PING upgrade.
  A transport failure also retires the connection so the next device gets a
  fresh socket rather than inheriting the failed path.
  """

  alias Maraithon.LLM.BoundedResponse

  require Logger

  @finch Maraithon.Push.Finch
  @request_timeout_ms 10_000
  @max_response_body_bytes 8_192
  @max_response_chunks 512
  @pool_idle_ttl_ms 60_000
  @pool_activity_key {__MODULE__, :pool_last_activity_at}

  def post(url, headers, body) do
    with {:ok, destination} <- pool_destination(url) do
      managed_request(destination, fn ->
        request = Finch.build(:post, url, headers, body)

        fn -> stream_request(request) end
        |> BoundedResponse.run(@request_timeout_ms)
        |> normalize_result()
      end)
    end
  end

  @doc false
  def managed_request(
        destination,
        request,
        stop_pool \\ &stop_pool/1,
        monotonic_ms \\ &monotonic_ms/0
      )
      when is_tuple(destination) and tuple_size(destination) == 3 and is_function(request, 0) and
             is_function(stop_pool, 1) and is_function(monotonic_ms, 0) do
    lock_id = {{__MODULE__, destination}, self()}

    case :global.trans(
           lock_id,
           fn ->
             recycle_idle_pool(destination, stop_pool, monotonic_ms.())
             run_managed_request(destination, request, stop_pool, monotonic_ms)
           end,
           [node()]
         ) do
      :aborted -> {:error, :pool_lock_unavailable}
      result -> result
    end
  end

  defp run_managed_request(destination, request, stop_pool, monotonic_ms) do
    result = request.()

    case result do
      {:ok, status, _body} when is_integer(status) ->
        :persistent_term.put(activity_key(destination), monotonic_ms.())

      {:error, _reason} ->
        retire_pool(destination, stop_pool)

      _other ->
        :ok
    end

    result
  rescue
    exception ->
      retire_pool(destination, stop_pool)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      retire_pool(destination, stop_pool)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp recycle_idle_pool(destination, stop_pool, now) do
    case :persistent_term.get(activity_key(destination), nil) do
      last_activity when is_integer(last_activity) and now - last_activity < @pool_idle_ttl_ms ->
        :ok

      _missing_or_idle ->
        Logger.debug("Recycling idle APNs HTTP/2 pool",
          transport_class: "idle_pool_recycle"
        )

        retire_pool(destination, stop_pool)
    end
  end

  defp retire_pool(destination, stop_pool) do
    _ = stop_pool.(destination)
    _ = :persistent_term.erase(activity_key(destination))
    :ok
  end

  defp stop_pool(destination) do
    _ = Finch.stop_pool(@finch, destination)
    :ok
  end

  defp activity_key(destination), do: {@pool_activity_key, destination}
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc false
  def pool_destination(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: port}
      when is_binary(host) and byte_size(host) > 0 and byte_size(host) <= 255 ->
        {:ok, {:https, host, port || 443}}

      _invalid ->
        {:error, :invalid_url}
    end
  end

  def pool_destination(_url), do: {:error, :invalid_url}

  defp stream_request(request) do
    initial = %{status: nil, chunks: [], bytes: 0, chunk_count: 0, overflow?: false}

    Finch.stream_while(
      request,
      @finch,
      initial,
      &collect/2,
      receive_timeout: @request_timeout_ms
    )
  end

  defp collect({:status, status}, acc), do: {:cont, %{acc | status: status}}
  defp collect({:headers, _headers}, acc), do: {:cont, acc}
  defp collect({:trailers, _trailers}, acc), do: {:cont, acc}

  defp collect({:data, data}, acc) when is_binary(data) do
    bytes = acc.bytes + byte_size(data)
    chunk_count = acc.chunk_count + 1

    if bytes > @max_response_body_bytes or chunk_count > @max_response_chunks do
      {:halt, %{acc | chunks: [], bytes: bytes, chunk_count: chunk_count, overflow?: true}}
    else
      {:cont, %{acc | chunks: [data | acc.chunks], bytes: bytes, chunk_count: chunk_count}}
    end
  end

  defp collect(_event, acc), do: {:halt, %{acc | overflow?: true, chunks: []}}

  defp normalize_result({:ok, %{overflow?: false, status: status} = acc})
       when is_integer(status) do
    {:ok, status, acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp normalize_result({:ok, %{overflow?: true}}), do: {:error, :response_body_too_large}

  defp normalize_result({:error, %{reason: reason}, _acc}) when is_atom(reason),
    do: {:error, reason}

  defp normalize_result({:error, %{reason: reason}}) when is_atom(reason),
    do: {:error, reason}

  defp normalize_result({:error, reason, _acc}), do: {:error, reason}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(_result), do: {:error, :invalid_response}
end
