defmodule MaraithonWeb.OAuthFlashCopy do
  @moduledoc false

  @technical_message_markers [
    "dbconnection",
    "ecto.",
    "http_status",
    "internal",
    "oauth_tokens",
    "postgrex",
    "stacktrace",
    "token=",
    "traceback"
  ]

  @connected_fallback "App connected."
  @error_fallback "App connection did not finish. Reopen the connector and complete sign-in."

  def message("connected", message), do: safe_message(message, @connected_fallback)
  def message("error", message), do: safe_message(message, @error_fallback)
  def message(_status, _message), do: @error_fallback

  defp safe_message(message, fallback) when is_binary(message) do
    trimmed = String.trim(message)

    cond do
      trimmed == "" -> fallback
      technical_message?(trimmed) -> fallback
      true -> trimmed
    end
  end

  defp safe_message(_message, fallback), do: fallback

  defp technical_message?(message) do
    lower = String.downcase(message)

    Enum.any?(@technical_message_markers, &String.contains?(lower, &1)) or
      String.contains?(message, ["{", "}", "=>"])
  end
end
