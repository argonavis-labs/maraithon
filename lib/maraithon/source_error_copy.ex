defmodule Maraithon.SourceErrorCopy do
  @moduledoc """
  Product-safe copy for connected-source availability failures.

  Source tooling can fail with provider bodies, OAuth internals, HTTP client
  structs, or local process exits. Those details are useful in logs, but not in
  assistant prompt context or user-visible source review results.
  """

  @doc """
  Returns a short, user-safe availability reason.
  """
  def reason({:error, reason}), do: reason(reason)
  def reason({:token_refresh_failed, reason}), do: reason(reason)
  def reason({:revocation_failed, reason}), do: reason(reason)

  def reason({:http_status, status, _body}) when status in [401, 403], do: "needs reconnect"

  def reason({:http_status, status, _body})
      when status in [408, 409, 425, 429] or status >= 500,
      do: "temporarily unavailable"

  def reason({:http_status, _status, _body}), do: "unavailable"
  def reason({:rate_limited, _body}), do: "temporarily unavailable"
  def reason({:http_error, _reason}), do: "temporarily unavailable"
  def reason({:exit, _reason}), do: "interrupted"

  def reason(:no_token), do: "not connected"
  def reason(:not_connected), do: "not connected"
  def reason(:unauthorized), do: "needs reconnect"
  def reason(:reauth_required), do: "needs reconnect"
  def reason(:no_refresh_token), do: "needs reconnect"
  def reason(:timeout), do: "timed out"
  def reason(:slow_fetch), do: "slow response"
  def reason(:interrupted), do: "interrupted"
  def reason(:temporary_failure), do: "temporarily unavailable"

  def reason(%_{}), do: "temporarily unavailable"

  def reason(value) when is_binary(value) do
    value
    |> String.downcase()
    |> classify_text()
  end

  def reason(_value), do: "temporarily unavailable"

  defp classify_text(text) do
    cond do
      String.contains?(text, [
        "account_not_connected",
        "not_connected",
        "no_token",
        "workspace_not_connected"
      ]) ->
        "not connected"

      String.contains?(text, [
        "expired or revoked",
        "invalid_grant",
        "missing_refresh",
        "oauth_reauth_required",
        "reauth",
        "reconnect",
        "unauthorized"
      ]) ->
        "needs reconnect"

      String.contains?(text, [
        "429",
        "api_failed",
        "db_timeout",
        "http_error",
        "http_status",
        "internal",
        "rate_limited",
        "tool_failed"
      ]) ->
        "temporarily unavailable"

      Regex.match?(~r/\b5\d\d\b/, text) ->
        "temporarily unavailable"

      String.contains?(text, ["timeout", "timed out"]) ->
        "timed out"

      true ->
        "temporarily unavailable"
    end
  end
end
