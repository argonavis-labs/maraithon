defmodule Maraithon.Redaction do
  @moduledoc """
  Scrub credentials and secrets from values before they hit logs, audit
  trails, or operator surfaces.

  Two complementary mechanisms:

    1. **Field-name heuristics** — keys whose normalized name ends in one of
       `apikey`, `password`, `passwd`, `passphrase`, `secret`, `secretkey`,
       `token`, or contains `bearer`, `authorization` are replaced with
       `"<redacted>"`.

    2. **Regex-based string scanners** — known credential patterns
       (Authorization Bearer/Basic headers, JWTs, Slack/GitHub tokens,
       OpenAI keys, set-cookie pairs) are replaced inline inside any binary
       value.

  Inspired by openclaw's `payload-redaction.ts`.
  """

  @redacted "<redacted>"
  @min_log_integer -9_223_372_036_854_775_808
  @max_log_integer 9_223_372_036_854_775_807

  @sensitive_field_suffixes ~w(
    apikey
    password
    passwd
    passphrase
    secret
    secretkey
    token
    accesstoken
    refreshtoken
    bearertoken
    privatekey
    sessionkey
  )

  @sensitive_field_substrings ~w(
    authorization
    cookie
    bearer
    promptsnapshot
    rawprompt
    systemprompt
    webhookbody
    tooloutput
  )

  @scanners [
    # Bearer / Basic auth headers
    {~r/\b(?:Bearer|Basic)\s+[A-Za-z0-9._\-+\/=]+/i, "<redacted-auth>"},
    # JWT-shaped strings (header.payload.signature)
    {~r/\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b/, "<redacted-jwt>"},
    # Anthropic-style keys (must come before the broader OpenAI scanner)
    {~r/\bsk-ant-[A-Za-z0-9_\-]{20,}\b/, "<redacted-anthropic-key>"},
    # OpenRouter-style keys (must come before the broader OpenAI scanner)
    {~r/\bsk-or-v1-[A-Za-z0-9_\-]{20,}\b/, "<redacted-openrouter-key>"},
    # OpenAI-style keys
    {~r/\bsk-(?!ant-)[A-Za-z0-9_\-]{20,}\b/, "<redacted-openai-key>"},
    # Slack tokens
    {~r/\bxox[abprs]-[A-Za-z0-9-]{10,}\b/, "<redacted-slack-token>"},
    # GitHub PAT / app tokens
    {~r/\bgh[opsu]_[A-Za-z0-9]{20,}\b/, "<redacted-github-token>"},
    # Assignment-style secrets that often appear in inspected error strings
    {~r/\b([A-Za-z0-9_]*(?:api_?key|access_?token|refresh_?token|client_?secret|private_?key|password|secret|token)[A-Za-z0-9_]*\s*=\s*)(?:"[^"]*"|'[^']*'|[^\s,;)}\]]+)/i,
     "\\1<redacted>"},
    # Generic Cookie name=value pairs
    {~r/(set-cookie:\s*[^=;]+=)([^;\s]+)/i, "\\1<redacted>"}
  ]

  @doc """
  Recursively redact a value. Maps and structs become maps with offending
  fields replaced; lists are walked element-by-element; strings are passed
  through the regex scanners; primitives pass through unchanged.
  """
  def redact(value)

  def redact(value) when is_binary(value), do: redact_string(value)

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact({key, value}) when is_atom(key) or is_binary(key) do
    if sensitive_key?(key), do: {key, @redacted}, else: {key, redact(value)}
  end

  def redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact/1)
    |> List.to_tuple()
  end

  def redact(%DateTime{} = value), do: value
  def redact(%NaiveDateTime{} = value), do: value
  def redact(%Date{} = value), do: value
  def redact(%Time{} = value), do: value

  def redact(%_{} = struct) do
    struct |> Map.from_struct() |> redact()
  end

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      cond do
        sensitive_key?(key) -> {key, @redacted}
        true -> {key, redact(nested)}
      end
    end)
  end

  def redact(value), do: value

  @doc """
  Apply only the regex scanners to a string. Useful when you have a binary
  blob you want to scrub without restructuring it.
  """
  def redact_string(value) when is_binary(value) do
    value
    |> Maraithon.PromptBudget.truncate_utf8(16_000)
    |> then(fn sanitized ->
      Enum.reduce(@scanners, sanitized, fn {regex, replacement}, acc ->
        Regex.replace(regex, acc, replacement)
      end)
    end)
  end

  def redact_string(value), do: value

  @doc """
  Return a stable pseudonymous short reference for an opaque identifier.

  This is intended for correlating per-user or per-account telemetry without
  writing the raw identifier to logs.
  """
  def fingerprint(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  def fingerprint(_value), do: nil

  @doc """
  Sanitize one Logger metadata value before a formatter or in-memory backend
  serializes it. Error/body-like fields are reduced to closed classifications
  rather than regex-redacted because provider bodies may contain arbitrary
  prompt or user text with no recognizable secret pattern.
  """
  def log_metadata_value(key, value) do
    case Maraithon.SafeLogMetadata.classification(key) do
      :identifier -> identifier_fingerprint(value)
      :opaque -> opaque_log_value(value)
      :status -> status_log_value(value)
      :numeric -> numeric_log_value(value)
      :label -> label_log_value(value)
      :failure_codes -> failure_codes_log_value(value)
      :unknown -> "redacted_detail"
    end
  end

  defp identifier_fingerprint(value) when is_binary(value), do: fingerprint(value)

  defp identifier_fingerprint(value)
       when is_integer(value) and value >= @min_log_integer and value <= @max_log_integer,
       do: fingerprint(Integer.to_string(value))

  defp identifier_fingerprint(_value), do: nil

  defp numeric_log_value(value)
       when is_integer(value) and value >= @min_log_integer and value <= @max_log_integer,
       do: value

  defp numeric_log_value(value) when is_float(value) do
    if value == value and abs(value) <= 9.223_372_036_854_776e18,
      do: value,
      else: "redacted_detail"
  end

  defp numeric_log_value(value) when is_boolean(value) or is_nil(value), do: value

  defp numeric_log_value(value) when is_binary(value) do
    if byte_size(value) <= 32 and Regex.match?(~r/^-?[0-9]+(?:\.[0-9]+)?$/, value),
      do: value,
      else: "redacted_detail"
  end

  defp numeric_log_value(_value), do: "redacted_detail"

  defp status_log_value(value) when is_number(value), do: numeric_log_value(value)
  defp status_log_value(value), do: label_log_value(value)

  defp label_log_value(value) when is_atom(value), do: label_log_value(Atom.to_string(value))

  defp label_log_value(value) when is_binary(value) do
    if byte_size(value) <= 128 and String.valid?(value) and
         Regex.match?(~r/^[A-Za-z0-9._:\/-]+$/, value),
       do: value,
       else: "redacted_detail"
  end

  defp label_log_value(_value), do: "redacted_detail"

  defp failure_codes_log_value(value) when is_map(value) do
    value
    |> Enum.take(32)
    |> Map.new(fn {key, count} -> {label_log_value(key), numeric_log_value(count)} end)
  end

  defp failure_codes_log_value(value) when is_list(value) do
    value |> Enum.take(32) |> Enum.map(&label_log_value/1)
  end

  defp failure_codes_log_value(_value), do: "redacted_detail"

  @doc """
  Return a bounded, closed error summary suitable for durable error fields.
  Provider-controlled detail is never inspected.
  """
  def error_summary(value) do
    case opaque_log_value(value) do
      summary when is_binary(summary) -> summary
      summary -> inspect(summary, pretty: false, limit: 5, printable_limit: 80)
    end
  end

  @doc """
  Return a closed error class without inspecting provider-controlled detail.
  """
  def error_class({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  def error_class({kind, _status, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  def error_class(%module{}) when is_atom(module), do: Atom.to_string(module)
  def error_class(value) when is_atom(value), do: Atom.to_string(value)
  def error_class(_value), do: "unknown_error"

  defp opaque_log_value({kind, delay_ms})
       when kind in [:rate_limited, :llm_busy] and is_integer(delay_ms) and delay_ms > 0,
       do: "#{kind}:#{min(delay_ms, 86_400_000)}"

  defp opaque_log_value({kind, status, _detail})
       when is_atom(kind) and is_integer(status) and status >= @min_log_integer and
              status <= @max_log_integer,
       do: "#{kind}:#{status}"

  defp opaque_log_value({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp opaque_log_value({kind, _status, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp opaque_log_value(%module{}) when is_atom(module), do: Atom.to_string(module)
  defp opaque_log_value(value) when is_atom(value), do: Atom.to_string(value)

  defp opaque_log_value(value)
       when is_integer(value) and value >= @min_log_integer and value <= @max_log_integer,
       do: value

  defp opaque_log_value(value) when is_boolean(value) or is_nil(value), do: value

  defp opaque_log_value(_value), do: "redacted_detail"

  @doc false
  def sensitive_key?(key) do
    case normalize_key(key) do
      "" ->
        false

      normalized ->
        Enum.any?(@sensitive_field_suffixes, &String.ends_with?(normalized, &1)) or
          Enum.any?(@sensitive_field_substrings, &String.contains?(normalized, &1))
    end
  end

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end
end
