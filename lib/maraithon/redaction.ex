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
  )

  @scanners [
    # Bearer / Basic auth headers
    {~r/\b(?:Bearer|Basic)\s+[A-Za-z0-9._\-+\/=]+/i, "<redacted-auth>"},
    # JWT-shaped strings (header.payload.signature)
    {~r/\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b/, "<redacted-jwt>"},
    # Anthropic-style keys (must come before the broader OpenAI scanner)
    {~r/\bsk-ant-[A-Za-z0-9_\-]{20,}\b/, "<redacted-anthropic-key>"},
    # OpenAI-style keys
    {~r/\bsk-(?!ant-)[A-Za-z0-9_\-]{20,}\b/, "<redacted-openai-key>"},
    # Slack tokens
    {~r/\bxox[abprs]-[A-Za-z0-9-]{10,}\b/, "<redacted-slack-token>"},
    # GitHub PAT / app tokens
    {~r/\bgh[opsu]_[A-Za-z0-9]{20,}\b/, "<redacted-github-token>"},
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
    Enum.reduce(@scanners, value, fn {regex, replacement}, acc ->
      Regex.replace(regex, acc, replacement)
    end)
  end

  def redact_string(value), do: value

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
