defmodule Maraithon.TelegramAssistant.ProviderWriteOutcome do
  @moduledoc false

  @max_provider_body_bytes 4_096

  # Telegram has emitted both the short and expanded forms over time. Equality
  # is intentional: a different 400 must remain visible to the durable caller.
  @message_not_modified_descriptions [
    "bad request: message is not modified",
    "bad request: message is not modified: specified new message content and reply markup are exactly the same as a current content and reply markup of the message",
    "bad request: message is not modified: specified new message content and reply markup were exactly the same as a current content and reply markup of the message"
  ]

  @drained_callback_descriptions [
    "bad request: query is too old and response timeout expired or query id is invalid",
    "bad request: query id is invalid"
  ]

  @ambiguous_transport_reasons [
    :closed,
    :connection_closed,
    :econnreset,
    :recv_timeout,
    :request_timeout,
    :socket_closed_remotely,
    :timeout,
    :unexpected_eof,
    :unexpected_response
  ]

  # Maraithon.HTTP deliberately reduces exceptions to a closed class before
  # returning them. These are the classes which mean that a request may have
  # reached Telegram even though its response did not reach us.
  @ambiguous_http_error_classes [
    "Elixir.Mint.TransportError",
    "Elixir.Req.TransportError",
    "Elixir.Task.TimeoutError",
    "Mint.TransportError",
    "Req.TransportError",
    "closed",
    "connection_closed",
    "econnreset",
    "recv_timeout",
    "request_timeout",
    "socket_closed_remotely",
    "timeout",
    "unexpected_eof",
    "unexpected_response"
  ]

  def edit_terminal_drained?(reason) do
    match?(
      {400, description} when description in @message_not_modified_descriptions,
      telegram_failure(reason)
    )
  end

  def callback_terminal_drained?(reason) do
    match?(
      {400, description} when description in @drained_callback_descriptions,
      telegram_failure(reason)
    )
  end

  # A timeout or lost/unparseable response can happen after Telegram accepted
  # the write. Those outcomes must not be retried automatically.
  def ambiguous_write_error?(reason) when reason in @ambiguous_transport_reasons, do: true

  def ambiguous_write_error?({:http_error, error_class}) when is_binary(error_class),
    do: error_class in @ambiguous_http_error_classes

  def ambiguous_write_error?({tag, reason})
      when tag in [:error, :transport, :transport_error, :request_error] do
    ambiguous_write_error?(reason)
  end

  def ambiguous_write_error?({tag, _detail, reason})
      when tag in [:error, :transport, :transport_error, :request_error] do
    ambiguous_write_error?(reason)
  end

  def ambiguous_write_error?(%{reason: reason}), do: ambiguous_write_error?(reason)
  def ambiguous_write_error?(%{"reason" => reason}), do: ambiguous_write_error?(reason)
  def ambiguous_write_error?(_reason), do: false

  # Persist only this closed vocabulary. Provider descriptions can contain
  # user text and transport exceptions can contain credentials or URLs.
  def error_fields(reason) do
    cond do
      ambiguous_write_error?(reason) ->
        %{"error_class" => "transport", "error_code" => "response_lost"}

      provider_status(reason) == 429 ->
        %{"error_class" => "provider_rejected", "error_code" => "rate_limited"}

      provider_status(reason) in [401, 403] ->
        %{"error_class" => "provider_rejected", "error_code" => "auth_or_forbidden"}

      provider_status(reason) == 400 ->
        %{"error_class" => "provider_rejected", "error_code" => "bad_request"}

      status = provider_status(reason) ->
        if status >= 500 and status <= 599 do
          %{"error_class" => "provider_unavailable", "error_code" => "server_error"}
        else
          %{"error_class" => "provider_error", "error_code" => "unexpected_status"}
        end

      true ->
        %{"error_class" => "provider_error", "error_code" => "unknown_provider_error"}
    end
  end

  def local_checkpoint_error_fields do
    %{"error_class" => "local_checkpoint", "error_code" => "receipt_not_committed"}
  end

  def expired_write_error_fields do
    %{"error_class" => "local_checkpoint", "error_code" => "write_owner_expired"}
  end

  def invalid_response_error_fields do
    %{"error_class" => "provider_error", "error_code" => "invalid_provider_result"}
  end

  def draft_generation_error_fields do
    %{"error_class" => "draft_generation", "error_code" => "generation_failed"}
  end

  defp provider_status(reason) do
    case telegram_failure(reason) do
      {status, _description} -> status
      nil -> http_status(reason)
    end
  end

  defp http_status({:http_status, status, _body}) when is_integer(status), do: status
  defp http_status(_reason), do: nil

  defp telegram_failure({:telegram_error, status, description})
       when is_integer(status) and is_binary(description) and
              byte_size(description) <= @max_provider_body_bytes do
    {status, normalize_description(description)}
  end

  # Maraithon.HTTP returns non-2xx Telegram JSON as an http_status tuple. Parse
  # only a small bounded body and accept only the Bot API's exact error shape.
  defp telegram_failure({:http_status, status, body})
       when is_integer(status) and is_binary(body) and byte_size(body) <= @max_provider_body_bytes do
    case Jason.decode(body) do
      {:ok, %{"ok" => false, "error_code" => ^status, "description" => description}}
      when is_binary(description) ->
        {status, normalize_description(description)}

      _other ->
        nil
    end
  end

  defp telegram_failure(_reason), do: nil

  defp normalize_description(description) do
    description
    |> String.trim()
    |> String.downcase()
  end
end
