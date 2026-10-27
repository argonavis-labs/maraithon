defmodule Maraithon.LocalSearch do
  @moduledoc """
  Shared natural-language matching for encrypted local-source mirrors.

  Many Desktop App sources are Cloak-encrypted, so search runs in memory after
  a bounded recency fetch. This helper keeps token matching consistent across
  iMessage, Notes, Reminders, Files, and Voice Memos.
  """

  @low_signal_tokens ~w(and the for with from about online project)

  def compile(term) when is_binary(term) do
    normalized = normalize(term)

    %{
      needle: normalized,
      tokens:
        normalized
        |> String.split(~r/[^a-z0-9]+/u, trim: true)
        |> Enum.reject(&low_signal_token?/1)
        |> Enum.uniq()
    }
  end

  def compile(_term), do: %{needle: "", tokens: []}

  def normalize(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def normalize(_value), do: ""

  def matches?(query, values) when is_map(query) and is_list(values) do
    haystack =
      values
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&normalize/1)
      |> Enum.join(" ")

    needle = Map.get(query, :needle, "")
    tokens = Map.get(query, :tokens, [])

    cond do
      needle == "" -> false
      String.contains?(haystack, needle) -> true
      tokens == [] -> false
      true -> token_match?(haystack, tokens)
    end
  end

  def matches?(_query, _values), do: false

  defp token_match?(_haystack, []), do: false

  defp token_match?(haystack, tokens) do
    matches = Enum.count(tokens, &String.contains?(haystack, &1))
    threshold = min(2, length(tokens))

    matches >= threshold
  end

  defp low_signal_token?(token) do
    String.length(token) < 3 or token in @low_signal_tokens
  end
end
