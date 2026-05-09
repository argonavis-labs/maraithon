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
    "get_open_loops" => Maraithon.Tools.GetOpenLoops,
    "list_todos" => Maraithon.Tools.ListTodos,
    "upsert_todos" => Maraithon.Tools.UpsertTodos,
    "resolve_todo" => Maraithon.Tools.ResolveTodo,
    "list_people" => Maraithon.Tools.ListPeople,
    "get_person" => Maraithon.Tools.GetPerson,
    "upsert_person" => Maraithon.Tools.UpsertPerson,
    "delete_person" => Maraithon.Tools.DeletePerson,
    "link_person_data" => Maraithon.Tools.LinkPersonData,
    "get_relationship_context" => Maraithon.Tools.GetRelationshipContext,
    "list_memories" => Maraithon.Tools.ListMemories,
    "write_memory" => Maraithon.Tools.WriteMemory,
    "recall_memory" => Maraithon.Tools.RecallMemory,
    "forget_memory" => Maraithon.Tools.ForgetMemory,
    "record_memory_feedback" => Maraithon.Tools.RecordMemoryFeedback,
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

  @tool_names @tools |> Map.keys() |> Enum.sort()

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
    "get_open_loops" =>
      "Fetch the built-in open-loop snapshot across todos, CRM relationships, and deep memory.",
    "list_todos" => "List the built-in persistent todo list for a user.",
    "upsert_todos" =>
      "Use model-level todo intelligence to create, update, or skip built-in persistent todos.",
    "resolve_todo" => "Mark one built-in persistent todo done, dismissed, or snoozed.",
    "list_people" => "List CRM people and relationship metadata for a user.",
    "get_person" => "Get one CRM person by id, query, or contact detail.",
    "upsert_person" => "Create or update one CRM person with contact and relationship details.",
    "delete_person" => "Delete one CRM person and its CRM links.",
    "link_person_data" =>
      "Attach or detach a CRM person from a todo or another user-owned data object.",
    "get_relationship_context" =>
      "Fetch CRM relationship context for a person, including linked todos.",
    "list_memories" => "List built-in durable deep memories for a user.",
    "write_memory" => "Create or update one built-in durable deep memory item.",
    "recall_memory" =>
      "Use model-level memory intelligence to recall relevant durable memories for a query.",
    "forget_memory" => "Archive, supersede, or reject one durable deep memory item.",
    "record_memory_feedback" =>
      "Record user feedback that something is relevant or not relevant as durable memory.",
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

  @read_only_tools MapSet.new(~w(
    time http_get read_file list_files file_tree search_files
    gmail_list_recent gmail_search gmail_get_message
    google_contacts_search google_calendar_list_events
    get_open_loops list_todos list_people get_person get_relationship_context
    list_memories recall_memory
    slack_list_conversations slack_list_messages slack_get_thread_replies slack_search_messages
    linear_get_issue linear_list_issues linear_list_teams
    notaui_list_tasks
    notion_search notion_get_page notion_query_database
  ))

  @destructive_tools MapSet.new(~w(
    delete_person resolve_todo forget_memory gmail_batch_modify gmail_filters gmail_labels
    gmail_drafts notaui_complete_task notaui_update_task notion_update_page notion_blocks
  ))

  @doc """
  Execute a tool by name.
  """
  def execute(name, args) do
    case fetch(name) do
      {:ok, module} -> module.execute(args)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolve a tool module by name.
  """
  def fetch(name) when is_binary(name) do
    case Map.get(@tools, name) do
      nil -> {:error, "unknown_tool: #{name}"}
      module -> {:ok, module}
    end
  end

  def fetch(name), do: {:error, "unknown_tool: #{inspect(name)}"}

  @doc """
  List available tools.
  """
  def list do
    @tool_names
  end

  @doc """
  List tool descriptors for MCP and other discovery clients.
  """
  def describe(names \\ nil) do
    names
    |> requested_tool_names()
    |> Enum.map(fn name ->
      %{
        name: name,
        description: Map.get(@tool_descriptions, name, "Execute the #{name} tool."),
        input_schema: Maraithon.Tools.InputSchemas.schema_for(name),
        annotations: annotations_for(name)
      }
    end)
  end

  @doc """
  Check if a tool exists.
  """
  def exists?(name) do
    Map.has_key?(@tools, name)
  end

  defp requested_tool_names(nil), do: @tool_names
  defp requested_tool_names([]), do: @tool_names

  defp requested_tool_names(names) when is_list(names) do
    names
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Map.has_key?(@tools, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp requested_tool_names(_names), do: @tool_names

  defp annotations_for(name) do
    %{
      "title" => titleize(name),
      "readOnlyHint" => MapSet.member?(@read_only_tools, name),
      "destructiveHint" => MapSet.member?(@destructive_tools, name),
      "idempotentHint" => idempotent_tool?(name)
    }
  end

  defp idempotent_tool?(name) do
    name in ~w(
      upsert_todos upsert_person write_memory record_memory_feedback link_person_data
      gmail_batch_modify notaui_update_task notion_update_page
    )
  end

  defp titleize(name) do
    name
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
