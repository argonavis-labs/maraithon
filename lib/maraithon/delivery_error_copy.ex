defmodule Maraithon.DeliveryErrorCopy do
  @moduledoc """
  Product-safe copy for persisted delivery failures.

  Delivery failures can include provider response bodies, chat identifiers,
  tokens, or internal tuples. Store actionable copy in records so dashboards,
  exports, and admin tooling do not need to defend against raw provider errors.
  """

  @missing_chat "Telegram is not linked yet. Connect Telegram before sending this message."
  @needs_reconnect "Telegram needs reconnecting before delivery can continue."
  @temporarily_unavailable "Telegram is temporarily unavailable. Try again in a minute."
  @timed_out "Delivery timed out. Try again in a minute."
  @generic "Delivery could not be sent. Check the connected channel and try again."

  @legacy_terminal_messages [
    ":missing_chat_id",
    "missing_chat_id",
    ":telegram_not_connected",
    "telegram_not_connected"
  ]

  @terminal_messages [@missing_chat, @needs_reconnect]

  def storage_message(reason) do
    reason
    |> normalize_reason()
    |> classify_reason()
  end

  def terminal_storage_messages do
    @legacy_terminal_messages ++ @terminal_messages
  end

  def terminal?(message) when is_binary(message) do
    String.trim(message) in terminal_storage_messages()
  end

  def terminal?(reason) do
    reason
    |> storage_message()
    |> terminal?()
  end

  defp normalize_reason({:error, reason}), do: normalize_reason(reason)

  defp normalize_reason({:telegram_error, code, description}) do
    {:telegram_error, code, normalize_text(description)}
  end

  defp normalize_reason({:http_status, status, body}) do
    {:http_status, status, normalize_text(body)}
  end

  defp normalize_reason({:http_error, reason}), do: {:http_error, normalize_reason(reason)}
  defp normalize_reason({:exit, reason}), do: {:exit, normalize_reason(reason)}
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason) when is_binary(reason), do: normalize_text(reason)

  defp normalize_reason(reason) do
    reason
    |> inspect(limit: 8)
    |> normalize_text()
  end

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: value |> inspect(limit: 8) |> String.trim()

  defp classify_reason(reason) when reason in ["missing_chat_id", ":missing_chat_id"] do
    @missing_chat
  end

  defp classify_reason(reason)
       when reason in [
              "telegram_not_connected",
              ":telegram_not_connected",
              "not_connected",
              "no_token",
              "no_refresh_token",
              "reauth_required",
              "unauthorized"
            ] do
    @needs_reconnect
  end

  defp classify_reason({:telegram_error, code, description}) do
    cond do
      code in [401, 403] ->
        @needs_reconnect

      code == 400 and terminal_telegram_description?(description) ->
        @needs_reconnect

      code == 429 or code >= 500 ->
        @temporarily_unavailable

      transient_text?(description) ->
        @temporarily_unavailable

      timeout_text?(description) ->
        @timed_out

      true ->
        @generic
    end
  end

  defp classify_reason({:http_status, status, body}) do
    cond do
      status in [401, 403] ->
        @needs_reconnect

      status == 400 and terminal_telegram_description?(body) ->
        @needs_reconnect

      status == 408 or status == 429 or status >= 500 ->
        @temporarily_unavailable

      transient_text?(body) ->
        @temporarily_unavailable

      timeout_text?(body) ->
        @timed_out

      true ->
        @generic
    end
  end

  defp classify_reason({:http_error, reason}), do: classify_reason(reason)
  defp classify_reason({:exit, _reason}), do: @temporarily_unavailable

  defp classify_reason(reason) when is_binary(reason) do
    cond do
      reason == "" -> @generic
      reason in terminal_storage_messages() -> reason
      terminal_telegram_description?(reason) -> @needs_reconnect
      reauth_text?(reason) -> @needs_reconnect
      transient_text?(reason) -> @temporarily_unavailable
      timeout_text?(reason) -> @timed_out
      true -> @generic
    end
  end

  defp classify_reason(_reason), do: @generic

  defp terminal_telegram_description?(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.contains?([
      "bot was blocked",
      "blocked by the user",
      "bot can't initiate",
      "bot can\\'t initiate",
      "chat not found",
      "user is deactivated",
      "bot was kicked"
    ])
  end

  defp terminal_telegram_description?(_text), do: false

  defp reauth_text?(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.contains?(["invalid token", "unauthorized", "reauth", "reconnect"])
  end

  defp reauth_text?(_text), do: false

  defp transient_text?(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.contains?([
      "temporarily unavailable",
      "rate limit",
      "rate_limited",
      "too many requests"
    ])
  end

  defp transient_text?(_text), do: false

  defp timeout_text?(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.contains?(["timeout", "timed out"])
  end

  defp timeout_text?(_text), do: false
end
