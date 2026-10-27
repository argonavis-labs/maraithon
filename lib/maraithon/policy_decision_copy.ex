defmodule Maraithon.PolicyDecisionCopy do
  @moduledoc """
  Sanitizes tool-policy decisions before they leave product-facing APIs.

  Raw policy decisions can include tool identifiers, argument names, or caller
  supplied messages. Keep the stable decision shape, but only expose copy and
  metadata that are useful to a client UI.
  """

  alias Maraithon.Normalization

  @fallback_message "Action did not complete. No confirmed change was recorded."
  @fallback_reason_code "tool_failed"

  @safe_metadata_keys MapSet.new(~w(
    agent_policy_applied
    confirmation_required
    destructive
    idempotent
    read_only
    side_effect
    surface
    user_required
  ))

  @technical_markers [
    "api key",
    "api_key",
    "bearer ",
    "clienterror",
    "dbconnection",
    "decode",
    "httpoison",
    "http ",
    "http_",
    "json",
    "nsurlerrordomain",
    "password",
    "postgres",
    "postgrex",
    "req_",
    "runtimeerror",
    "secret",
    "servererror",
    "stacktrace",
    "token",
    "traceback",
    "upstream"
  ]

  def sanitize(decision, opts \\ [])

  def sanitize(decision, opts) when is_map(decision) do
    fallback_message = Keyword.get(opts, :fallback_message, @fallback_message)
    fallback_reason_code = Keyword.get(opts, :fallback_reason_code, @fallback_reason_code)
    decision = Normalization.stringify_keys(decision)
    reason_code = safe_reason_code(Map.get(decision, "reason_code"), fallback_reason_code)

    %{}
    |> maybe_put("status", safe_status(Map.get(decision, "status")))
    |> Map.put("reason_code", reason_code)
    |> Map.put(
      "message",
      safe_message(reason_code, Map.get(decision, "message"), fallback_message)
    )
    |> Map.put("metadata", safe_metadata(Map.get(decision, "metadata", %{})))
  end

  def sanitize(_decision, opts) do
    fallback_message = Keyword.get(opts, :fallback_message, @fallback_message)
    fallback_reason_code = Keyword.get(opts, :fallback_reason_code, @fallback_reason_code)

    %{
      "reason_code" => fallback_reason_code,
      "message" => fallback_message,
      "metadata" => %{}
    }
  end

  def message(decision, opts \\ []) do
    decision
    |> sanitize(opts)
    |> Map.get("message", Keyword.get(opts, :fallback_message, @fallback_message))
  end

  defp safe_reason_code(value, fallback) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^[a-z0-9_]{1,80}$/, value) do
      value
    else
      fallback
    end
  end

  defp safe_reason_code(_value, fallback), do: fallback

  defp safe_status(value) when is_binary(value) do
    case String.trim(value) do
      status when status in ["allow", "deny", "needs_confirmation", "allowed", "denied"] ->
        status

      _ ->
        nil
    end
  end

  defp safe_status(_value), do: nil

  defp safe_message("unknown_tool", _message, _fallback), do: "Action is not available."

  defp safe_message("confirmation_required", _message, _fallback),
    do: "Confirm this action before it runs."

  defp safe_message("invalid_user_context", _message, _fallback) do
    "Sign in again so Maraithon can confirm the account."
  end

  defp safe_message(_reason_code, message, fallback) when is_binary(message) do
    message = String.trim(message)

    if safe_freeform_message?(message) do
      message
    else
      fallback
    end
  end

  defp safe_message(_reason_code, _message, fallback), do: fallback

  defp safe_metadata(metadata) when is_map(metadata) do
    metadata
    |> Normalization.stringify_keys()
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if MapSet.member?(@safe_metadata_keys, key) do
        case safe_metadata_value(value) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      else
        acc
      end
    end)
  end

  defp safe_metadata(_metadata), do: %{}

  defp safe_metadata_value(value) when is_boolean(value), do: {:ok, value}

  defp safe_metadata_value(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^[a-z0-9_:-]{1,80}$/, value) do
      {:ok, value}
    else
      :error
    end
  end

  defp safe_metadata_value(_value), do: :error

  defp safe_freeform_message?(message) do
    message != "" and String.length(message) <= 220 and not technical_message?(message)
  end

  defp technical_message?(message) do
    lower = String.downcase(message)

    Enum.any?(@technical_markers, &String.contains?(lower, &1)) or
      String.contains?(message, "{") or
      String.contains?(message, "}") or
      String.contains?(message, "=>") or
      Regex.match?(~r/\bapi\b/i, message) or
      Regex.match?(~r/\b(access|refresh)?_?token\s*[:=]/i, message)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
