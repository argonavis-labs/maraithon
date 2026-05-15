defmodule Maraithon.Capabilities do
  @moduledoc """
  First-party capability registry for tools, connectors, and model providers.

  This registry is intentionally static. It gives product and runtime code one
  source of truth for the capabilities Maraithon ships with, without opening a
  third-party plugin/runtime-loading surface.
  """

  alias Maraithon.Tools.InputSchemas

  @tool_modules %{
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
    "review_connected_context" => Maraithon.Tools.ReviewConnectedContext,
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
    "learn_relationship_context" => Maraithon.Tools.LearnRelationshipContext,
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
    "notion_blocks" => Maraithon.Tools.NotionBlocks,
    "notes_search" => Maraithon.Tools.NotesSearch,
    "notes_get" => Maraithon.Tools.NotesGet,
    "notes_list_recent" => Maraithon.Tools.NotesListRecent,
    "voice_memos_search" => Maraithon.Tools.VoiceMemosSearch,
    "voice_memos_get" => Maraithon.Tools.VoiceMemosGet,
    "voice_memos_list_recent" => Maraithon.Tools.VoiceMemosListRecent,
    "files_search" => Maraithon.Tools.FilesSearch,
    "files_get" => Maraithon.Tools.FilesGet,
    "files_list_recent" => Maraithon.Tools.FilesListRecent,
    "messages_search" => Maraithon.Tools.MessagesSearch,
    "messages_get" => Maraithon.Tools.MessagesGet,
    "messages_list_recent" => Maraithon.Tools.MessagesListRecent,
    "messages_chats_recent" => Maraithon.Tools.MessagesChatsRecent,
    "reminders_open" => Maraithon.Tools.RemindersOpen,
    "reminders_due_soon" => Maraithon.Tools.RemindersDueSoon,
    "reminders_search" => Maraithon.Tools.RemindersSearch,
    "reminders_get" => Maraithon.Tools.RemindersGet,
    "calendar_events_around" => Maraithon.Tools.CalendarEventsAround,
    "calendar_events_for_person" => Maraithon.Tools.CalendarEventsForPerson,
    "calendar_search" => Maraithon.Tools.CalendarSearch,
    "calendar_event_get" => Maraithon.Tools.CalendarEventGet,
    "browser_history_recent" => Maraithon.Tools.BrowserHistoryRecent,
    "browser_history_by_host" => Maraithon.Tools.BrowserHistoryByHost,
    "browser_history_search" => Maraithon.Tools.BrowserHistorySearch,
    "browser_history_get" => Maraithon.Tools.BrowserHistoryGet,
    "recall_anywhere" => Maraithon.Tools.RecallAnywhere,
    "companion_devices_list" => Maraithon.Tools.CompanionDevicesList,
    "notes_semantic_search" => Maraithon.Tools.NotesSemanticSearch,
    "voice_memos_semantic_search" => Maraithon.Tools.VoiceMemosSemanticSearch,
    "messages_semantic_search" => Maraithon.Tools.MessagesSemanticSearch,
    "calendar_semantic_search" => Maraithon.Tools.CalendarSemanticSearch,
    "reminders_semantic_search" => Maraithon.Tools.RemindersSemanticSearch,
    "files_semantic_search" => Maraithon.Tools.FilesSemanticSearch
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
    "review_connected_context" =>
      "Review connected CRM, Gmail, contacts, calendar, Slack, open loops, and memory for source-grounded context.",
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
    "learn_relationship_context" =>
      "Use model-level relationship intelligence to learn CRM people, memories, and links from source observations.",
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
    "notion_blocks" => "List, append, update, or archive Notion blocks.",
    "notes_search" =>
      "Search the user's mirrored macOS Notes for a substring in title or snippet.",
    "notes_get" => "Fetch one mirrored macOS Note by its source GUID.",
    "notes_list_recent" => "List the user's most recently modified mirrored macOS Notes.",
    "voice_memos_search" => "Search the user's mirrored macOS Voice Memos by title substring.",
    "voice_memos_get" => "Fetch one mirrored macOS Voice Memo by its source GUID.",
    "voice_memos_list_recent" =>
      "List the user's most recently created mirrored macOS Voice Memos.",
    "files_search" =>
      "Search the user's mirrored macOS files (Documents, Desktop, Downloads) for a substring across filename, path, and extracted text content. Optional extension and path_substring filters.",
    "files_get" =>
      "Fetch one mirrored macOS file by its source GUID, including extracted text (capped at 30 KB for the response).",
    "files_list_recent" =>
      "List the user's most recently modified mirrored macOS files, newest first. Optional extension filter.",
    "messages_search" =>
      "Search the user's mirrored iMessage history for a substring, optionally filtered by sender handle and date range.",
    "messages_get" =>
      "Fetch one mirrored iMessage by its source GUID, including full text and chat metadata.",
    "messages_list_recent" =>
      "List the user's most recent mirrored iMessages, newest first. Optionally restrict to one chat by chat_key.",
    "messages_chats_recent" =>
      "List the user's most recently active iMessage chats with the latest message in each and a 7-day message count.",
    "reminders_open" =>
      "List the user's open mirrored macOS Reminders, ordered by due date then priority.",
    "reminders_due_soon" =>
      "List the user's open mirrored macOS Reminders due within the next N days (default 7), including overdue.",
    "reminders_search" =>
      "Search the user's mirrored macOS Reminders for a substring in title, notes, or list name.",
    "reminders_get" =>
      "Fetch one mirrored macOS Reminder by its source GUID (EventKit identifier).",
    "calendar_events_around" =>
      "List the user's mirrored macOS Calendar events overlapping a date window (default: now to +7 days). Prefer this over google_calendar_list_events when both are available — the local mirror aggregates every calendar account (iCloud, Exchange, Google CalDAV, etc.) that the user has added on their Mac.",
    "calendar_events_for_person" =>
      "Find the user's mirrored macOS Calendar events that involve a specific person, matched by email or name substring against attendees, organizer, and title.",
    "calendar_search" =>
      "Substring-search the user's mirrored macOS Calendar events on title, notes, and location. Use for topic-based questions like 'when's the launch review?'.",
    "calendar_event_get" => "Fetch one mirrored macOS Calendar event by its EventKit GUID.",
    "browser_history_recent" =>
      "List the user's most recently visited URLs across Chrome / Safari / Arc / Brave, newest first. Optional browser filter.",
    "browser_history_by_host" =>
      "Filter the user's browser history by host substring (e.g. 'techmeme'). Use when the user asks about an article from a specific site.",
    "browser_history_search" =>
      "Search the user's browser history for a substring in title, URL, or host. Use when the user references something they were reading or researching online by topic.",
    "browser_history_get" =>
      "Fetch one browser visit by its source GUID, including the full URL and title.",
    "recall_anywhere" =>
      "Search every local + remote source the user has connected — iMessage, Notes, Voice Memos, Calendar, Reminders, Files, Browser History, Gmail, Slack, CRM people, deep memory — in one shot. Use as a first-call when the user asks open-ended questions like 'what was that thing about a wedding?' or 'remind me what we said about the launch'.",
    "companion_devices_list" =>
      "List the Macs (and other companion devices) the user has paired, with last-seen timestamps and per-source mirrored-row counts. Use when the user asks 'what Macs am I paired on?' or wants to audit which devices are sending data.",
    "notes_semantic_search" =>
      "Semantic search of the user's mirrored macOS Notes by meaning (cosine similarity over embeddings), not exact substring. Pairs with `notes_search`: prefer this tool when the user asks 'find the note about something like X' or 'what was that idea I wrote down about ...' and won't recall the exact words.",
    "voice_memos_semantic_search" =>
      "Semantic search of the user's mirrored macOS Voice Memos by meaning, not exact substring. Pairs with `voice_memos_search`: prefer this tool when the user asks 'find the memo where I talked about something similar' and won't recall the exact words.",
    "messages_semantic_search" =>
      "Semantic search of the user's mirrored iMessage history by meaning, not exact substring. Pairs with `messages_search`: prefer this tool when the user asks 'find the text where we talked about something like X' and won't recall the exact wording. Substring `messages_search` is still right for exact phrase or sender lookups.",
    "calendar_semantic_search" =>
      "Semantic search of the user's mirrored macOS Calendar events by meaning, not exact substring. Pairs with `calendar_search`: prefer this tool when the user asks 'when's the meeting about something similar' and won't recall the exact title.",
    "reminders_semantic_search" =>
      "Semantic search of the user's mirrored macOS Reminders by meaning, not exact substring. Pairs with `reminders_search`: prefer this tool when the user asks 'do I have a reminder about something like X' and won't recall the exact title.",
    "files_semantic_search" =>
      "Semantic search of the user's mirrored macOS files (Documents / Desktop / Downloads) by meaning across filename, path, and extracted text content. Pairs with `files_search`: prefer this tool when the user asks 'find the doc where I wrote about something similar' and won't recall the exact filename or words."
  }

  @read_only_tools MapSet.new(~w(
    time http_get read_file list_files file_tree search_files
    gmail_list_recent gmail_search gmail_get_message
    google_contacts_search google_calendar_list_events
    review_connected_context get_open_loops list_todos list_people get_person get_relationship_context
    list_memories recall_memory
    slack_list_conversations slack_list_messages slack_get_thread_replies slack_search_messages
    linear_get_issue linear_list_issues linear_list_teams
    notaui_list_tasks
    notion_search notion_get_page notion_query_database
    notes_search notes_get notes_list_recent
    voice_memos_search voice_memos_get voice_memos_list_recent
    files_search files_get files_list_recent
    messages_search messages_get messages_list_recent messages_chats_recent
    reminders_open reminders_due_soon reminders_search reminders_get
    calendar_events_around calendar_events_for_person calendar_search calendar_event_get
    browser_history_recent browser_history_by_host browser_history_search browser_history_get
    recall_anywhere
    companion_devices_list
    notes_semantic_search voice_memos_semantic_search messages_semantic_search
    calendar_semantic_search reminders_semantic_search files_semantic_search
  ))

  @destructive_tools MapSet.new(~w(
    delete_person resolve_todo forget_memory gmail_batch_modify gmail_filters gmail_labels
    gmail_drafts notaui_complete_task notaui_update_task notion_update_page notion_blocks
  ))

  @external_send_tools MapSet.new(~w(
    gmail_send_message github_create_issue_comment slack_post_message
    linear_create_comment linear_create_issue linear_update_issue linear_update_issue_state
    linear_update_issue notion_create_page
  ))

  @write_tools MapSet.new(~w(
    upsert_todos upsert_person link_person_data learn_relationship_context
    write_memory record_memory_feedback
  ))

  @user_optional_tools MapSet.new(~w(
    time http_get read_file list_files file_tree search_files
  ))

  @idempotent_tools MapSet.new(~w(
    upsert_todos upsert_person learn_relationship_context write_memory
    record_memory_feedback link_person_data
    gmail_batch_modify notaui_update_task notion_update_page
  ))

  @default_status_labels %{
    "connected" => "Connected",
    "error" => "Needs attention",
    "disconnected" => "Reconnect required",
    "unknown" => "Unknown"
  }

  @connector_specs %{
    "google" => %{
      id: "google",
      type: "connector",
      display_name: "Google",
      provider: "google",
      oauth_scopes: ["openid", "email", "profile"],
      account_status_labels: @default_status_labels,
      event_types: ["oauth.connected", "oauth.refreshed", "connector.reauth"],
      tool_names: []
    },
    "gmail" => %{
      id: "gmail",
      type: "connector",
      display_name: "Gmail",
      provider: "google",
      oauth_scopes: [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send"
      ],
      account_status_labels: @default_status_labels,
      event_types: ["gmail.message", "gmail.thread", "gmail.history"],
      tool_names: ~w(
        gmail_list_recent gmail_search gmail_get_message gmail_send_message
        gmail_labels gmail_drafts gmail_batch_modify gmail_filters
      )
    },
    "google_calendar" => %{
      id: "google_calendar",
      type: "connector",
      display_name: "Google Calendar",
      provider: "google",
      oauth_scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
      account_status_labels: @default_status_labels,
      event_types: ["calendar.event", "calendar.sync"],
      tool_names: ~w(google_calendar_list_events)
    },
    "google_contacts" => %{
      id: "google_contacts",
      type: "connector",
      display_name: "Google Contacts",
      provider: "google",
      oauth_scopes: ["https://www.googleapis.com/auth/contacts.readonly"],
      account_status_labels: @default_status_labels,
      event_types: ["contacts.search"],
      tool_names: ~w(google_contacts_search)
    },
    "slack" => %{
      id: "slack",
      type: "connector",
      display_name: "Slack",
      provider: "slack",
      oauth_scopes: ["channels:history", "channels:read", "chat:write", "search:read"],
      account_status_labels: @default_status_labels,
      event_types: ["slack.message", "slack.thread", "slack.channel"],
      tool_names: ~w(
        slack_post_message slack_list_conversations slack_list_messages
        slack_get_thread_replies slack_search_messages slack_open_conversation
      )
    },
    "github" => %{
      id: "github",
      type: "connector",
      display_name: "GitHub",
      provider: "github",
      oauth_scopes: ["repo", "read:user"],
      account_status_labels: @default_status_labels,
      event_types: ["github.issue", "github.pull_request", "github.comment"],
      tool_names: ~w(github_create_issue_comment)
    },
    "linear" => %{
      id: "linear",
      type: "connector",
      display_name: "Linear",
      provider: "linear",
      oauth_scopes: ["read", "write"],
      account_status_labels: @default_status_labels,
      event_types: ["linear.issue", "linear.comment"],
      tool_names: ~w(
        linear_create_comment linear_create_issue linear_get_issue linear_list_issues
        linear_list_teams linear_update_issue linear_update_issue_state
      )
    },
    "telegram" => %{
      id: "telegram",
      type: "connector",
      display_name: "Telegram",
      provider: "telegram",
      oauth_scopes: [],
      account_status_labels: @default_status_labels,
      event_types: ["telegram.message", "telegram.callback", "telegram.push"],
      tool_names: []
    },
    "whatsapp" => %{
      id: "whatsapp",
      type: "connector",
      display_name: "WhatsApp",
      provider: "whatsapp",
      oauth_scopes: [],
      account_status_labels: @default_status_labels,
      event_types: ["whatsapp.message", "whatsapp.webhook"],
      tool_names: []
    },
    "notion" => %{
      id: "notion",
      type: "connector",
      display_name: "Notion",
      provider: "notion",
      oauth_scopes: [],
      account_status_labels: @default_status_labels,
      event_types: ["notion.page", "notion.database", "notion.block"],
      tool_names: ~w(
        notion_search notion_get_page notion_query_database notion_create_page
        notion_update_page notion_blocks
      )
    },
    "notaui" => %{
      id: "notaui",
      type: "connector",
      display_name: "Notaui",
      provider: "notaui",
      oauth_scopes: [],
      account_status_labels: @default_status_labels,
      event_types: ["notaui.task", "notaui.sync"],
      tool_names: ~w(notaui_list_tasks notaui_complete_task notaui_update_task)
    }
  }

  @provider_specs %{
    "openai" => %{
      id: "openai",
      type: "provider",
      display_name: "OpenAI",
      module: Maraithon.LLM.OpenAIProvider,
      requirements: %{env: ["OPENAI_API_KEY"], config: ["llm_model"]}
    },
    "anthropic" => %{
      id: "anthropic",
      type: "provider",
      display_name: "Anthropic",
      module: Maraithon.LLM.AnthropicProvider,
      requirements: %{env: ["ANTHROPIC_API_KEY"], config: ["anthropic_model"]}
    },
    "mock" => %{
      id: "mock",
      type: "provider",
      display_name: "Mock LLM",
      module: Maraithon.LLM.MockProvider,
      requirements: %{env: [], config: []}
    }
  }

  @required_connector_ids Map.keys(@connector_specs) |> Enum.sort()

  def register_tool(attrs), do: validate_tool_spec(attrs)
  def register_connector(attrs), do: validate_connector_spec(attrs)
  def register_provider(attrs), do: validate_provider_spec(attrs)

  def list_capabilities(kind \\ :all)

  def list_capabilities(kind) when kind in [:tool, "tool", :tools, "tools"] do
    @tool_modules
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&tool_spec!/1)
  end

  def list_capabilities(kind) when kind in [:connector, "connector", :connectors, "connectors"] do
    @connector_specs
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  def list_capabilities(kind) when kind in [:provider, "provider", :providers, "providers"] do
    @provider_specs
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  def list_capabilities(:all) do
    %{
      tools: list_capabilities(:tool),
      connectors: list_capabilities(:connector),
      providers: list_capabilities(:provider)
    }
  end

  def list_capabilities(_kind), do: []

  def requirements_for({:tool, name}) when is_binary(name), do: tool_requirements(name)
  def requirements_for({:connector, id}) when is_binary(id), do: connector_requirements(id)
  def requirements_for({:provider, id}) when is_binary(id), do: provider_requirements(id)

  def requirements_for(name) when is_binary(name) do
    cond do
      tool_registered?(name) -> tool_requirements(name)
      Map.has_key?(@connector_specs, name) -> connector_requirements(name)
      Map.has_key?(@provider_specs, name) -> provider_requirements(name)
      true -> nil
    end
  end

  def requirements_for(_capability), do: nil

  def policy_metadata_for(name) when is_binary(name) do
    if tool_registered?(name) do
      %{
        side_effect: side_effect_for(name),
        read_only?: MapSet.member?(@read_only_tools, name),
        destructive?: MapSet.member?(@destructive_tools, name),
        idempotent?: MapSet.member?(@idempotent_tools, name),
        user_required?: not MapSet.member?(@user_optional_tools, name),
        confirmation_required?: confirmation_required_tool?(name)
      }
    end
  end

  def policy_metadata_for(_name), do: nil

  def tool_module(name) when is_binary(name), do: Map.get(@tool_modules, name)
  def tool_module(_name), do: nil

  def tool_registered?(name) when is_binary(name), do: Map.has_key?(@tool_modules, name)
  def tool_registered?(_name), do: false

  def tool_names, do: @tool_modules |> Map.keys() |> Enum.sort()

  def tool_descriptors(names \\ nil) do
    names
    |> requested_tool_names()
    |> Enum.map(&tool_descriptor/1)
  end

  def tool_descriptor(name) when is_binary(name) do
    if tool_registered?(name) do
      %{
        name: name,
        description: Map.fetch!(@tool_descriptions, name),
        input_schema: InputSchemas.schema_for(name),
        annotations: tool_annotations(name)
      }
    end
  end

  def tool_descriptor(_name), do: nil

  def tool_annotations(name) when is_binary(name) do
    policy_metadata = policy_metadata_for(name)

    if policy_metadata do
      %{
        "title" => titleize(name),
        "readOnlyHint" => policy_metadata.read_only?,
        "destructiveHint" => policy_metadata.destructive?,
        "idempotentHint" => policy_metadata.idempotent?,
        "sideEffect" => policy_metadata.side_effect,
        "confirmationRequired" => policy_metadata.confirmation_required?
      }
    end
  end

  def tool_annotations(_name), do: nil

  def connector_metadata_for(id) when is_binary(id), do: Map.get(@connector_specs, id)
  def connector_metadata_for(_id), do: nil

  def provider_metadata_for(id) when is_binary(id), do: Map.get(@provider_specs, id)
  def provider_metadata_for(_id), do: nil

  def required_connector_ids, do: @required_connector_ids

  defp tool_spec!(name) do
    %{
      id: name,
      type: "tool",
      name: name,
      module: Map.fetch!(@tool_modules, name),
      description: Map.fetch!(@tool_descriptions, name),
      input_schema: InputSchemas.schema_for(name),
      annotations: tool_annotations(name),
      policy_metadata: policy_metadata_for(name),
      requirements: tool_requirements(name)
    }
  end

  defp requested_tool_names(nil), do: tool_names()
  defp requested_tool_names([]), do: tool_names()

  defp requested_tool_names(names) when is_list(names) do
    names
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&tool_registered?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp requested_tool_names(_names), do: tool_names()

  defp tool_requirements(name) do
    connectors =
      @connector_specs
      |> Map.values()
      |> Enum.filter(&(name in &1.tool_names))
      |> Enum.map(& &1.id)
      |> Enum.sort()

    %{
      connectors: connectors,
      user_context_required: not MapSet.member?(@user_optional_tools, name)
    }
  end

  defp connector_requirements(id) do
    case Map.get(@connector_specs, id) do
      nil -> nil
      spec -> %{oauth_scopes: spec.oauth_scopes, tools: spec.tool_names}
    end
  end

  defp provider_requirements(id) do
    case Map.get(@provider_specs, id) do
      nil -> nil
      spec -> spec.requirements
    end
  end

  defp validate_tool_spec(attrs) when is_map(attrs) do
    with {:ok, name} <- required_string(attrs, :name),
         {:ok, module} <- required_value(attrs, :module),
         {:ok, description} <- required_string(attrs, :description),
         {:ok, policy_metadata} <- validate_policy_metadata(Map.get(attrs, :policy_metadata)) do
      {:ok,
       %{
         id: name,
         type: "tool",
         name: name,
         module: module,
         description: description,
         policy_metadata: policy_metadata
       }}
    end
  end

  defp validate_tool_spec(_attrs), do: {:error, :invalid_tool_capability}

  defp validate_connector_spec(attrs) when is_map(attrs) do
    with {:ok, id} <- required_string(attrs, :id),
         {:ok, display_name} <- required_string(attrs, :display_name),
         {:ok, provider} <- required_string(attrs, :provider) do
      {:ok,
       %{
         id: id,
         type: "connector",
         display_name: display_name,
         provider: provider,
         oauth_scopes: string_list(Map.get(attrs, :oauth_scopes, [])),
         event_types: string_list(Map.get(attrs, :event_types, [])),
         tool_names: string_list(Map.get(attrs, :tool_names, []))
       }}
    end
  end

  defp validate_connector_spec(_attrs), do: {:error, :invalid_connector_capability}

  defp validate_provider_spec(attrs) when is_map(attrs) do
    with {:ok, id} <- required_string(attrs, :id),
         {:ok, display_name} <- required_string(attrs, :display_name),
         {:ok, module} <- required_value(attrs, :module) do
      {:ok,
       %{
         id: id,
         type: "provider",
         display_name: display_name,
         module: module,
         requirements: Map.get(attrs, :requirements, %{})
       }}
    end
  end

  defp validate_provider_spec(_attrs), do: {:error, :invalid_provider_capability}

  defp validate_policy_metadata(nil), do: {:error, :missing_policy_metadata}

  defp validate_policy_metadata(metadata) when is_map(metadata) do
    side_effect = metadata[:side_effect] || metadata["side_effect"]

    if side_effect in ~w(read write destructive external_send credential system) do
      {:ok,
       %{
         side_effect: side_effect,
         read_only?: truthy?(metadata[:read_only?] || metadata["read_only?"]),
         destructive?: truthy?(metadata[:destructive?] || metadata["destructive?"]),
         idempotent?: truthy?(metadata[:idempotent?] || metadata["idempotent?"]),
         user_required?: truthy?(metadata[:user_required?] || metadata["user_required?"]),
         confirmation_required?:
           truthy?(metadata[:confirmation_required?] || metadata["confirmation_required?"])
       }}
    else
      {:error, :invalid_policy_metadata}
    end
  end

  defp validate_policy_metadata(_metadata), do: {:error, :invalid_policy_metadata}

  defp required_string(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, {:missing_field, key}}, else: {:ok, value}

      _other ->
        {:error, {:missing_field, key}}
    end
  end

  defp required_value(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp string_list(_values), do: []

  defp side_effect_for(name) do
    cond do
      MapSet.member?(@read_only_tools, name) -> "read"
      MapSet.member?(@destructive_tools, name) -> "destructive"
      MapSet.member?(@external_send_tools, name) -> "external_send"
      MapSet.member?(@write_tools, name) -> "write"
      true -> "system"
    end
  end

  defp confirmation_required_tool?(name) do
    MapSet.member?(@destructive_tools, name) or MapSet.member?(@external_send_tools, name)
  end

  defp titleize(name) do
    name
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false
end
