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
  @service_problem "service problem"
  @source_check_failed "source check failed"

  def reason({:error, reason}), do: reason(reason)
  def reason({:token_refresh_failed, reason}), do: reason(reason)
  def reason({:revocation_failed, reason}), do: reason(reason)

  def reason({:http_status, status, _body}) when status in [401, 403], do: "needs reconnect"
  def reason({:http_status, 408, _body}), do: "timed out"
  def reason({:http_status, 429, _body}), do: "rate limited"
  def reason({:http_status, status, _body}) when status >= 500, do: @service_problem

  def reason({:http_status, _status, _body}), do: @source_check_failed
  def reason({:rate_limited, _body}), do: "rate limited"
  def reason({:http_error, _reason}), do: @service_problem
  def reason({:exit, _reason}), do: "interrupted"

  def reason(:no_token), do: "not connected"
  def reason(:not_connected), do: "not connected"
  def reason(:unauthorized), do: "needs reconnect"
  def reason(:reauth_required), do: "needs reconnect"
  def reason(:no_refresh_token), do: "needs reconnect"
  def reason(:timeout), do: "timed out"
  def reason(:slow_fetch), do: "slow response"
  def reason(:interrupted), do: "interrupted"
  def reason(:temporary_failure), do: @service_problem

  def reason(%_{}), do: @service_problem

  def reason(value) when is_binary(value) do
    value
    |> String.downcase()
    |> classify_text()
  end

  def reason(_value), do: @source_check_failed

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

      String.contains?(text, ["429", "rate_limited"]) ->
        "rate limited"

      String.contains?(text, [
        "api_failed",
        "db_timeout",
        "http_error",
        "http request failed",
        "http_status",
        "internal",
        "temporarily unavailable",
        "tool_failed"
      ]) ->
        @service_problem

      Regex.match?(~r/\b5\d\d\b/, text) ->
        @service_problem

      String.contains?(text, ["timeout", "timed out"]) ->
        "timed out"

      true ->
        @source_check_failed
    end
  end
end
