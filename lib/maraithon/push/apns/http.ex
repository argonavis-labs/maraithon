defmodule Maraithon.Push.APNS.HTTP do
  @moduledoc """
  Bounded Finch HTTP/2 transport for APNs, injectable for tests.
  """

  alias Maraithon.LLM.BoundedResponse

  @finch Maraithon.Push.Finch
  @request_timeout_ms 10_000
  @max_response_body_bytes 8_192
  @max_response_chunks 512

  def post(url, headers, body) do
    request = Finch.build(:post, url, headers, body)

    fn -> stream_request(request) end
    |> BoundedResponse.run(@request_timeout_ms)
    |> normalize_result()
  end

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
  defp normalize_result({:error, %{reason: :timeout}}), do: {:error, :timeout}
  defp normalize_result({:error, reason, _acc}), do: {:error, reason}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(_result), do: {:error, :invalid_response}
end
