defmodule Maraithon.Push.APNS.HTTP do
  @moduledoc """
  Bounded Finch HTTP/2 transport for APNs, injectable for tests.

  A safe, non-delivery HEAD request warms and verifies the shared HTTP/2
  connection before the notification POST. Only that preflight may retry;
  the external notification request is issued exactly once.
  """

  alias Maraithon.LLM.BoundedResponse
  alias Maraithon.Redaction

  @request_timeout_ms 10_000
  @post_cleanup_grace_ms 1_000
  @preflight_budget_ms 3_000
  @preflight_receive_timeout_ms 1_500
  @preflight_retry_delay_ms 500
  @preflight_attempts 3
  @max_response_body_bytes 8_192
  @max_response_chunks 512

  def post(url, headers, body)
      when is_binary(url) and is_list(headers) and is_binary(body) do
    deadline_ms = System.monotonic_time(:millisecond) + @request_timeout_ms

    with true <- is_pid(Process.whereis(Maraithon.Runtime.ToolCallSupervisor)),
         {:ok, preflight} <- preflight_request(url),
         :ok <- ensure_ready(preflight, @preflight_attempts, preflight_deadline(deadline_ms)),
         remaining_ms when remaining_ms > @post_cleanup_grace_ms <- remaining_ms(deadline_ms) do
      request = Finch.build(:post, url, headers, body)
      receive_timeout_ms = remaining_ms - @post_cleanup_grace_ms

      fn -> stream_request(request, receive_timeout_ms) end
      |> BoundedResponse.run(remaining_ms)
      |> normalize_result()
    else
      {:error, reason} -> {:error, {:before_send, reason}}
      false -> {:error, {:before_send, :supervisor_unavailable}}
      _expired -> {:error, {:before_send, :preflight_timeout}}
    end
  end

  def post(_url, _headers, _body), do: {:error, {:before_send, :invalid_request}}

  defp preflight_request(url) do
    with {:ok, %URI{scheme: scheme, host: host, userinfo: nil} = uri} <- URI.new(url),
         true <- scheme in ["https", "http"] and is_binary(host) and host != "" do
      preflight_url =
        uri
        |> Map.put(:path, "/")
        |> Map.put(:query, nil)
        |> Map.put(:fragment, nil)
        |> URI.to_string()

      {:ok, Finch.build(:head, preflight_url)}
    else
      _invalid -> {:error, :invalid_url}
    end
  end

  defp preflight_deadline(request_deadline_ms) do
    min(
      request_deadline_ms,
      System.monotonic_time(:millisecond) + @preflight_budget_ms
    )
  end

  defp ensure_ready(_request, 0, _deadline_ms), do: {:error, :preflight_failed}

  defp ensure_ready(request, attempts_left, deadline_ms) do
    case remaining_ms(deadline_ms) do
      remaining when remaining <= 0 ->
        {:error, :preflight_timeout}

      remaining ->
        timeout = min(remaining, @preflight_receive_timeout_ms)

        case preflight(request, timeout) do
          :ok ->
            :ok

          {:error, _reason} when attempts_left > 1 ->
            wait_before_preflight_retry(deadline_ms)
            ensure_ready(request, attempts_left - 1, deadline_ms)

          {:error, reason} ->
            {:error, preflight_failure_code(reason)}
        end
    end
  end

  defp preflight(request, timeout_ms) do
    request_fun = fn ->
      Finch.stream_while(
        request,
        finch_name(),
        :waiting,
        fn
          {:status, _status}, _acc -> {:halt, :ready}
          _event, acc -> {:cont, acc}
        end,
        receive_timeout: max(timeout_ms - 100, 1)
      )
    end

    case BoundedResponse.run(request_fun, timeout_ms) do
      {:ok, :ready} -> :ok
      {:error, reason, _acc} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_preflight_response}
    end
  rescue
    _exception -> {:error, :preflight_exception}
  catch
    _kind, _reason -> {:error, :preflight_exit}
  end

  defp wait_before_preflight_retry(deadline_ms) do
    wait_ms = min(@preflight_retry_delay_ms, max(remaining_ms(deadline_ms), 0))

    if wait_ms > 0 do
      receive do
      after
        wait_ms -> :ok
      end
    else
      :ok
    end
  end

  defp preflight_failure_code(reason) do
    case Redaction.error_class(reason) do
      "unknown_error" -> :preflight_failed
      failure_code -> {:preflight_failed, failure_code}
    end
  end

  defp remaining_ms(deadline_ms),
    do: deadline_ms - System.monotonic_time(:millisecond)

  defp stream_request(request, timeout_ms) do
    initial = %{status: nil, chunks: [], bytes: 0, chunk_count: 0, overflow?: false}

    Finch.stream_while(
      request,
      finch_name(),
      initial,
      &collect/2,
      receive_timeout: timeout_ms
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

  defp finch_name do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:finch_name, Maraithon.Push.Finch)
  end

  defp normalize_result({:ok, %{overflow?: false, status: status} = acc})
       when is_integer(status) do
    {:ok, status, acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  # Once APNs has returned an HTTP status, delivery is conclusive even if its
  # small diagnostic body overflowed or the response stream ended early. Keep
  # the status so callers can safely classify acceptance versus rejection.
  defp normalize_result({:ok, %{status: status}}) when is_integer(status),
    do: {:ok, status, ""}

  defp normalize_result({:error, _reason, %{status: status}}) when is_integer(status),
    do: {:ok, status, ""}

  defp normalize_result({:error, %{reason: :timeout}}), do: {:error, :timeout}
  defp normalize_result({:error, reason, _acc}), do: {:error, reason}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(_result), do: {:error, :invalid_response}
end
