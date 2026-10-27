defmodule MaraithonWeb.AutomationDisplayCopy do
  @moduledoc false

  @action_labels %{
    "file_tree" => "Review folder structure",
    "list_files" => "List local files",
    "read_file" => "Read local files",
    "search_files" => "Search local files",
    "http_get" => "Check URLs",
    "gmail_get_message" => "Read Gmail messages",
    "gmail_list_recent" => "Review recent Gmail",
    "gmail_search" => "Search Gmail",
    "gmail_send_message" => "Send Gmail messages",
    "google_calendar_list_events" => "Review calendar events",
    "slack_get_thread_replies" => "Review Slack threads",
    "slack_list_conversations" => "Review Slack channels",
    "slack_list_messages" => "Review Slack messages",
    "slack_post_message" => "Send Slack messages",
    "slack_search_messages" => "Search Slack",
    "linear_create_comment" => "Comment in Linear",
    "linear_create_issue" => "Create Linear issues",
    "linear_update_issue_state" => "Update Linear issues"
  }

  def context_list(values) do
    values
    |> normalize_list()
    |> Enum.map(&context_label/1)
    |> Enum.join(", ")
  end

  def action_list(values) do
    values
    |> normalize_list()
    |> Enum.map(&action_label/1)
    |> Enum.join(", ")
  end

  defp context_label("github:" <> repository), do: "GitHub #{repository}"
  defp context_label("email:" <> mailbox), do: "Email #{mailbox}"
  defp context_label("calendar:" <> calendar), do: "Calendar #{calendar}"
  defp context_label("slack:" <> workspace), do: "Slack #{workspace}"
  defp context_label(value), do: value

  defp action_label(action) do
    Map.get(@action_labels, action) || humanize_identifier(action)
  end

  defp normalize_list(values) when is_binary(values) do
    values
    |> String.split(",")
    |> normalize_parts()
  end

  defp normalize_list(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      value when is_binary(value) -> String.split(value, ",")
      _value -> []
    end)
    |> normalize_parts()
  end

  defp normalize_list(_values), do: []

  defp normalize_parts(values) do
    values
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp humanize_identifier(value) do
    value
    |> String.replace(~r/[_.]/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &display_word/1)
  end

  defp display_word(word) do
    case String.downcase(word) do
      "api" -> "API"
      "dm" -> "DM"
      "dms" -> "DMs"
      "gmail" -> "Gmail"
      "github" -> "GitHub"
      "http" -> "HTTP"
      "url" -> "URL"
      other -> String.capitalize(other)
    end
  end
end
