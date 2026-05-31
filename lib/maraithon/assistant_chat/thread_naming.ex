defmodule Maraithon.AssistantChat.ThreadNaming do
  @moduledoc false

  @default_title "New conversation"

  def default_title, do: @default_title

  def title_for_message(message, opts \\ [])

  def title_for_message(message, opts) when is_binary(message) do
    max_length = Keyword.get(opts, :max_length, 42)
    cleaned = normalize(message)

    cond do
      cleaned == "" ->
        @default_title

      suggested = suggested_title(cleaned) ->
        suggested

      true ->
        cleaned
        |> public_title_text()
        |> clipped(max_length)
    end
  end

  def title_for_message(_message, _opts), do: @default_title

  def placeholder?(value) when is_binary(value) do
    normalized =
      value
      |> normalize()
      |> String.downcase()

    normalized in ["", String.downcase(@default_title)]
  end

  def placeholder?(_value), do: true

  def public_title_text(value) when is_binary(value) do
    value
    |> normalize()
    |> String.replace(~r/\btodos\b/i, "work items")
    |> String.replace(~r/\btodo\b/i, "work item")
    |> String.replace(~r/^(please\s+|help me\s+|can you\s+|could you\s+)/i, "")
    |> String.trim()
    |> String.replace(~r/^[\s\p{P}]+|[\s\p{P}]+$/u, "")
    |> capitalize_first()
  end

  def public_title_text(_value), do: nil

  defp normalize(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp suggested_title(value) do
    lower = String.downcase(value)

    cond do
      String.contains?(lower, "plan my day") or String.contains?(lower, "prioritize my day") ->
        "Daily plan"

      String.contains?(lower, "who needs care") or
        String.contains?(lower, "who needs attention") or
        String.contains?(lower, "review my people") or
          String.contains?(lower, "relationship follow") ->
        "Relationship follow-ups"

      String.contains?(lower, "what do i owe") or
        String.contains?(lower, "waiting on me") or
          String.contains?(lower, "waiting on") ->
        "What I owe"

      String.contains?(lower, "draft a follow-up") or
        String.contains?(lower, "draft follow-up") or
          String.contains?(lower, "write a follow-up") ->
        "Follow-up draft"

      String.contains?(lower, "capture work") or
        String.contains?(lower, "capture a work item") or
        String.contains?(lower, "capture a todo") or
          String.contains?(lower, "capture todo") ->
        "Capture work"

      true ->
        nil
    end
  end

  defp capitalize_first(""), do: ""

  defp capitalize_first(value) do
    case String.next_grapheme(value) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> value
    end
  end

  defp clipped(nil, _max_length), do: @default_title

  defp clipped(value, max_length) when is_integer(max_length) and max_length > 0 do
    if String.length(value) > max_length do
      prefix =
        value
        |> String.slice(0, max_length)
        |> String.trim()

      if word_boundary?(value, max_length) do
        prefix
      else
        trimmed_prefix =
          prefix
          |> String.split(~r/\s+/, trim: true)
          |> Enum.drop(-1)
          |> Enum.join(" ")

        if trimmed_prefix == "", do: prefix, else: trimmed_prefix
      end
    else
      value
    end
  end

  defp clipped(value, _max_length), do: value

  defp word_boundary?(value, max_length) do
    case String.slice(value, max_length, 1) do
      "" -> true
      next -> Regex.match?(~r/^[\s\p{P}]$/u, next)
    end
  end
end
