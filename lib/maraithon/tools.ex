defmodule Maraithon.Tools do
  @moduledoc """
  Tool registry and execution.
  """

  @tools %{
    "time" => Maraithon.Tools.Time,
    "http_get" => Maraithon.Tools.HttpGet,
    "read_file" => Maraithon.Tools.ReadFile,
    "list_files" => Maraithon.Tools.ListFiles,
    "file_tree" => Maraithon.Tools.FileTree,
    "search_files" => Maraithon.Tools.SearchFiles,
    "gmail_list_recent" => Maraithon.Tools.GmailListRecent,
    "gmail_search" => Maraithon.Tools.GmailSearch,
    "gmail_get_message" => Maraithon.Tools.GmailGetMessage,
    "gmail_send_message" => Maraithon.Tools.GmailSendMessage,
    "gmail_labels" => Maraithon.Tools.GmailLabels,
    "gmail_drafts" => Maraithon.Tools.GmailDrafts,
    "gmail_batch_modify" => Maraithon.Tools.GmailBatchModify,
    "gmail_filters" => Maraithon.Tools.GmailFilters,
    "google_contacts_search" => Maraithon.Tools.GoogleContactsSearch,
    "google_calendar_list_events" => Maraithon.Tools.GoogleCalendarListEvents,
    "github_create_issue_comment" => Maraithon.Tools.GitHubCreateIssueComment,
    "slack_post_message" => Maraithon.Tools.SlackPostMessage,
    "slack_list_conversations" => Maraithon.Tools.SlackListConversations,
    "slack_list_messages" => Maraithon.Tools.SlackListMessages,
    "slack_get_thread_replies" => Maraithon.Tools.SlackGetThreadReplies,
    "slack_search_messages" => Maraithon.Tools.SlackSearchMessages,
    "slack_open_conversation" => Maraithon.Tools.SlackOpenConversation,
    "linear_create_comment" => Maraithon.Tools.LinearCreateComment,
    "linear_create_issue" => Maraithon.Tools.LinearCreateIssue,
    "linear_get_issue" => Maraithon.Tools.LinearGetIssue,
    "linear_list_issues" => Maraithon.Tools.LinearListIssues,
    "linear_list_teams" => Maraithon.Tools.LinearListTeams,
    "linear_update_issue" => Maraithon.Tools.LinearUpdateIssue,
    "linear_update_issue_state" => Maraithon.Tools.LinearUpdateIssueState,
    "notaui_list_tasks" => Maraithon.Tools.NotauiListTasks,
    "notaui_complete_task" => Maraithon.Tools.NotauiCompleteTask,
    "notaui_update_task" => Maraithon.Tools.NotauiUpdateTask,
    "notion_search" => Maraithon.Tools.NotionSearch,
    "notion_get_page" => Maraithon.Tools.NotionGetPage,
    "notion_query_database" => Maraithon.Tools.NotionQueryDatabase,
    "notion_create_page" => Maraithon.Tools.NotionCreatePage,
    "notion_update_page" => Maraithon.Tools.NotionUpdatePage,
    "notion_blocks" => Maraithon.Tools.NotionBlocks
  }

  @tool_descriptions %{
    "time" => "Return the current UTC time.",
    "http_get" => "Fetch a URL with an HTTP GET request.",
    "read_file" => "Read a local file within the allowed tool roots.",
    "list_files" => "List files in a local directory within the allowed tool roots.",
    "file_tree" => "Return a compact file tree for a local directory.",
    "search_files" => "Search local files by text pattern.",
    "gmail_list_recent" => "List recent Gmail messages across connected Google accounts.",
    "gmail_search" => "Search Gmail with a Gmail query string.",
    "gmail_get_message" => "Fetch a Gmail message by id.",
    "gmail_send_message" => "Send a Gmail message or threaded reply.",
    "gmail_labels" => "List, create, update, and delete Gmail labels.",
    "gmail_drafts" => "List, get, create, update, send, and delete Gmail drafts.",
    "gmail_batch_modify" =>
      "Batch archive, unarchive, mark read/unread, label, or unlabel Gmail messages.",
    "gmail_filters" => "List, get, create, and delete Gmail filters.",
    "google_contacts_search" => "Search connected Google Contacts.",
    "google_calendar_list_events" => "List Google Calendar events.",
    "github_create_issue_comment" => "Create a GitHub issue comment.",
    "slack_post_message" => "Post a Slack message or thread reply.",
    "slack_list_conversations" => "List Slack channels, private channels, DMs, and MPIMs.",
    "slack_list_messages" =>
      "Read recent Slack messages from a channel, private channel, DM, or MPIM.",
    "slack_get_thread_replies" => "Read replies in a Slack thread.",
    "slack_search_messages" => "Search Slack messages with a connected user token.",
    "slack_open_conversation" => "Open or resume a Slack DM or MPIM conversation.",
    "linear_create_comment" => "Create a Linear comment on an issue.",
    "linear_create_issue" => "Create a Linear issue.",
    "linear_get_issue" => "Get a Linear issue by UUID or identifier.",
    "linear_list_issues" =>
      "List Linear issues with team, assignee, state, project, label, and text filters.",
    "linear_list_teams" => "List Linear teams available to the connected user.",
    "linear_update_issue" =>
      "Update Linear issue fields such as title, description, priority, assignee, project, labels, or state.",
    "linear_update_issue_state" => "Update a Linear issue state.",
    "notaui_list_tasks" => "List tasks from a connected Notaui MCP workspace.",
    "notaui_complete_task" => "Complete a Notaui task through MCP.",
    "notaui_update_task" => "Update a Notaui task through MCP.",
    "notion_search" => "Search pages and databases in a connected Notion workspace.",
    "notion_get_page" => "Get a Notion page by id.",
    "notion_query_database" => "Query a Notion database.",
    "notion_create_page" => "Create a Notion page under a parent page or database.",
    "notion_update_page" => "Update a Notion page.",
    "notion_blocks" => "List, append, update, or archive Notion blocks."
  }

  @doc """
  Execute a tool by name.
  """
  def execute(name, args) do
    case Map.get(@tools, name) do
      nil -> {:error, "unknown_tool: #{name}"}
      module -> module.execute(args)
    end
  end

  @doc """
  List available tools.
  """
  def list do
    Map.keys(@tools)
  end

  @doc """
  List tool descriptors for MCP and other discovery clients.
  """
  def describe do
    @tools
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn name ->
      %{
        name: name,
        description: Map.get(@tool_descriptions, name, "Execute the #{name} tool."),
        input_schema: permissive_input_schema()
      }
    end)
  end

  @doc """
  Check if a tool exists.
  """
  def exists?(name) do
    Map.has_key?(@tools, name)
  end

  defp permissive_input_schema do
    %{
      "type" => "object",
      "additionalProperties" => true
    }
  end
end
