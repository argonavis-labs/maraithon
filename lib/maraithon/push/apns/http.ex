defmodule Maraithon.Push.APNS.HTTP do
  @moduledoc """
  Thin Finch HTTP/2 transport for APNs, injectable for tests via
  `config :maraithon, :apns, http_module: ...`.
  """

  @finch Maraithon.Push.Finch
  @request_timeout_ms 15_000

  def post(url, headers, body) do
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, @finch, receive_timeout: @request_timeout_ms) do
      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:ok, status, response_body}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
