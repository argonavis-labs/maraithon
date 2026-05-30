defmodule Maraithon.RunErrorCopy do
  @moduledoc """
  Product-safe copy for persisted run failures.

  Run errors often contain provider response bodies, stack traces, internal
  module names, SQL fragments, or tokens. Persist those raw values for
  debugging, but route user-facing run history and exports through this module.
  """

  @assistant_fallback "Maraithon could not finish that response. Ask for a narrower check or refresh the conversation before continuing."
  @agent_fallback "That run did not complete. Review the last action before running it again."
  @scheduled_task_fallback "That scheduled task did not complete. Review it before running it again."
  @runtime_fallback "Operation did not complete. Check the connection before running it again."

  def assistant_response(nil), do: nil
  def assistant_response(""), do: nil

  def assistant_response(reason) do
    classify(reason,
      fallback: @assistant_fallback,
      internal: @assistant_fallback,
      timeout: "That response took too long. Ask for a narrower check."
    )
  end

  def agent_run(nil), do: nil
  def agent_run(""), do: nil

  def agent_run(reason) do
    classify(reason,
      fallback: @agent_fallback,
      internal: @agent_fallback,
      timeout: "That run took too long. Review the last action before running it again."
    )
  end

  def scheduled_task(nil), do: nil
  def scheduled_task(""), do: nil

  def scheduled_task(reason) do
    classify(reason,
      fallback: @scheduled_task_fallback,
      internal: @scheduled_task_fallback,
      timeout: "That scheduled task took too long. Review it before running it again."
    )
  end

  def runtime_failure(%{source: "job", details: details}) do
    runtime_failure(details,
      fallback:
        "Background work did not report completion. Review the latest status before rerunning it."
    )
  end

  def runtime_failure(%{source: "background_job", details: details}) do
    runtime_failure(details,
      fallback: "Background job did not complete. Review the latest status before rerunning it."
    )
  end

  def runtime_failure(%{source: "effect", details: details}) do
    runtime_failure(details,
      fallback: "Action did not complete. No confirmed change was recorded."
    )
  end

  def runtime_failure(%{details: details}) do
    runtime_failure(details, fallback: @runtime_fallback)
  end

  def runtime_failure(reason) do
    runtime_failure(reason, fallback: @runtime_fallback)
  end

  defp runtime_failure(nil, opts), do: Keyword.fetch!(opts, :fallback)
  defp runtime_failure("", opts), do: Keyword.fetch!(opts, :fallback)

  defp runtime_failure(reason, opts) do
    fallback = Keyword.fetch!(opts, :fallback)

    classify(reason,
      fallback: fallback,
      internal: fallback,
      timeout: "Operation took too long. Check the latest state before running it again."
    )
  end

  defp classify(reason, copy) do
    reason = normalized_reason(reason)

    cond do
      account_connection_error?(reason) ->
        "Connect the missing account before running this again."

      account_reauth_error?(reason) ->
        "Reconnect the account before running this again."

      internal_error?(reason) ->
        Keyword.fetch!(copy, :internal)

      timeout_error?(reason) ->
        Keyword.fetch!(copy, :timeout)

      true ->
        Keyword.fetch!(copy, :fallback)
    end
  end

  defp normalized_reason(reason) when is_binary(reason) do
    String.downcase(reason)
  end

  defp normalized_reason(reason) do
    reason
    |> inspect(limit: 8)
    |> String.downcase()
  end

  defp account_connection_error?(reason) do
    String.contains?(reason, [
      "account_not_connected",
      "not_connected",
      "not configured",
      "not_configured",
      "no_token"
    ])
  end

  defp account_reauth_error?(reason) do
    String.contains?(reason, [
      "expired or revoked",
      "invalid_grant",
      "missing_refresh",
      "oauth_reauth_required",
      "reauth",
      "reconnect",
      "unauthorized"
    ])
  end

  defp internal_error?(reason) do
    String.contains?(reason, [
      "api_failed",
      "db_timeout",
      "http_error",
      "http_status",
      "internal",
      "stacktrace",
      "secret",
      "token",
      "tool_failed"
    ])
  end

  defp timeout_error?(reason) do
    String.contains?(reason, ["timeout", "timed out"])
  end
end
