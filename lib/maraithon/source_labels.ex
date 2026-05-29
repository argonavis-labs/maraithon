defmodule Maraithon.SourceLabels do
  @moduledoc """
  User-facing labels for connector and local-source identifiers.

  Internal source keys often use snake_case tokens. Product copy should not
  leak those tokens to chat, cards, or mobile surfaces.
  """

  @labels %{
    "browser" => "Browser",
    "browser_history" => "Browser History",
    "calendar" => "Calendar",
    "calendar_local" => "Calendar",
    "desktop" => "Mac companion",
    "files" => "Files",
    "github" => "GitHub",
    "gmail" => "Gmail",
    "gmail_thread" => "Gmail",
    "google" => "Google",
    "google_calendar" => "Google Calendar",
    "imessage" => "iMessage",
    "linear" => "Linear",
    "manual" => "Added by you",
    "messages" => "Messages",
    "mcp" => "Connected tool",
    "notaui" => "Notaui",
    "notes" => "Notes",
    "notion" => "Notion",
    "operator_ui" => "Manual edit",
    "reminders" => "Reminders",
    "runtime" => "Maraithon",
    "slack" => "Slack",
    "system" => "Maraithon",
    "telegram" => "Telegram",
    "telegram_assistant" => "Maraithon",
    "telegram_confirmation" => "Telegram",
    "telegram_verification" => "Maraithon",
    "voice_memos" => "Voice Memos"
  }

  @doc """
  Returns a user-facing source label.

  Namespaced values such as `gmail_thread:abc123` are labeled by their source
  prefix. Unknown tokens are title-cased after replacing separators.
  """
  def label(source, opts \\ [])

  def label(source, opts) when is_binary(source) and is_list(opts) do
    fallback = Keyword.get(opts, :fallback, "Maraithon")

    source
    |> normalize()
    |> case do
      nil -> fallback
      key -> Map.get(@labels, key) || titleize(key)
    end
  end

  def label(nil, opts) when is_list(opts), do: Keyword.get(opts, :fallback, "Maraithon")

  def label(source, _opts), do: to_string(source)

  defp normalize(source) do
    source
    |> String.trim()
    |> case do
      "" -> nil
      value -> value |> String.downcase() |> String.split(":", parts: 2) |> List.first()
    end
  end

  defp titleize(value) do
    value
    |> String.replace(~r/[_-]+/, " ")
    |> String.split()
    |> Enum.map(&capitalize_word/1)
    |> Enum.join(" ")
  end

  defp capitalize_word(<<first::utf8, rest::binary>>) do
    String.upcase(<<first::utf8>>) <> String.downcase(rest)
  end

  defp capitalize_word(value), do: value
end
