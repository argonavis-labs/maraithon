defmodule Maraithon.TelegramAssistant.Toolbox do
  @moduledoc """
  Curated Telegram-safe tool surface for the unified operator assistant.
  """

  alias Maraithon.Admin
  alias Maraithon.AgentBuilder
  alias Maraithon.Agents
  alias Maraithon.ActionLedger
  alias Maraithon.BriefingSchedules
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Connectors.Linear
  alias Maraithon.Insights
  alias Maraithon.Memory
  alias Maraithon.OperatorMemory
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Linear, as: LinearOAuth
  alias Maraithon.OpenLoops
  alias Maraithon.PreferenceMemory
  alias Maraithon.Projects
  alias Maraithon.Repo
  alias Maraithon.Runtime
  alias Maraithon.ScheduledTasks
  alias Maraithon.SourceFreshness
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.Todos
  alias Maraithon.ToolPolicy
  alias Maraithon.Tools
  alias Maraithon.UserMemory

  @immediate_agent_actions ~w(start stop restart)
  @gmail_insight_stale_threshold_hours 72
  @external_action_tools %{
    "gmail_send" => %{
      tool: "gmail_send_message",
      target_type: "gmail_thread"
    },
    "slack_post" => %{
      tool: "slack_post_message",
      target_type: "slack_channel"
    },
    "linear_create_issue" => %{
      tool: "linear_create_issue",
      target_type: "linear_issue"
    },
    "linear_create_comment" => %{
      tool: "linear_create_comment",
      target_type: "linear_issue"
    },
    "linear_update_issue_state" => %{
      tool: "linear_update_issue_state",
      target_type: "linear_issue"
    },
    "notaui_complete_task" => %{
      tool: "notaui_complete_task",
      target_type: "task"
    },
    "notaui_update_task" => %{
      tool: "notaui_update_task",
      target_type: "task"
    }
  }

  @toolbox_read_tools MapSet.new(~w(
    get_open_work_summary get_open_loops inspect_open_insight list_preferences
    list_memories recall_memory list_todos list_people get_person get_relationship_context
    review_connected_context gmail_search_messages gmail_get_message calendar_list_events
    slack_search_messages slack_get_thread_context linear_list_or_lookup notaui_list_tasks
    list_projects inspect_project list_implementation_runs list_agents inspect_agent
    list_scheduled_tasks
    explain_action_ledger
    notes_search notes_get notes_list_recent
    voice_memos_search voice_memos_get voice_memos_list_recent
    files_search files_get files_list_recent
    reminders_open reminders_due_soon reminders_search reminders_get
    calendar_events_around calendar_events_for_person calendar_search calendar_event_get
    browser_history_recent browser_history_by_host browser_history_search browser_history_get
  ))

  @toolbox_write_tools MapSet.new(~w(
    update_briefing_schedule remember_preferences forget_preference write_memory
    record_memory_feedback forget_memory upsert_todos resolve_todo upsert_person
    link_person_data learn_relationship_context delete_person update_project_scope
    decide_project_recommendation grant_project_repo_access start_implementation_run
    update_implementation_run prepare_project_action prepare_agent_action
    prepare_external_action query_agent create_scheduled_task pause_scheduled_task
    cancel_scheduled_task
  ))

  def tool_definitions(_context) do
    [
      tool_definition(
        "get_open_work_summary",
        "Summarize open work, recent insights, and active agents for the linked user.",
        %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 10}
          }
        }
      ),
      tool_definition(
        "get_open_loops",
        "Fetch the linked user's durable open-loop snapshot across todos, CRM relationships, and deep memory.",
        %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "inspect_open_insight",
        "Inspect one open insight or the latest linked insight detail.",
        %{
          "type" => "object",
          "properties" => %{
            "insight_id" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "explain_action_ledger",
        "Explain a recent Maraithon action from the redacted action ledger.",
        %{
          "type" => "object",
          "properties" => %{
            "action_id" => %{"type" => "string"},
            "object_type" => %{"type" => "string"},
            "object_id" => %{"type" => "string"},
            "event_type" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "update_briefing_schedule",
        "Update the user's recurring briefing schedule in local time.",
        %{
          "type" => "object",
          "required" => ["briefing_kind", "local_hour"],
          "properties" => %{
            "briefing_kind" => %{"type" => "string"},
            "local_hour" => %{"type" => "integer", "minimum" => 0, "maximum" => 23},
            "local_day_of_week" => %{"type" => "integer", "minimum" => 1, "maximum" => 7},
            "timezone_offset_hours" => %{
              "type" => "integer",
              "minimum" => -12,
              "maximum" => 14
            },
            "agent_id" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "list_scheduled_tasks",
        "List the linked user's scheduled tasks.",
        %{
          "type" => "object",
          "properties" => %{
            "status" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "create_scheduled_task",
        "Create a user-facing scheduled task from a Telegram turn.",
        %{
          "type" => "object",
          "required" => ["title"],
          "properties" => %{
            "title" => %{"type" => "string"},
            "description" => %{"type" => "string"},
            "once_at" => %{"type" => "string"},
            "daily_at" => %{"type" => "string"},
            "weekly_day" => %{"type" => "string"},
            "weekly_at" => %{"type" => "string"},
            "schedule" => %{"type" => "object"},
            "prompt" => %{"type" => "string"},
            "command" => %{"type" => "object"},
            "failure_destination" => %{"type" => "object"},
            "metadata" => %{"type" => "object"}
          }
        }
      ),
      tool_definition(
        "pause_scheduled_task",
        "Pause one linked user's scheduled task.",
        %{
          "type" => "object",
          "required" => ["task_id"],
          "properties" => %{"task_id" => %{"type" => "string"}}
        }
      ),
      tool_definition(
        "cancel_scheduled_task",
        "Cancel one linked user's scheduled task.",
        %{
          "type" => "object",
          "required" => ["task_id"],
          "properties" => %{"task_id" => %{"type" => "string"}}
        }
      ),
      tool_definition(
        "list_preferences",
        "List the linked user's durable preference rules, operator memory summaries, and learned user profile.",
        %{
          "type" => "object",
          "properties" => %{}
        }
      ),
      tool_definition(
        "remember_preferences",
        "Persist one or more durable operator preference rules inferred from conversation.",
        %{
          "type" => "object",
          "required" => ["rules"],
          "properties" => %{
            "rules" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "required" => [
                  "id",
                  "kind",
                  "label",
                  "instruction",
                  "applies_to",
                  "confidence",
                  "filters"
                ],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "kind" => %{"type" => "string"},
                  "label" => %{"type" => "string"},
                  "instruction" => %{"type" => "string"},
                  "applies_to" => %{"type" => "array", "items" => %{"type" => "string"}},
                  "confidence" => %{"type" => "number"},
                  "filters" => %{"type" => "object"},
                  "evidence" => %{"type" => "array", "items" => %{"type" => "string"}}
                }
              }
            }
          }
        }
      ),
      tool_definition(
        "forget_preference",
        "Forget one saved durable operator preference rule.",
        %{
          "type" => "object",
          "required" => ["rule_id"],
          "properties" => %{
            "rule_id" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "list_memories",
        "List the linked user's durable deep memory items.",
        %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "status" => %{"type" => "string"},
            "kind" => %{"type" => "string"},
            "scope" => %{"type" => "string"},
            "tag" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "recall_memory",
        "Recall relevant durable deep memories for a query using model-level memory intelligence.",
        %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "kind" => %{"type" => "string"},
            "scope" => %{"type" => "string"},
            "tag" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 40}
          }
        }
      ),
      tool_definition(
        "write_memory",
        "Create or update a durable deep memory item for the linked user.",
        %{
          "type" => "object",
          "required" => ["memory"],
          "properties" => %{
            "memory" => %{
              "type" => "object",
              "required" => ["content"],
              "properties" => %{
                "memory_id" => %{"type" => "string"},
                "kind" => %{"type" => "string"},
                "scope" => %{"type" => "string"},
                "title" => %{"type" => "string"},
                "content" => %{"type" => "string"},
                "summary" => %{"type" => "string"},
                "source" => %{"type" => "string"},
                "author_type" => %{"type" => "string"},
                "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
                "importance" => %{"type" => "integer", "minimum" => 0, "maximum" => 100},
                "confidence" => %{"type" => "number"},
                "polarity" => %{"type" => "string"},
                "dedupe_key" => %{"type" => "string"},
                "metadata" => %{"type" => "object"}
              }
            }
          }
        }
      ),
      tool_definition(
        "record_memory_feedback",
        "Record that something is relevant or not relevant as durable deep memory.",
        %{
          "type" => "object",
          "required" => ["subject", "feedback"],
          "properties" => %{
            "subject" => %{"type" => "string"},
            "feedback" => %{"type" => "string"},
            "reason" => %{"type" => "string"},
            "resource_type" => %{"type" => "string"},
            "resource_id" => %{"type" => "string"},
            "source" => %{"type" => "string"},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
            "metadata" => %{"type" => "object"}
          }
        }
      ),
      tool_definition(
        "forget_memory",
        "Archive, supersede, or reject one durable deep memory item.",
        %{
          "type" => "object",
          "properties" => %{
            "memory_id" => %{"type" => "string"},
            "query" => %{"type" => "string"},
            "status" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "list_todos",
        "List the linked user's persisted todos and their statuses.",
        %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "statuses" => %{"type" => "array", "items" => %{"type" => "string"}},
            "source" => %{"type" => "string"},
            "source_account_id" => %{"type" => "integer"},
            "kind" => %{"type" => "string"},
            "attention_mode" => %{"type" => "string"},
            "owner_user_id" => %{"type" => "string"},
            "due_before" => %{"type" => "string"},
            "due_after" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "upsert_todos",
        "Create, update, or skip persisted todos for the linked user using model-level todo intelligence and semantic dedupe.",
        %{
          "type" => "object",
          "required" => ["todos"],
          "properties" => %{
            "todos" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "required" => ["source", "title", "summary", "next_action"],
                "properties" => %{
                  "source" => %{"type" => "string"},
                  "kind" => %{"type" => "string"},
                  "attention_mode" => %{"type" => "string"},
                  "title" => %{"type" => "string"},
                  "summary" => %{"type" => "string"},
                  "next_action" => %{"type" => "string"},
                  "due_at" => %{"type" => "string"},
                  "due_date" => %{"type" => "string"},
                  "notes" => %{"type" => "string"},
                  "action_plan" => %{"type" => "string"},
                  "action_draft" => %{"type" => "object"},
                  "owner_user_id" => %{"type" => "string"},
                  "owner_label" => %{"type" => "string"},
                  "source_account_id" => %{"type" => "integer"},
                  "source_account_label" => %{"type" => "string"},
                  "priority" => %{"type" => "integer"},
                  "status" => %{"type" => "string"},
                  "source_item_id" => %{"type" => "string"},
                  "source_occurred_at" => %{"type" => "string"},
                  "dedupe_key" => %{"type" => "string"},
                  "metadata" => %{"type" => "object"}
                }
              }
            }
          }
        }
      ),
      tool_definition(
        "resolve_todo",
        "Mark one persisted todo done, dismissed, or snoozed.",
        %{
          "type" => "object",
          "required" => ["todo_id"],
          "properties" => %{
            "todo_id" => %{"type" => "string"},
            "status" => %{"type" => "string"},
            "resolution_note" => %{"type" => "string"},
            "snooze_until" => %{"type" => "string"},
            "include_remaining" => %{"type" => "boolean"},
            "source" => %{"type" => "string"},
            "source_account_id" => %{"type" => "integer"},
            "kind" => %{"type" => "string"},
            "attention_mode" => %{"type" => "string"},
            "owner_user_id" => %{"type" => "string"},
            "due_before" => %{"type" => "string"},
            "due_after" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "list_people",
        "List the linked user's CRM people and relationship metadata.",
        %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "relationship" => %{"type" => "string"},
            "preferred_communication_method" => %{"type" => "string"},
            "communication_frequency" => %{"type" => "string"},
            "contact_kind" => %{"type" => "string"},
            "contact_value" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "get_person",
        "Get one CRM person by id, search query, or contact detail.",
        %{
          "type" => "object",
          "properties" => %{
            "person_id" => %{"type" => "string"},
            "query" => %{"type" => "string"},
            "contact_kind" => %{"type" => "string"},
            "contact_value" => %{"type" => "string"},
            "include_links" => %{"type" => "boolean"},
            "link_limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "upsert_person",
        "Create or update one CRM person with contact details, preferred communication, relationship, and speaking frequency.",
        %{
          "type" => "object",
          "properties" => %{
            "person" => %{
              "type" => "object",
              "properties" => %{
                "person_id" => %{"type" => "string"},
                "first_name" => %{"type" => "string"},
                "last_name" => %{"type" => "string"},
                "display_name" => %{"type" => "string"},
                "contact_details" => %{"type" => "object"},
                "email" => %{"type" => "string"},
                "phone" => %{"type" => "string"},
                "slack_id" => %{"type" => "string"},
                "preferred_communication_method" => %{"type" => "string"},
                "relationship" => %{"type" => "string"},
                "communication_frequency" => %{"type" => "string"},
                "notes" => %{"type" => "string"},
                "metadata" => %{"type" => "object"}
              }
            }
          }
        }
      ),
      tool_definition(
        "link_person_data",
        "Attach or detach a CRM person from a todo or another user-owned object.",
        %{
          "type" => "object",
          "required" => ["person_id"],
          "properties" => %{
            "person_id" => %{"type" => "string"},
            "operation" => %{"type" => "string"},
            "resource_type" => %{"type" => "string"},
            "resource_id" => %{"type" => "string"},
            "todo_id" => %{"type" => "string"},
            "resource_source" => %{"type" => "string"},
            "title" => %{"type" => "string"},
            "summary" => %{"type" => "string"},
            "relationship_note" => %{"type" => "string"},
            "metadata" => %{"type" => "object"},
            "include_context" => %{"type" => "boolean"}
          }
        }
      ),
      tool_definition(
        "get_relationship_context",
        "Fetch CRM relationship context for one person, including linked todos.",
        %{
          "type" => "object",
          "properties" => %{
            "person_id" => %{"type" => "string"},
            "query" => %{"type" => "string"},
            "contact_kind" => %{"type" => "string"},
            "contact_value" => %{"type" => "string"},
            "link_limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "learn_relationship_context",
        "Learn CRM people, relationship memories, and source links from recent source observations using model-level relationship intelligence.",
        %{
          "type" => "object",
          "required" => ["observations"],
          "properties" => %{
            "source" => %{"type" => "string"},
            "observations" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "source" => %{"type" => "string"},
                  "resource_type" => %{"type" => "string"},
                  "resource_id" => %{"type" => "string"},
                  "title" => %{"type" => "string"},
                  "summary" => %{"type" => "string"},
                  "from" => %{"type" => "string"},
                  "to" => %{"type" => "string"},
                  "account" => %{"type" => "string"},
                  "occurred_at" => %{"type" => "string"},
                  "body_excerpt" => %{"type" => "string"},
                  "metadata" => %{"type" => "object"}
                }
              }
            }
          }
        }
      ),
      tool_definition(
        "delete_person",
        "Delete one CRM person only when the user explicitly asks to remove that CRM record.",
        %{
          "type" => "object",
          "required" => ["person_id"],
          "properties" => %{"person_id" => %{"type" => "string"}}
        }
      ),
      tool_definition(
        "gmail_search_messages",
        "Search Gmail threads or messages for the linked user.",
        %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string"},
            "max_results" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "review_connected_context",
        "Review connected CRM, Gmail, Google Contacts, Calendar, Slack, open loops, and memory in one fast source-gathering call.",
        %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "person" => %{"type" => "string"},
            "review_goal" => %{"type" => "string"},
            "sources" => %{"type" => "array", "items" => %{"type" => "string"}},
            "gmail_query" => %{"type" => "string"},
            "time_min" => %{"type" => "string"},
            "time_max" => %{"type" => "string"},
            "since_days" => %{"type" => "integer", "minimum" => 1, "maximum" => 365},
            "max_results" => %{"type" => "integer", "minimum" => 1, "maximum" => 12}
          }
        }
      ),
      tool_definition(
        "gmail_get_message",
        "Fetch one Gmail message by message id, including decoded full body content when available.",
        %{
          "type" => "object",
          "required" => ["message_id"],
          "properties" => %{
            "message_id" => %{"type" => "string"},
            "google_provider" => %{"type" => "string"},
            "google_account_email" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "calendar_list_events",
        "List Google Calendar events for the linked user.",
        %{
          "type" => "object",
          "properties" => %{
            "calendar_id" => %{"type" => "string"},
            "query" => %{"type" => "string"},
            "time_min" => %{"type" => "string"},
            "time_max" => %{"type" => "string"},
            "max_results" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          }
        }
      ),
      tool_definition(
        "slack_search_messages",
        "Search Slack message context using the linked user's connected workspace.",
        %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "team_id" => %{"type" => "string"},
            "query" => %{"type" => "string"},
            "count" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          }
        }
      ),
      tool_definition(
        "slack_get_thread_context",
        "Fetch a Slack thread and replies from one channel.",
        %{
          "type" => "object",
          "required" => ["channel", "thread_ts"],
          "properties" => %{
            "team_id" => %{"type" => "string"},
            "channel" => %{"type" => "string"},
            "thread_ts" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 200}
          }
        }
      ),
      tool_definition(
        "linear_list_or_lookup",
        "List Linear teams or look up one issue by identifier.",
        %{
          "type" => "object",
          "properties" => %{
            "identifier" => %{"type" => "string"},
            "team_id" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
          }
        }
      ),
      tool_definition(
        "notaui_list_tasks",
        "List tasks from Notaui.",
        %{
          "type" => "object",
          "properties" => %{
            "account_id" => %{"type" => "string"},
            "project_id" => %{"type" => "string"},
            "statuses" => %{"type" => "array", "items" => %{"type" => "string"}},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          }
        }
      ),
      tool_definition(
        "list_projects",
        "List the linked user's projects and their compact operating summaries.",
        %{
          "type" => "object",
          "properties" => %{
            "status" => %{"type" => "string"},
            "priority" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "inspect_project",
        "Inspect one project by id, slug, or human name, including local memory, attached agents, and top project-manager recommendations.",
        %{
          "type" => "object",
          "properties" => %{
            "project_id" => %{"type" => "string"},
            "project_slug" => %{"type" => "string"},
            "project_name" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "update_project_scope",
        "Set whether a project is primarily work or home, using explicit project arguments or the linked project in context.",
        %{
          "type" => "object",
          "required" => ["life_domain"],
          "properties" => %{
            "project_id" => %{"type" => "string"},
            "project_slug" => %{"type" => "string"},
            "project_name" => %{"type" => "string"},
            "life_domain" => %{"type" => "string"},
            "confidence" => %{"type" => "number"},
            "reasoning" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "decide_project_recommendation",
        "Accept, defer, or reject one project-manager recommendation as a durable workflow decision.",
        %{
          "type" => "object",
          "required" => ["recommendation_id", "decision"],
          "properties" => %{
            "recommendation_id" => %{"type" => "string"},
            "decision" => %{"type" => "string"},
            "decision_note" => %{"type" => "string"},
            "project_id" => %{"type" => "string"},
            "project_slug" => %{"type" => "string"},
            "project_name" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "grant_project_repo_access",
        "Record an explicit GitHub repo access grant for one project.",
        %{
          "type" => "object",
          "required" => ["repo_full_name", "scope"],
          "properties" => %{
            "repo_full_name" => %{"type" => "string"},
            "scope" => %{"type" => "string"},
            "provider" => %{"type" => "string"},
            "project_id" => %{"type" => "string"},
            "project_slug" => %{"type" => "string"},
            "project_name" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "start_implementation_run",
        "Start a tracked implementation run for one accepted project recommendation.",
        %{
          "type" => "object",
          "required" => ["recommendation_id"],
          "properties" => %{
            "recommendation_id" => %{"type" => "string"},
            "decision_note" => %{"type" => "string"},
            "repo_full_name" => %{"type" => "string"},
            "project_id" => %{"type" => "string"},
            "project_slug" => %{"type" => "string"},
            "project_name" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "list_implementation_runs",
        "List tracked implementation runs for one project or for all projects.",
        %{
          "type" => "object",
          "properties" => %{
            "project_id" => %{"type" => "string"},
            "project_slug" => %{"type" => "string"},
            "project_name" => %{"type" => "string"},
            "statuses" => %{"type" => "array", "items" => %{"type" => "string"}},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
          }
        }
      ),
      tool_definition(
        "update_implementation_run",
        "Record progress, blockers, branch details, or PR links for one tracked implementation run.",
        %{
          "type" => "object",
          "required" => ["implementation_run_id"],
          "properties" => %{
            "implementation_run_id" => %{"type" => "string"},
            "status" => %{"type" => "string"},
            "branch_name" => %{"type" => "string"},
            "pull_request_url" => %{"type" => "string"},
            "result_summary" => %{"type" => "string"},
            "metadata" => %{"type" => "object"}
          }
        }
      ),
      tool_definition(
        "prepare_project_action",
        "Prepare creation or update of a project for confirmation.",
        %{
          "type" => "object",
          "required" => ["action"],
          "properties" => %{
            "action" => %{"type" => "string"},
            "project_id" => %{"type" => "string"},
            "project_slug" => %{"type" => "string"},
            "attrs" => %{"type" => "object"}
          }
        }
      ),
      tool_definition(
        "list_agents",
        "List the linked user's saved agents and runtime status.",
        %{
          "type" => "object",
          "properties" => %{
            "status" => %{"type" => "string"},
            "behavior" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "inspect_agent",
        "Inspect one agent, including runtime, spend, logs, events, and queued work.",
        %{
          "type" => "object",
          "required" => ["agent_id"],
          "properties" => %{"agent_id" => %{"type" => "string"}}
        }
      ),
      tool_definition(
        "prepare_agent_action",
        "Prepare or execute an agent lifecycle or CRUD action.",
        %{
          "type" => "object",
          "required" => ["action"],
          "properties" => %{
            "action" => %{"type" => "string"},
            "agent_id" => %{"type" => "string"},
            "launch" => %{"type" => "object"}
          }
        }
      ),
      tool_definition(
        "prepare_external_action",
        "Prepare a Gmail, Slack, Linear, or Notaui write action for confirmation.",
        %{
          "type" => "object",
          "required" => ["action_type", "payload"],
          "properties" => %{
            "action_type" => %{"type" => "string"},
            "payload" => %{"type" => "object"}
          }
        }
      ),
      tool_definition(
        "query_agent",
        "Ask a running agent a question and wait briefly for a response.",
        %{
          "type" => "object",
          "required" => ["agent_id", "message"],
          "properties" => %{
            "agent_id" => %{"type" => "string"},
            "message" => %{"type" => "string"},
            "timeout_ms" => %{"type" => "integer", "minimum" => 1000, "maximum" => 30000}
          }
        }
      ),
      tool_definition(
        "notes_search",
        "Search the user's Apple Notes for a substring in title or body. Use when the user references a note by topic, name, or content they remember writing down.",
        %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
            "folder" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "notes_get",
        "Fetch a single Apple Note by its id. Use after notes_search returns candidates and you need the full snippet/folder/timestamps.",
        %{
          "type" => "object",
          "required" => ["note_id"],
          "properties" => %{
            "note_id" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "notes_list_recent",
        "List the user's Apple Notes ordered by most recently modified. Use when the user asks what they wrote down recently or wants a sweep of fresh notes.",
        %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
            "folder" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "voice_memos_search",
        "Search the user's Apple Voice Memos by title substring. Use when the user mentions a recording they made or asks about a past dictation.",
        %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "voice_memos_get",
        "Fetch a single Apple Voice Memo by its id. Use after voice_memos_search returns candidates and you need duration, size, and timestamps.",
        %{
          "type" => "object",
          "required" => ["memo_id"],
          "properties" => %{
            "memo_id" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "voice_memos_list_recent",
        "List the user's Apple Voice Memos ordered by most recently created. Use when the user asks about recent recordings or wants a sweep of fresh dictations.",
        %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "files_search",
        "Search the user's mirrored macOS files (Documents, Desktop, Downloads) by substring across filename, path, and extracted text content. Use when the user references a file they wrote, downloaded, or saved (PDF, doc, markdown, text). Optional extension and path_substring filters narrow the result set.",
        %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
            "extension" => %{"type" => "string"},
            "path_substring" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "files_get",
        "Fetch a single mirrored macOS file by its id, including the full extracted text content (capped at 30 KB). Use after files_search returns candidates and you need the body, not just the snippet.",
        %{
          "type" => "object",
          "required" => ["file_id"],
          "properties" => %{
            "file_id" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "files_list_recent",
        "List the user's mirrored macOS files ordered by most recently modified. Use when the user asks 'what files did I save recently?' or wants a sweep of new documents.",
        %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
            "extension" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "messages_search",
        "Search the user's iMessage history for a substring in the message text. Use when the user references a text from someone, by topic, by sender, or within a date range.",
        %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
            "from_handle" => %{"type" => "string"},
            "since" => %{"type" => "string"},
            "before" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "messages_get",
        "Fetch a single iMessage by its id. Use after messages_search returns candidates and you need the full text body and chat metadata.",
        %{
          "type" => "object",
          "required" => ["message_id"],
          "properties" => %{
            "message_id" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "messages_list_recent",
        "List the user's most recent iMessages, newest first. Optionally restrict to one chat by chat_key.",
        %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "chat_key" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "messages_chats_recent",
        "List the user's most recently active iMessage chats with the latest message in each and a 7-day message count. Use as the entry point when the user asks what conversations are active or wants a sweep of recent texts.",
        %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        }
      ),
      tool_definition(
        "reminders_open",
        "List the user's open Apple Reminders ordered by due date then priority. Use as the entry point when the user asks about reminders, things they need to do, or their to-do list (the durable Reminders.app list, not assistant-written todos).",
        %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "list_name" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "reminders_due_soon",
        "List the user's open Apple Reminders due within the next N days (default 7), including overdue. Use when the user asks 'what's due soon?', 'what's coming up?', or 'what's overdue?'.",
        %{
          "type" => "object",
          "properties" => %{
            "days_ahead" => %{"type" => "integer", "minimum" => 1, "maximum" => 365},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "list_name" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "reminders_search",
        "Search the user's Apple Reminders for a substring in title, notes, or list name. Use when the user asks if they have a reminder about a specific topic.",
        %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "list_name" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "reminders_get",
        "Fetch a single Apple Reminder by its id. Use after reminders_search or reminders_open returns candidates and you need the full notes body, completion timestamp, or url attachment.",
        %{
          "type" => "object",
          "required" => ["reminder_id"],
          "properties" => %{
            "reminder_id" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "calendar_events_around",
        "List the user's macOS Calendar events overlapping a date window (default: now to +7 days). The Mac's Calendar.app aggregates iCloud, Exchange, Google CalDAV, etc. — prefer this over the Google Calendar connector when both are available. Use for schedule questions (today, tomorrow, this week, what's on my calendar).",
        %{
          "type" => "object",
          "properties" => %{
            "since" => %{"type" => "string"},
            "until" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          }
        }
      ),
      tool_definition(
        "calendar_events_for_person",
        "Find Calendar events that involve a specific person, matched by email or name substring against attendees, organizer, and title. Use when the user asks about meetings with a particular person.",
        %{
          "type" => "object",
          "required" => ["email_or_substring"],
          "properties" => %{
            "email_or_substring" => %{"type" => "string"},
            "since" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          }
        }
      ),
      tool_definition(
        "calendar_search",
        "Substring-search the user's Calendar events on title, notes, and location. Use for topic-based queries like 'when's the launch review?'.",
        %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string"},
            "since" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          }
        }
      ),
      tool_definition(
        "calendar_event_get",
        "Fetch a single Calendar event by its EventKit id. Use after calendar_events_around or calendar_search returns candidates and you need the full notes body and attendee list.",
        %{
          "type" => "object",
          "required" => ["event_id"],
          "properties" => %{
            "event_id" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "browser_history_recent",
        "List the user's most recently visited URLs across Chrome / Safari / Arc / Brave, newest first. Use as the entry point for sweeping 'what have I been looking at?' questions.",
        %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "browser" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "browser_history_by_host",
        "Filter the user's browser history by host substring (e.g. 'techmeme'). Use when the user asks about an article from a specific site.",
        %{
          "type" => "object",
          "required" => ["host"],
          "properties" => %{
            "host" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "browser" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "browser_history_search",
        "Search the user's browser history for a substring in title, URL, or host. Use when the user references something they were reading or researching online by topic.",
        %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "browser" => %{"type" => "string"}
          }
        }
      ),
      tool_definition(
        "browser_history_get",
        "Fetch a single browser visit by its source GUID. Use after browser_history_search / browser_history_by_host returns candidates and you need the full URL and title.",
        %{
          "type" => "object",
          "required" => ["visit_id"],
          "properties" => %{
            "visit_id" => %{"type" => "string"}
          }
        }
      )
    ]
  end

  def execute(tool_name, args, runtime_context)
      when is_binary(tool_name) and is_map(args) and is_map(runtime_context) do
    policy_context = toolbox_policy_context(tool_name, args, runtime_context)

    ToolPolicy.enforce(policy_context, fn ->
      do_execute(tool_name, args, runtime_context)
    end)
  end

  defp do_execute(tool_name, args, runtime_context) do
    case tool_name do
      "get_open_work_summary" ->
        get_open_work_summary(runtime_context, args)

      "get_open_loops" ->
        get_open_loops(runtime_context, args)

      "inspect_open_insight" ->
        inspect_open_insight(runtime_context, args)

      "explain_action_ledger" ->
        explain_action_ledger(runtime_context, args)

      "update_briefing_schedule" ->
        update_briefing_schedule(runtime_context, args)

      "list_scheduled_tasks" ->
        list_scheduled_tasks(runtime_context, args)

      "create_scheduled_task" ->
        create_scheduled_task(runtime_context, args)

      "pause_scheduled_task" ->
        pause_scheduled_task(runtime_context, args)

      "cancel_scheduled_task" ->
        cancel_scheduled_task(runtime_context, args)

      "list_preferences" ->
        list_preferences(runtime_context)

      "remember_preferences" ->
        remember_preferences(runtime_context, args)

      "forget_preference" ->
        forget_preference(runtime_context, args)

      "list_memories" ->
        inject_user_and_execute("list_memories", runtime_context, args)

      "recall_memory" ->
        inject_user_and_execute("recall_memory", runtime_context, args)

      "write_memory" ->
        inject_user_and_execute("write_memory", runtime_context, args)

      "record_memory_feedback" ->
        inject_user_and_execute("record_memory_feedback", runtime_context, args)

      "forget_memory" ->
        inject_user_and_execute("forget_memory", runtime_context, args)

      "list_todos" ->
        list_todos(runtime_context, args)

      "upsert_todos" ->
        upsert_todos(runtime_context, args)

      "resolve_todo" ->
        resolve_todo(runtime_context, args)

      "list_people" ->
        inject_user_and_execute("list_people", runtime_context, args)

      "get_person" ->
        inject_user_and_execute("get_person", runtime_context, args)

      "upsert_person" ->
        inject_user_and_execute("upsert_person", runtime_context, args)

      "link_person_data" ->
        inject_user_and_execute("link_person_data", runtime_context, args)

      "get_relationship_context" ->
        inject_user_and_execute("get_relationship_context", runtime_context, args)

      "learn_relationship_context" ->
        inject_user_and_execute("learn_relationship_context", runtime_context, args)

      "delete_person" ->
        inject_user_and_execute("delete_person", runtime_context, args)

      "review_connected_context" ->
        inject_user_and_execute("review_connected_context", runtime_context, args)

      "gmail_search_messages" ->
        inject_user_and_execute("gmail_search", runtime_context, args)

      "gmail_get_message" ->
        inject_user_and_execute("gmail_get_message", runtime_context, args)

      "calendar_list_events" ->
        inject_user_and_execute("google_calendar_list_events", runtime_context, args)

      "slack_search_messages" ->
        slack_search(runtime_context, args)

      "slack_get_thread_context" ->
        slack_thread_context(runtime_context, args)

      "linear_list_or_lookup" ->
        linear_list_or_lookup(runtime_context, args)

      "notaui_list_tasks" ->
        inject_user_and_execute("notaui_list_tasks", runtime_context, args)

      "list_projects" ->
        list_projects(runtime_context, args)

      "inspect_project" ->
        inspect_project(runtime_context, args)

      "update_project_scope" ->
        update_project_scope(runtime_context, args)

      "decide_project_recommendation" ->
        decide_project_recommendation(runtime_context, args)

      "grant_project_repo_access" ->
        grant_project_repo_access(runtime_context, args)

      "start_implementation_run" ->
        start_implementation_run(runtime_context, args)

      "list_implementation_runs" ->
        list_implementation_runs(runtime_context, args)

      "update_implementation_run" ->
        update_implementation_run(runtime_context, args)

      "prepare_project_action" ->
        prepare_project_action(runtime_context, args)

      "list_agents" ->
        list_agents(runtime_context, args)

      "inspect_agent" ->
        inspect_agent(runtime_context, args)

      "prepare_agent_action" ->
        prepare_agent_action(runtime_context, args)

      "prepare_external_action" ->
        prepare_external_action(runtime_context, args)

      "query_agent" ->
        query_agent(runtime_context, args)

      "notes_search" ->
        inject_user_and_execute("notes_search", runtime_context, args)

      "notes_get" ->
        inject_user_and_execute("notes_get", runtime_context, args)

      "notes_list_recent" ->
        inject_user_and_execute("notes_list_recent", runtime_context, args)

      "voice_memos_search" ->
        inject_user_and_execute("voice_memos_search", runtime_context, args)

      "voice_memos_get" ->
        inject_user_and_execute("voice_memos_get", runtime_context, args)

      "voice_memos_list_recent" ->
        inject_user_and_execute("voice_memos_list_recent", runtime_context, args)

      "files_search" ->
        inject_user_and_execute("files_search", runtime_context, args)

      "files_get" ->
        inject_user_and_execute("files_get", runtime_context, args)

      "files_list_recent" ->
        inject_user_and_execute("files_list_recent", runtime_context, args)

      "messages_search" ->
        inject_user_and_execute("messages_search", runtime_context, args)

      "messages_get" ->
        inject_user_and_execute("messages_get", runtime_context, args)

      "messages_list_recent" ->
        inject_user_and_execute("messages_list_recent", runtime_context, args)

      "messages_chats_recent" ->
        inject_user_and_execute("messages_chats_recent", runtime_context, args)

      "reminders_open" ->
        inject_user_and_execute("reminders_open", runtime_context, args)

      "reminders_due_soon" ->
        inject_user_and_execute("reminders_due_soon", runtime_context, args)

      "reminders_search" ->
        inject_user_and_execute("reminders_search", runtime_context, args)

      "reminders_get" ->
        inject_user_and_execute("reminders_get", runtime_context, args)

      "calendar_events_around" ->
        inject_user_and_execute("calendar_events_around", runtime_context, args)

      "calendar_events_for_person" ->
        inject_user_and_execute("calendar_events_for_person", runtime_context, args)

      "calendar_search" ->
        inject_user_and_execute("calendar_search", runtime_context, args)

      "calendar_event_get" ->
        inject_user_and_execute("calendar_event_get", runtime_context, args)

      "browser_history_recent" ->
        inject_user_and_execute("browser_history_recent", runtime_context, args)

      "browser_history_by_host" ->
        inject_user_and_execute("browser_history_by_host", runtime_context, args)

      "browser_history_search" ->
        inject_user_and_execute("browser_history_search", runtime_context, args)

      "browser_history_get" ->
        inject_user_and_execute("browser_history_get", runtime_context, args)

      _ ->
        {:error, "unknown_telegram_tool: #{tool_name}"}
    end
  end

  defp toolbox_policy_context(tool_name, args, runtime_context) do
    %{
      surface: "telegram",
      tool_name: tool_name,
      arguments: args,
      user_id: Map.get(runtime_context, :user_id) || Map.get(runtime_context, "user_id"),
      agent_id: Map.get(runtime_context, :agent_id) || Map.get(runtime_context, "agent_id"),
      source_context: %{
        run_id: Map.get(runtime_context, :run_id),
        conversation_id: Map.get(runtime_context, :conversation_id),
        chat_id: Map.get(runtime_context, :chat_id)
      },
      tool_metadata: toolbox_policy_metadata(tool_name)
    }
  end

  defp toolbox_policy_metadata(tool_name) do
    cond do
      MapSet.member?(@toolbox_read_tools, tool_name) ->
        %{
          side_effect: "read",
          read_only?: true,
          destructive?: false,
          idempotent?: true,
          user_required?: true,
          confirmation_required?: false
        }

      MapSet.member?(@toolbox_write_tools, tool_name) ->
        %{
          side_effect: toolbox_side_effect(tool_name),
          read_only?: false,
          destructive?: false,
          idempotent?: toolbox_idempotent?(tool_name),
          user_required?: true,
          confirmation_required?: false
        }

      true ->
        Tools.policy_metadata_for(tool_name)
    end
  end

  defp toolbox_side_effect(tool_name) when tool_name in ["query_agent", "prepare_agent_action"],
    do: "system"

  defp toolbox_side_effect(_tool_name), do: "write"

  defp toolbox_idempotent?(tool_name) do
    tool_name in ~w(
      update_briefing_schedule remember_preferences write_memory record_memory_feedback
      upsert_todos resolve_todo upsert_person link_person_data learn_relationship_context
      update_project_scope decide_project_recommendation update_implementation_run
      create_scheduled_task pause_scheduled_task cancel_scheduled_task
    )
  end

  defp get_open_work_summary(runtime_context, args) do
    user_id = runtime_context.user_id
    limit = normalize_limit(Map.get(args, "limit"), 5, 10)

    open_insights = Insights.list_open_for_user(user_id, limit: max(limit, 20))

    insights =
      open_insights
      |> Enum.take(limit)
      |> Enum.map(fn insight ->
        %{
          id: insight.id,
          title: insight.title,
          source: insight.source,
          priority: insight.priority,
          recommended_action: insight.recommended_action
        }
      end)

    source_health = source_health_summary(user_id, open_insights)
    todos = Todos.list_open_for_user(user_id, limit: limit)

    agents =
      Agents.list_agents(user_id: user_id)
      |> Enum.map(fn agent ->
        %{
          id: agent.id,
          name: get_in(agent.config || %{}, ["name"]),
          behavior: agent.behavior,
          status: agent.status
        }
      end)

    {:ok,
     %{
       insight_count: length(insights),
       top_insights: insights,
       todo_count: length(todos),
       todos: Enum.map(todos, &serialize_todo_summary/1),
       source_health: source_health,
       agent_count: length(agents),
       agents: agents,
       project_count: length(get_in(runtime_context.context, [:projects]) || []),
       projects: get_in(runtime_context.context, [:projects]) || []
     }}
  end

  defp get_open_loops(runtime_context, args) do
    limit = normalize_limit(Map.get(args, "limit"), 12, 50)

    {:ok,
     OpenLoops.snapshot(runtime_context.user_id,
       query: Map.get(args, "query"),
       limit: limit
     )}
  end

  defp list_todos(runtime_context, args) do
    limit = normalize_limit(Map.get(args, "limit"), 50, 50)
    statuses = Map.get(args, "statuses")

    todos =
      if is_list(statuses) or is_binary(statuses) do
        Todos.list_for_user(runtime_context.user_id,
          limit: limit,
          statuses: statuses,
          source: Map.get(args, "source"),
          source_account_id: Map.get(args, "source_account_id"),
          kind: Map.get(args, "kind"),
          attention_mode: Map.get(args, "attention_mode"),
          owner_user_id: Map.get(args, "owner_user_id"),
          due_before: Map.get(args, "due_before"),
          due_after: Map.get(args, "due_after"),
          query: Map.get(args, "query")
        )
      else
        Todos.list_open_for_user(runtime_context.user_id,
          limit: limit,
          source: Map.get(args, "source"),
          source_account_id: Map.get(args, "source_account_id"),
          kind: Map.get(args, "kind"),
          attention_mode: Map.get(args, "attention_mode"),
          owner_user_id: Map.get(args, "owner_user_id"),
          due_before: Map.get(args, "due_before"),
          due_after: Map.get(args, "due_after"),
          query: Map.get(args, "query")
        )
      end

    {:ok,
     %{
       count: length(todos),
       todos: Enum.map(todos, &serialize_todo_detail/1)
     }}
  end

  defp update_briefing_schedule(runtime_context, args) do
    case BriefingSchedules.update_schedule(runtime_context.user_id, args) do
      {:ok, result} ->
        {:ok, result}

      {:error, :no_briefing_agents} ->
        {:error, "no_briefing_agents"}

      {:error, :briefing_agent_not_found} ->
        {:error, "briefing_agent_not_found"}

      {:error, :invalid_briefing_kind} ->
        {:error, "invalid_briefing_kind"}

      {:error, :invalid_local_hour} ->
        {:error, "invalid_local_hour"}

      {:error, :invalid_timezone_offset_hours} ->
        {:error, "invalid_timezone_offset_hours"}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp list_scheduled_tasks(runtime_context, args) do
    limit = normalize_limit(Map.get(args, "limit"), 20, 50)

    tasks =
      ScheduledTasks.list_tasks(runtime_context.user_id,
        status: Map.get(args, "status"),
        limit: limit
      )

    {:ok,
     %{
       count: length(tasks),
       tasks: Enum.map(tasks, &ScheduledTasks.serialize_task/1)
     }}
  end

  defp create_scheduled_task(runtime_context, args) do
    case ScheduledTasks.create_from_telegram(runtime_context.user_id, args) do
      {:ok, task} -> {:ok, %{task: ScheduledTasks.serialize_task(task)}}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp pause_scheduled_task(runtime_context, args) do
    case ScheduledTasks.pause_task(runtime_context.user_id, Map.get(args, "task_id")) do
      {:ok, task} -> {:ok, %{task: ScheduledTasks.serialize_task(task)}}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp cancel_scheduled_task(runtime_context, args) do
    case ScheduledTasks.cancel_task(runtime_context.user_id, Map.get(args, "task_id")) do
      {:ok, task} -> {:ok, %{task: ScheduledTasks.serialize_task(task)}}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp list_preferences(runtime_context) do
    {:ok, preference_snapshot(runtime_context.user_id)}
  end

  defp remember_preferences(runtime_context, args) do
    rules = Map.get(args, "rules", [])

    cond do
      not is_list(rules) ->
        {:error, "invalid_rules"}

      rules == [] ->
        {:error, "missing_rules"}

      true ->
        with {:ok, saved} <-
               PreferenceMemory.save_interpreted_rules(
                 runtime_context.user_id,
                 Enum.filter(rules, &is_map/1),
                 "explicit_telegram",
                 conversation_id: Map.get(runtime_context, :conversation_id),
                 source_delivery_id: linked_delivery_id(runtime_context)
               ) do
          active = Enum.filter(saved, &(Map.get(&1, "status") == "active"))
          pending = Enum.filter(saved, &(Map.get(&1, "status") == "pending_confirmation"))

          _ = maybe_mark_pending_preference_confirmation(runtime_context, pending)

          {:ok,
           preference_snapshot(runtime_context.user_id)
           |> Map.merge(%{
             status: if(pending == [], do: "saved", else: "awaiting_confirmation"),
             saved_count: length(saved),
             saved_rules: saved,
             active_saved_count: length(active),
             pending_saved_count: length(pending),
             requires_confirmation: pending != [],
             message: remember_preferences_message(active, pending, saved)
           })}
        end
    end
  end

  defp forget_preference(runtime_context, args) do
    with {:ok, rule_id} <- required_string(args, "rule_id"),
         {:ok, message} <- PreferenceMemory.forget_rule(runtime_context.user_id, rule_id) do
      {:ok,
       preference_snapshot(runtime_context.user_id)
       |> Map.merge(%{
         status: "forgotten",
         forgotten_rule_id: rule_id,
         message: message
       })}
    else
      {:error, :rule_not_found} -> {:error, "preference_not_found"}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp upsert_todos(runtime_context, args) do
    todos = Map.get(args, "todos", [])

    if is_list(todos) do
      case OpenLoops.ingest_todos(runtime_context.user_id, Enum.filter(todos, &is_map/1),
             source: "telegram_assistant"
           ) do
        {:ok, result} ->
          {:ok,
           %{
             count: length(result.todos),
             skipped_count: result.skipped_count,
             summary: result.summary,
             decisions: result.decisions,
             enrichment: result.enrichment,
             todos: Enum.map(result.todos, &serialize_todo_detail/1)
           }}

        {:error, reason} ->
          {:error, normalize_error(reason)}
      end
    else
      {:error, "invalid_todos"}
    end
  end

  defp resolve_todo(runtime_context, args) do
    with {:ok, todo_id} <- required_string(args, "todo_id") do
      resolution_note = Map.get(args, "resolution_note")
      include_remaining = Map.get(args, "include_remaining") == true
      limit = normalize_limit(Map.get(args, "limit"), 5, 50)

      result =
        case Map.get(args, "status", "done") do
          "done" ->
            Todos.mark_done(runtime_context.user_id, todo_id, note: resolution_note)

          "dismissed" ->
            Todos.dismiss(runtime_context.user_id, todo_id, note: resolution_note)

          "snoozed" ->
            with {:ok, snooze_until} <- resolve_snooze_until(args) do
              Todos.snooze(runtime_context.user_id, todo_id, snooze_until, note: resolution_note)
            end

          _ ->
            {:error, "unsupported_todo_status"}
        end

      with {:ok, todo} <- result do
        remaining =
          if include_remaining do
            Todos.list_open_for_user(runtime_context.user_id,
              limit: limit,
              source: Map.get(args, "source"),
              source_account_id: Map.get(args, "source_account_id"),
              kind: Map.get(args, "kind"),
              attention_mode: Map.get(args, "attention_mode"),
              owner_user_id: Map.get(args, "owner_user_id"),
              due_before: Map.get(args, "due_before"),
              due_after: Map.get(args, "due_after")
            )
          else
            []
          end

        {:ok,
         %{
           todo: serialize_todo_detail(todo),
           remaining_count: length(remaining),
           remaining_todos: Enum.map(remaining, &serialize_todo_detail/1)
         }}
      end
    end
  end

  defp list_projects(runtime_context, args) do
    Projects.list_projects(user_id: runtime_context.user_id)
    |> Enum.filter(&matches_project_filter?(&1, args))
    |> Enum.map(&serialize_project_summary/1)
    |> then(&{:ok, %{count: length(&1), projects: &1}})
  end

  defp inspect_project(runtime_context, args) do
    with %{} = project <- resolve_project(runtime_context, args) do
      agents =
        Agents.list_agents(user_id: runtime_context.user_id, project_id: project.id)
        |> Enum.map(fn agent ->
          %{
            id: agent.id,
            name: get_in(agent.config || %{}, ["name"]),
            behavior: agent.behavior,
            status: agent.status,
            updated_at: agent.updated_at
          }
        end)

      items =
        Projects.list_project_items(
          user_id: runtime_context.user_id,
          project_id: project.id,
          limit: 6
        )
        |> Enum.map(&serialize_project_item/1)

      recommendations =
        Projects.list_project_recommendations(project.id, runtime_context.user_id, limit: 3)

      {:ok,
       %{
         project: serialize_project_detail(project),
         item_count: length(items),
         items: items,
         agent_count: length(agents),
         agents: agents,
         repo_grant_count:
           length(
             Projects.list_repo_grants(project_id: project.id, user_id: runtime_context.user_id)
           ),
         repo_grants:
           Projects.list_repo_grants(
             project_id: project.id,
             user_id: runtime_context.user_id,
             limit: 3
           )
           |> Enum.map(&serialize_project_repo_grant/1),
         implementation_run_count:
           length(
             Projects.list_implementation_runs(
               project_id: project.id,
               user_id: runtime_context.user_id
             )
           ),
         implementation_runs:
           Projects.list_implementation_runs(
             project_id: project.id,
             user_id: runtime_context.user_id,
             limit: 3
           )
           |> Enum.map(&serialize_project_implementation_run/1),
         recommendation_count: length(recommendations),
         recommendations: recommendations
       }}
    else
      nil -> {:error, "project_not_found"}
    end
  end

  defp update_project_scope(runtime_context, args) do
    reviewed_at = DateTime.utc_now()

    with %{} = project <- resolve_project_for_scope_update(runtime_context, args),
         life_domain when life_domain in ["work", "home"] <- Map.get(args, "life_domain"),
         {:ok, updated} <-
           Projects.classify_life_domain(project, %{
             "life_domain" => life_domain,
             "confidence" => Map.get(args, "confidence"),
             "reasoning" => Map.get(args, "reasoning"),
             "needs_confirmation" => false,
             "source" => "telegram_assistant",
             "reviewed_at" => reviewed_at
           }),
         {:ok, aligned_todos} <-
           Todos.align_scope_for_project(runtime_context.user_id, project.id, %{
             "project_name" => project.name,
             "life_domain" => life_domain,
             "confidence" => Map.get(args, "confidence"),
             "reasoning" => Map.get(args, "reasoning"),
             "source" => "project_scope_confirmation",
             "reviewed_at" => reviewed_at
           }) do
      {:ok,
       %{
         status: "updated",
         project: serialize_project_detail(updated),
         life_domain: life_domain,
         aligned_todo_count: length(aligned_todos)
       }}
    else
      nil -> {:error, "project_not_found"}
      _ -> {:error, "invalid_life_domain"}
    end
  end

  defp decide_project_recommendation(runtime_context, args) do
    with %{} = project <- resolve_project(runtime_context, args) || {:error, "project_not_found"},
         {:ok, recommendation_id} <- required_string(args, "recommendation_id"),
         {:ok, decision} <-
           Projects.decide_project_recommendation(
             project.id,
             runtime_context.user_id,
             recommendation_id,
             %{
               "decision" => Map.get(args, "decision"),
               "decision_note" => Map.get(args, "decision_note")
             }
           ),
         %{} = recommendation <-
           Projects.get_project_recommendation(
             project.id,
             runtime_context.user_id,
             recommendation_id
           ) ||
             {:error, "recommendation_not_found"} do
      {:ok,
       %{
         project: serialize_project_detail(project),
         recommendation: recommendation,
         decision: serialize_project_recommendation_decision(decision),
         message:
           "#{String.capitalize(decision.decision)} #{recommendation.title} for #{project.name}."
       }}
    else
      nil ->
        {:error, "project_not_found"}

      {:error, :project_not_found} ->
        {:error, "project_not_found"}

      {:error, :recommendation_not_found} ->
        {:error, "recommendation_not_found"}

      {:error, :invalid_recommendation_decision} ->
        {:error, "invalid_recommendation_decision"}

      {:error, :invalid_recommendation_decision_note} ->
        {:error, "invalid_recommendation_decision_note"}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp grant_project_repo_access(runtime_context, args) do
    with %{} = project <- resolve_project(runtime_context, args) || {:error, "project_not_found"},
         {:ok, grant} <-
           Projects.grant_project_repo_access(project.id, runtime_context.user_id, args) do
      {:ok,
       %{
         project: serialize_project_detail(project),
         repo_grant: serialize_project_repo_grant(grant),
         message:
           "Granted #{human_repo_scope(grant.scope)} GitHub access for #{grant.repo_full_name} on #{project.name}."
       }}
    else
      nil -> {:error, "project_not_found"}
      {:error, :project_not_found} -> {:error, "project_not_found"}
      {:error, :missing_repo_full_name} -> {:error, "missing_repo_full_name"}
      {:error, :invalid_repo_scope} -> {:error, "invalid_repo_scope"}
      {:error, :invalid_repo_provider} -> {:error, "invalid_repo_provider"}
      {:error, :invalid_repo_grant_status} -> {:error, "invalid_repo_grant_status"}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp start_implementation_run(runtime_context, args) do
    with %{} = project <- resolve_project(runtime_context, args) || {:error, "project_not_found"},
         {:ok, run} <-
           Projects.start_implementation_run(project.id, runtime_context.user_id, args) do
      {:ok,
       %{
         project: serialize_project_detail(project),
         implementation_run: serialize_project_implementation_run(run),
         message: run.result_summary || "Started an implementation run for #{project.name}."
       }}
    else
      nil -> {:error, "project_not_found"}
      {:error, :project_not_found} -> {:error, "project_not_found"}
      {:error, :missing_recommendation_id} -> {:error, "missing_recommendation_id"}
      {:error, :recommendation_not_found} -> {:error, "recommendation_not_found"}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp list_implementation_runs(runtime_context, args) do
    limit = normalize_limit(Map.get(args, "limit"), 6, 20)

    runs =
      case resolve_project(runtime_context, args) do
        %{} = project ->
          Projects.list_implementation_runs(
            project_id: project.id,
            user_id: runtime_context.user_id,
            statuses: Map.get(args, "statuses"),
            limit: limit
          )

        nil ->
          Projects.list_implementation_runs(
            user_id: runtime_context.user_id,
            statuses: Map.get(args, "statuses"),
            limit: limit
          )
      end

    {:ok,
     %{
       count: length(runs),
       implementation_runs: Enum.map(runs, &serialize_project_implementation_run/1)
     }}
  end

  defp update_implementation_run(runtime_context, args) do
    with {:ok, run_id} <- required_string(args, "implementation_run_id"),
         {:ok, update_attrs} <- implementation_run_update_attrs(args),
         {:ok, run} <-
           Projects.update_implementation_run(run_id, runtime_context.user_id, update_attrs) do
      {:ok,
       %{
         implementation_run: serialize_project_implementation_run(run),
         message:
           run.result_summary ||
             "Updated implementation run #{run.id}."
       }}
    else
      {:error, :implementation_run_not_found} ->
        {:error, "implementation_run_not_found"}

      {:error, :invalid_implementation_run_status} ->
        {:error, "invalid_implementation_run_status"}

      {:error, :invalid_implementation_run_metadata} ->
        {:error, "invalid_implementation_run_metadata"}

      {:error, "missing_implementation_run_update"} ->
        {:error, "missing_implementation_run_update"}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp inspect_open_insight(runtime_context, args) do
    linked_item = get_in(runtime_context.context, [:linked_item])

    case Map.get(args, "insight_id") do
      insight_id when is_binary(insight_id) and insight_id != "" ->
        insight =
          Insights.list_open_with_details_for_user(runtime_context.user_id, limit: 20)
          |> Enum.find(fn %{insight: insight} -> insight.id == insight_id end)

        case insight do
          %{insight: insight, detail: detail} ->
            {:ok,
             %{
               id: insight.id,
               title: insight.title,
               summary: insight.summary,
               recommended_action: insight.recommended_action,
               detail: detail
             }}

          nil ->
            {:error, "insight_not_found"}
        end

      _ ->
        case linked_item do
          %{} = item when map_size(item) > 0 -> {:ok, item}
          _ -> {:error, "no_linked_insight"}
        end
    end
  end

  defp explain_action_ledger(runtime_context, args) do
    user_id = runtime_context.user_id

    case resolve_action_explanation(user_id, args) do
      {:ok, explanation} ->
        freshness = SourceFreshness.compact_for_prompt(user_id)

        {:ok,
         %{
           explanation: explanation,
           source_freshness: freshness,
           message: action_explanation_message(explanation, freshness)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_action_explanation(user_id, args) do
    action_id = optional_string(args, "action_id")
    object_type = optional_string(args, "object_type")
    object_id = optional_string(args, "object_id")
    event_type = optional_string(args, "event_type")

    cond do
      action_id ->
        ActionLedger.explain(user_id, action_id)

      object_type && object_id ->
        user_id
        |> ActionLedger.find_by_object(object_type, object_id)
        |> maybe_filter_action_event_type(event_type)
        |> explain_first_action()

      event_type ->
        user_id
        |> ActionLedger.list_recent(event_type: event_type, limit: 1)
        |> explain_first_action()

      true ->
        user_id
        |> ActionLedger.list_recent(limit: 1)
        |> explain_first_action()
    end
  end

  defp maybe_filter_action_event_type(actions, nil), do: actions

  defp maybe_filter_action_event_type(actions, event_type),
    do: Enum.filter(actions, &(&1.event_type == event_type))

  defp explain_first_action([action | _actions]), do: {:ok, ActionLedger.explain_action(action)}
  defp explain_first_action([]), do: {:error, "action_not_found"}

  defp action_explanation_message(explanation, freshness) do
    summary =
      explanation.model_summary ||
        explanation.message ||
        "I found the ledger entry, but it did not include a model summary."

    stale =
      freshness
      |> Enum.filter(&(&1.status in ["stale", "reauth_required", "error", "unknown"]))
      |> Enum.map_join(", ", fn source -> "#{source.provider}: #{source.status}" end)

    basis =
      case explanation.reason_code do
        nil -> "No policy reason was recorded."
        reason -> "Policy reason: #{reason}."
      end

    freshness_line =
      if stale == "" do
        "Sources were not marked stale in the current freshness snapshot."
      else
        "Source freshness issues: #{stale}."
      end

    "#{summary} #{basis} #{freshness_line}"
  end

  defp slack_search(runtime_context, args) do
    args =
      args
      |> Map.put("user_id", runtime_context.user_id)
      |> maybe_put_default("team_id", runtime_context.default_slack_team_id)

    Tools.execute("slack_search_messages", args, checked_tool_context(runtime_context))
  end

  defp slack_thread_context(runtime_context, args) do
    args =
      args
      |> Map.put("user_id", runtime_context.user_id)
      |> maybe_put_default("team_id", runtime_context.default_slack_team_id)

    Tools.execute("slack_get_thread_replies", args, checked_tool_context(runtime_context))
  end

  defp linear_list_or_lookup(runtime_context, args) do
    with {:ok, access_token} <- OAuth.get_valid_access_token(runtime_context.user_id, "linear") do
      case Map.get(args, "identifier") do
        identifier when is_binary(identifier) and identifier != "" ->
          lookup_linear_issue(access_token, identifier)

        _ ->
          with {:ok, teams} <- Linear.get_teams(access_token) do
            {:ok, %{teams: teams}}
          end
      end
    else
      {:error, :no_token} -> {:error, "linear_not_connected"}
      {:error, :reauth_required} -> {:error, "linear_reauth_required"}
      {:error, reason} -> {:error, "linear_lookup_failed: #{inspect(reason)}"}
    end
  end

  defp list_agents(runtime_context, args) do
    Agents.list_agents(user_id: runtime_context.user_id, preload: [:project])
    |> Enum.filter(&matches_agent_filter?(&1, args))
    |> Enum.map(fn agent ->
      %{
        id: agent.id,
        name: get_in(agent.config || %{}, ["name"]),
        behavior: agent.behavior,
        status: agent.status,
        project_id: agent.project_id,
        project_name: agent.project && agent.project.name,
        started_at: agent.started_at,
        updated_at: agent.updated_at
      }
    end)
    |> then(&{:ok, %{count: length(&1), agents: &1}})
  end

  defp inspect_agent(runtime_context, args) do
    with {:ok, agent_id} <- required_string(args, "agent_id"),
         %{} <- Agents.get_agent_for_user(agent_id, runtime_context.user_id) do
      case Admin.safe_agent_snapshot(agent_id,
             user_id: runtime_context.user_id,
             event_limit: 12,
             effect_limit: 12,
             job_limit: 12,
             log_limit: 20
           ) do
        {:ok, snapshot} -> {:ok, snapshot}
        {:degraded, snapshot} -> {:ok, Map.put(snapshot, :degraded, true)}
        {:error, :not_found} -> {:error, "agent_not_found"}
        {:error, reason} -> {:error, "agent_inspection_failed: #{inspect(reason)}"}
      end
    else
      nil -> {:error, "agent_not_found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_agent_action(runtime_context, args) do
    with true <- TelegramAssistant.agent_control_enabled?() || {:error, "agent_control_disabled"},
         {:ok, action} <- required_string(args, "action") do
      case action do
        "create" ->
          prepare_agent_create(runtime_context, args)

        "update" ->
          prepare_agent_update(runtime_context, args)

        "delete" ->
          prepare_agent_delete(runtime_context, args)

        action when action in @immediate_agent_actions ->
          execute_immediate_agent_action(runtime_context, action, args)

        _ ->
          {:error, "unsupported_agent_action"}
      end
    else
      false -> {:error, "agent_control_disabled"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_external_action(runtime_context, args) do
    with true <- TelegramAssistant.write_tools_enabled?() || {:error, "write_tools_disabled"},
         {:ok, action_type} <- required_string(args, "action_type"),
         %{} = spec <- Map.get(@external_action_tools, action_type),
         payload when is_map(payload) <- Map.get(args, "payload", %{}) do
      executable_payload = Map.put(payload, "user_id", runtime_context.user_id)
      preview_text = external_action_preview(action_type, executable_payload)

      expires_at =
        DateTime.add(DateTime.utc_now(), TelegramAssistant.confirmation_window_seconds(), :second)

      TelegramAssistant.create_prepared_action(%{
        user_id: runtime_context.user_id,
        chat_id: runtime_context.chat_id,
        conversation_id: runtime_context.conversation_id,
        run_id: runtime_context.run_id,
        action_type: action_type,
        target_type: spec.target_type,
        target_id: external_target_id(action_type, executable_payload),
        payload: executable_payload,
        preview_text: preview_text,
        status: "awaiting_confirmation",
        expires_at: expires_at
      })
      |> case do
        {:ok, prepared_action} ->
          {:ok,
           %{
             status: "awaiting_confirmation",
             prepared_action_id: prepared_action.id,
             preview_text: preview_text,
             requires_confirmation: true,
             message:
               "#{preview_text} Reply `yes` or use the buttons to confirm, or `no` to cancel."
           }}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      false -> {:error, "write_tools_disabled"}
      nil -> {:error, "unsupported_external_action"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "invalid_external_payload"}
    end
  end

  defp query_agent(runtime_context, args) do
    with true <- TelegramAssistant.agent_control_enabled?() || {:error, "agent_control_disabled"},
         {:ok, agent_id} <- required_string(args, "agent_id"),
         {:ok, message} <- required_string(args, "message"),
         %{} <- Agents.get_agent_for_user(agent_id, runtime_context.user_id),
         {:ok, result} <-
           Runtime.request_response(
             agent_id,
             message,
             %{"source" => "telegram_assistant", "run_id" => runtime_context.run_id},
             timeout_ms: normalize_timeout(Map.get(args, "timeout_ms"))
           ) do
      {:ok, result}
    else
      false -> {:error, "agent_control_disabled"}
      nil -> {:error, "agent_not_found"}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp prepare_agent_create(runtime_context, args) do
    launch = stringify_map(Map.get(args, "launch", %{}))

    with {:ok, start_params} <- AgentBuilder.build_start_params(launch, runtime_context.user_id) do
      preview_text = create_agent_preview(runtime_context, start_params)

      expires_at =
        DateTime.add(DateTime.utc_now(), TelegramAssistant.confirmation_window_seconds(), :second)

      TelegramAssistant.create_prepared_action(%{
        user_id: runtime_context.user_id,
        chat_id: runtime_context.chat_id,
        conversation_id: runtime_context.conversation_id,
        run_id: runtime_context.run_id,
        action_type: "agent_create",
        target_type: "agent",
        payload: %{"start_params" => start_params, "launch" => launch},
        preview_text: preview_text,
        status: "awaiting_confirmation",
        expires_at: expires_at
      })
      |> case do
        {:ok, prepared_action} ->
          {:ok,
           %{
             status: "awaiting_confirmation",
             prepared_action_id: prepared_action.id,
             preview_text: preview_text,
             requires_confirmation: true,
             message:
               "#{preview_text} Reply `yes` or use the buttons to create it, or `no` to cancel."
           }}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp prepare_agent_update(runtime_context, args) do
    with {:ok, agent_id} <- required_string(args, "agent_id"),
         %{} = agent <- Agents.get_agent_for_user(agent_id, runtime_context.user_id) do
      launch =
        agent
        |> AgentBuilder.launch_params_from_agent()
        |> Map.merge(stringify_map(Map.get(args, "launch", %{})))

      with {:ok, update_params} <-
             AgentBuilder.build_start_params(launch, runtime_context.user_id) do
        preview_text = update_agent_preview(runtime_context, agent, update_params)

        expires_at =
          DateTime.add(
            DateTime.utc_now(),
            TelegramAssistant.confirmation_window_seconds(),
            :second
          )

        TelegramAssistant.create_prepared_action(%{
          user_id: runtime_context.user_id,
          chat_id: runtime_context.chat_id,
          conversation_id: runtime_context.conversation_id,
          run_id: runtime_context.run_id,
          action_type: "agent_update",
          target_type: "agent",
          target_id: agent.id,
          payload: %{
            "agent_id" => agent.id,
            "update_params" =>
              Map.take(update_params, ["behavior", "config", "budget", "project_id"]),
            "launch" => launch
          },
          preview_text: preview_text,
          status: "awaiting_confirmation",
          expires_at: expires_at
        })
        |> case do
          {:ok, prepared_action} ->
            {:ok,
             %{
               status: "awaiting_confirmation",
               prepared_action_id: prepared_action.id,
               preview_text: preview_text,
               requires_confirmation: true,
               message:
                 "#{preview_text} Reply `yes` or use the buttons to apply the update, or `no` to cancel."
             }}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
      end
    else
      nil -> {:error, "agent_not_found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_agent_delete(runtime_context, args) do
    with {:ok, agent_id} <- required_string(args, "agent_id"),
         %{} = agent <- Agents.get_agent_for_user(agent_id, runtime_context.user_id) do
      preview_text = delete_agent_preview(agent)

      expires_at =
        DateTime.add(DateTime.utc_now(), TelegramAssistant.confirmation_window_seconds(), :second)

      TelegramAssistant.create_prepared_action(%{
        user_id: runtime_context.user_id,
        chat_id: runtime_context.chat_id,
        conversation_id: runtime_context.conversation_id,
        run_id: runtime_context.run_id,
        action_type: "agent_delete",
        target_type: "agent",
        target_id: agent.id,
        payload: %{"agent_id" => agent.id},
        preview_text: preview_text,
        status: "awaiting_confirmation",
        expires_at: expires_at
      })
      |> case do
        {:ok, prepared_action} ->
          {:ok,
           %{
             status: "awaiting_confirmation",
             prepared_action_id: prepared_action.id,
             preview_text: preview_text,
             requires_confirmation: true,
             message:
               "#{preview_text} Reply `yes` or use the buttons to delete it, or `no` to cancel."
           }}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      nil -> {:error, "agent_not_found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_immediate_agent_action(runtime_context, action, args) do
    with {:ok, agent_id} <- required_string(args, "agent_id"),
         %{} = agent <- Agents.get_agent_for_user(agent_id, runtime_context.user_id),
         {:ok, result} <- perform_agent_action(action, agent_id) do
      preview_text = immediate_agent_preview(action, agent)
      now = DateTime.utc_now()

      {:ok, prepared_action} =
        TelegramAssistant.create_prepared_action(%{
          user_id: runtime_context.user_id,
          chat_id: runtime_context.chat_id,
          conversation_id: runtime_context.conversation_id,
          run_id: runtime_context.run_id,
          action_type: "agent_#{action}",
          target_type: "agent",
          target_id: agent.id,
          payload: %{"agent_id" => agent.id},
          preview_text: preview_text,
          status: "executed",
          expires_at: now,
          confirmed_at: now,
          executed_at: now
        })

      {:ok,
       %{
         status: "executed",
         prepared_action_id: prepared_action.id,
         message: immediate_agent_result_text(action, agent, result),
         result: result
       }}
    else
      nil -> {:error, "agent_not_found"}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp prepare_project_action(runtime_context, args) do
    with true <- TelegramAssistant.write_tools_enabled?() || {:error, "write_tools_disabled"},
         {:ok, action} <- required_string(args, "action") do
      case action do
        "create" ->
          prepare_project_create(runtime_context, args)

        "update" ->
          prepare_project_update(runtime_context, args)

        _ ->
          {:error, "unsupported_project_action"}
      end
    else
      false -> {:error, "write_tools_disabled"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_project_create(runtime_context, args) do
    attrs = stringify_map(Map.get(args, "attrs", %{}))

    case validate_project_attrs(attrs) do
      {:ok, validated_attrs} ->
        preview_text = create_project_preview(validated_attrs)

        expires_at =
          DateTime.add(
            DateTime.utc_now(),
            TelegramAssistant.confirmation_window_seconds(),
            :second
          )

        TelegramAssistant.create_prepared_action(%{
          user_id: runtime_context.user_id,
          chat_id: runtime_context.chat_id,
          conversation_id: runtime_context.conversation_id,
          run_id: runtime_context.run_id,
          action_type: "project_create",
          target_type: "project",
          payload: %{"user_id" => runtime_context.user_id, "attrs" => validated_attrs},
          preview_text: preview_text,
          status: "awaiting_confirmation",
          expires_at: expires_at
        })
        |> case do
          {:ok, prepared_action} ->
            {:ok,
             %{
               status: "awaiting_confirmation",
               prepared_action_id: prepared_action.id,
               preview_text: preview_text,
               requires_confirmation: true,
               message:
                 "#{preview_text} Reply `yes` or use the buttons to create it, or `no` to cancel."
             }}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_project_update(runtime_context, args) do
    attrs = stringify_map(Map.get(args, "attrs", %{}))

    with %{} = project <- resolve_project(runtime_context, args) || {:error, "project_not_found"},
         {:ok, validated_attrs} <- validate_project_attrs(attrs, allow_empty?: false) do
      preview_text = update_project_preview(project, validated_attrs)

      expires_at =
        DateTime.add(DateTime.utc_now(), TelegramAssistant.confirmation_window_seconds(), :second)

      TelegramAssistant.create_prepared_action(%{
        user_id: runtime_context.user_id,
        chat_id: runtime_context.chat_id,
        conversation_id: runtime_context.conversation_id,
        run_id: runtime_context.run_id,
        action_type: "project_update",
        target_type: "project",
        target_id: project.id,
        payload: %{"project_id" => project.id, "attrs" => validated_attrs},
        preview_text: preview_text,
        status: "awaiting_confirmation",
        expires_at: expires_at
      })
      |> case do
        {:ok, prepared_action} ->
          {:ok,
           %{
             status: "awaiting_confirmation",
             prepared_action_id: prepared_action.id,
             preview_text: preview_text,
             requires_confirmation: true,
             message:
               "#{preview_text} Reply `yes` or use the buttons to apply the update, or `no` to cancel."
           }}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      nil -> {:error, "project_not_found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inject_user_and_execute(tool_name, runtime_context, args) do
    tool_name
    |> Tools.execute(
      Map.put(args, "user_id", runtime_context.user_id),
      checked_tool_context(runtime_context)
    )
    |> normalize_tool_result()
  end

  defp checked_tool_context(runtime_context) do
    %{
      surface: "telegram",
      user_id: runtime_context.user_id,
      agent_id: Map.get(runtime_context, :agent_id),
      policy_checked?: true
    }
  end

  defp normalize_tool_result({:ok, result}), do: {:ok, result}
  defp normalize_tool_result({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp normalize_tool_result({:error, reason}), do: {:error, inspect(reason)}

  defp lookup_linear_issue(access_token, identifier) do
    query = """
    query LookupIssue($identifier: String!) {
      issues(filter: { identifier: { eq: $identifier } }, first: 1) {
        nodes {
          id
          identifier
          title
          description
          url
          priority
          state {
            id
            name
            type
          }
          team {
            id
            key
            name
          }
        }
      }
    }
    """

    case LinearOAuth.graphql(access_token, query, %{identifier: identifier}) do
      {:ok, %{"issues" => %{"nodes" => [issue | _]}}} ->
        {:ok, %{issue: issue}}

      {:ok, %{"issues" => %{"nodes" => []}}} ->
        {:error, "linear_issue_not_found"}

      {:error, reason} ->
        {:error, "linear_lookup_failed: #{inspect(reason)}"}
    end
  end

  defp matches_agent_filter?(agent, args) do
    status = Map.get(args, "status")
    behavior = Map.get(args, "behavior")

    (is_nil(status) or agent.status == status) and
      (is_nil(behavior) or agent.behavior == behavior)
  end

  defp matches_project_filter?(project, args) do
    status = Map.get(args, "status")
    priority = Map.get(args, "priority")

    (is_nil(status) or project.status == status) and
      (is_nil(priority) or project.priority == priority)
  end

  defp perform_agent_action("start", agent_id), do: Runtime.start_existing_agent(agent_id)

  defp perform_agent_action("stop", agent_id),
    do: Runtime.stop_agent(agent_id, "telegram_operator")

  defp perform_agent_action("restart", agent_id) do
    with {:ok, _stop} <- Runtime.stop_agent(agent_id, "telegram_operator_restart"),
         {:ok, restarted} <- Runtime.start_existing_agent(agent_id) do
      {:ok, restarted}
    end
  end

  defp external_action_preview("gmail_send", payload) do
    "Send Gmail message to #{Map.get(payload, "to")} with subject \"#{Map.get(payload, "subject")}\"."
  end

  defp external_action_preview("slack_post", payload) do
    "Post Slack message to #{Map.get(payload, "channel")} on workspace #{Map.get(payload, "team_id")}."
  end

  defp external_action_preview("linear_create_issue", payload) do
    "Create Linear issue \"#{Map.get(payload, "title")}\" in team #{Map.get(payload, "team_id")}."
  end

  defp external_action_preview("linear_create_comment", payload) do
    "Add a Linear comment to issue #{Map.get(payload, "issue_id")}."
  end

  defp external_action_preview("linear_update_issue_state", payload) do
    "Move Linear issue #{Map.get(payload, "issue_id")} to state #{Map.get(payload, "state_id")}."
  end

  defp external_action_preview("notaui_complete_task", payload) do
    "Complete Notaui task #{Map.get(payload, "task_id")}."
  end

  defp external_action_preview("notaui_update_task", payload) do
    "Update Notaui task #{Map.get(payload, "task_id")}."
  end

  defp external_action_preview(_action_type, _payload),
    do: "Prepare the requested external action."

  defp external_target_id(action_type, payload)
       when action_type in [
              "gmail_send",
              "slack_post",
              "notaui_complete_task",
              "notaui_update_task"
            ] do
    Map.get(payload, "thread_id") || Map.get(payload, "channel") || Map.get(payload, "task_id")
  end

  defp external_target_id(_action_type, payload),
    do: Map.get(payload, "issue_id") || Map.get(payload, "state_id")

  defp create_agent_preview(runtime_context, start_params) do
    config = Map.get(start_params, "config", %{})
    name = Map.get(config, "name") || start_params["behavior"]

    project_suffix =
      case project_name(runtime_context, Map.get(start_params, "project_id")) do
        nil -> ""
        project_name -> " and attach it to project #{project_name}"
      end

    "Create agent #{name} using behavior #{start_params["behavior"]}#{project_suffix}."
  end

  defp update_agent_preview(runtime_context, agent, update_params) do
    name = get_in(agent.config || %{}, ["name"]) || agent.behavior
    behavior = Map.get(update_params, "behavior", agent.behavior)

    project_suffix =
      case project_name(runtime_context, Map.get(update_params, "project_id", agent.project_id)) do
        nil -> ""
        project_name -> " Attach it to project #{project_name}."
      end

    "Update agent #{name} with behavior #{behavior} and apply the new configuration.#{project_suffix}"
  end

  defp delete_agent_preview(agent) do
    name = get_in(agent.config || %{}, ["name"]) || agent.behavior
    "Delete agent #{name}. This removes its saved definition and runtime history dependencies."
  end

  defp immediate_agent_preview(action, agent) do
    name = get_in(agent.config || %{}, ["name"]) || agent.behavior
    "#{String.capitalize(action)} agent #{name}."
  end

  defp immediate_agent_result_text("start", agent, _result) do
    "Started agent #{agent_name(agent)}."
  end

  defp immediate_agent_result_text("stop", agent, _result) do
    "Stopped agent #{agent_name(agent)}."
  end

  defp immediate_agent_result_text("restart", agent, _result) do
    "Restarted agent #{agent_name(agent)}."
  end

  defp immediate_agent_result_text(_action, agent, _result) do
    "Updated agent #{agent_name(agent)}."
  end

  defp agent_name(agent) do
    get_in(agent.config || %{}, ["name"]) || agent.behavior
  end

  defp create_project_preview(attrs) do
    "Create project #{Map.get(attrs, "name")}."
  end

  defp update_project_preview(project, attrs) do
    case Map.get(attrs, "name") do
      value when is_binary(value) and value != "" ->
        "Update project #{project.name} and rename it to #{value}."

      _ ->
        "Update project #{project.name}."
    end
  end

  defp validate_project_attrs(attrs, opts \\ []) when is_map(attrs) do
    allow_empty? = Keyword.get(opts, :allow_empty?, true)
    permitted = Map.take(attrs, ["name", "slug", "status", "priority", "description", "summary"])

    cond do
      map_size(permitted) == 0 and not allow_empty? ->
        {:error, "missing_project_attrs"}

      Map.get(permitted, "name") in [nil, ""] and allow_empty? ->
        {:error, "missing_project_name"}

      true ->
        {:ok, permitted}
    end
  end

  defp resolve_project(runtime_context, args) do
    case optional_string_arg(args, "project_id") do
      {:ok, project_id} ->
        Projects.get_project_for_user(project_id, runtime_context.user_id)

      :missing ->
        case optional_string_arg(args, "project_slug") do
          {:ok, slug} ->
            Projects.get_project_by_slug_for_user(slug, runtime_context.user_id)

          :missing ->
            case optional_string_arg(args, "project_name") do
              {:ok, name} -> Projects.get_project_by_name_for_user(name, runtime_context.user_id)
              :missing -> default_project(runtime_context)
              {:error, _reason} -> nil
            end

          {:error, _reason} ->
            nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp resolve_project_for_scope_update(runtime_context, args) do
    case optional_string_arg(args, "project_id") do
      {:ok, project_id} ->
        Projects.get_project_for_user(project_id, runtime_context.user_id)

      :missing ->
        case optional_string_arg(args, "project_slug") do
          {:ok, slug} ->
            Projects.get_project_by_slug_for_user(slug, runtime_context.user_id)

          :missing ->
            case optional_string_arg(args, "project_name") do
              {:ok, name} ->
                Projects.get_project_by_name_for_user(name, runtime_context.user_id)

              :missing ->
                get_in(runtime_context, [:context, :linked_item, :project, :id])
                |> case do
                  value when is_binary(value) ->
                    Projects.get_project_for_user(value, runtime_context.user_id)

                  _ ->
                    nil
                end

              {:error, _reason} ->
                nil
            end

          {:error, _reason} ->
            nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp default_project(runtime_context) do
    case Map.get(runtime_context, :default_project_id) do
      value when is_binary(value) and value != "" ->
        Projects.get_project_for_user(value, runtime_context.user_id)

      _ ->
        nil
    end
  end

  defp serialize_project_summary(project) do
    %{
      id: project.id,
      name: project.name,
      slug: project.slug,
      status: project.status,
      priority: project.priority,
      summary: project.summary,
      metadata:
        (project.metadata || %{})
        |> Map.take([
          "life_domain",
          "life_domain_confidence",
          "life_domain_reasoning",
          "life_domain_needs_confirmation"
        ])
    }
  end

  defp serialize_project_detail(project) do
    %{
      id: project.id,
      name: project.name,
      slug: project.slug,
      status: project.status,
      priority: project.priority,
      description: project.description,
      summary: project.summary,
      metadata: project.metadata || %{},
      updated_at: project.updated_at
    }
  end

  defp serialize_project_item(item) do
    %{
      id: item.id,
      item_type: item.item_type,
      title: item.title,
      content: item.content,
      status: item.status,
      inserted_at: item.inserted_at
    }
  end

  defp serialize_project_recommendation_decision(decision) when is_map(decision) do
    %{
      id: decision.id,
      decision: decision.decision,
      decision_note: decision.decision_note,
      accepted_plan:
        Map.get(decision, :accepted_plan) || Map.get(decision, "accepted_plan") || %{},
      updated_at: decision.updated_at
    }
  end

  defp serialize_project_recommendation_decision(_decision), do: nil

  defp serialize_project_repo_grant(grant) do
    %{
      id: grant.id,
      provider: grant.provider,
      repo_full_name: grant.repo_full_name,
      scope: grant.scope,
      status: grant.status,
      granted_at: grant.granted_at
    }
  end

  defp serialize_project_implementation_run(run) do
    %{
      id: run.id,
      agent_id: run.agent_id,
      repo_full_name: run.repo_full_name,
      status: run.status,
      branch_name: run.branch_name,
      pull_request_url: run.pull_request_url,
      result_summary: run.result_summary,
      queued_at: run.queued_at,
      started_at: run.started_at,
      completed_at: run.completed_at,
      metadata: run.metadata || %{}
    }
  end

  defp implementation_run_update_attrs(args) when is_map(args) do
    attrs =
      Map.take(args, ["status", "branch_name", "pull_request_url", "result_summary", "metadata"])
      |> Enum.reject(fn
        {"metadata", value} -> is_nil(value)
        {_key, value} -> value in [nil, ""]
      end)
      |> Map.new()

    if map_size(attrs) == 0 do
      {:error, "missing_implementation_run_update"}
    else
      {:ok, attrs}
    end
  end

  defp human_repo_scope("read_only"), do: "read-only"
  defp human_repo_scope("branch_write"), do: "branch-write"
  defp human_repo_scope("pr_open"), do: "PR-open"
  defp human_repo_scope(scope), do: scope

  defp project_name(_runtime_context, nil), do: nil
  defp project_name(_runtime_context, ""), do: nil

  defp project_name(runtime_context, project_id) when is_binary(project_id) do
    case Projects.get_project_for_user(project_id, runtime_context.user_id) do
      %{} = project -> project.name
      nil -> nil
    end
  end

  defp source_health_summary(user_id, open_insights)
       when is_binary(user_id) and is_list(open_insights) do
    gmail_accounts =
      ConnectedAccounts.list_for_user(user_id)
      |> Enum.filter(&gmail_account?/1)
      |> Enum.map(&gmail_account_health(user_id, &1))

    freshest_visible_email_at =
      gmail_accounts
      |> Enum.map(&parse_iso8601_datetime(&1.latest_visible_email_at))
      |> most_recent_datetime()

    latest_gmail_insight_at =
      open_insights
      |> Enum.filter(&(normalize_source(&1.source) == "gmail"))
      |> Enum.map(&latest_gmail_insight_datetime/1)
      |> most_recent_datetime()

    insights_stale =
      gmail_insights_stale?(freshest_visible_email_at, latest_gmail_insight_at)

    gmail_status =
      cond do
        gmail_accounts == [] -> "not_connected"
        Enum.any?(gmail_accounts, &(&1.status == "ok")) -> "ok"
        true -> "error"
      end

    %{
      gmail: %{
        status: gmail_status,
        freshest_visible_email_at: datetime_to_iso8601(freshest_visible_email_at),
        latest_open_insight_at: datetime_to_iso8601(latest_gmail_insight_at),
        insights_stale: insights_stale,
        recommended_next_step:
          gmail_recommended_next_step(gmail_status, insights_stale, freshest_visible_email_at),
        accounts: gmail_accounts
      }
    }
  end

  defp gmail_account_health(user_id, account) do
    provider = account.provider
    account_email = account_email(account)

    case Gmail.fetch_recent_emails(user_id, 1, provider: provider) do
      {:ok, [message | _]} ->
        %{
          provider: provider,
          account_email: account_email,
          connection_status: account.status,
          status: "ok",
          latest_visible_email_at: datetime_to_iso8601(Map.get(message, :internal_date)),
          latest_visible_email_subject: Map.get(message, :subject),
          latest_visible_email_from: Map.get(message, :from),
          last_error: nil
        }

      {:ok, []} ->
        %{
          provider: provider,
          account_email: account_email,
          connection_status: account.status,
          status: "empty",
          latest_visible_email_at: nil,
          latest_visible_email_subject: nil,
          latest_visible_email_from: nil,
          last_error: nil
        }

      {:error, reason} ->
        ConnectedAccounts.report_access_issue(user_id, provider, reason)

        %{
          provider: provider,
          account_email: account_email,
          connection_status: account.status,
          status: "error",
          latest_visible_email_at: nil,
          latest_visible_email_subject: nil,
          latest_visible_email_from: nil,
          last_error: normalize_error(reason)
        }
    end
  end

  defp gmail_account?(account) do
    is_binary(account.provider) and String.starts_with?(account.provider, "google:")
  end

  defp account_email(account) do
    metadata = account.metadata || %{}

    metadata["account_email"] || metadata["email"] ||
      case account.provider do
        "google:" <> account_email -> account_email
        _ -> nil
      end
  end

  defp latest_gmail_insight_datetime(insight) do
    insight.source_occurred_at || insight.inserted_at
  end

  defp gmail_insights_stale?(%DateTime{} = _freshest_visible_email_at, nil), do: true

  defp gmail_insights_stale?(
         %DateTime{} = freshest_visible_email_at,
         %DateTime{} = latest_insight_at
       ) do
    DateTime.diff(freshest_visible_email_at, latest_insight_at, :hour) >
      @gmail_insight_stale_threshold_hours
  end

  defp gmail_insights_stale?(_freshest_visible_email_at, _latest_insight_at), do: false

  defp gmail_recommended_next_step("not_connected", _insights_stale, _freshest_visible_email_at) do
    "Tell the user Gmail is not connected, or that Maraithon cannot currently inspect inbox state."
  end

  defp gmail_recommended_next_step("error", _insights_stale, _freshest_visible_email_at) do
    "Tell the user Gmail access failed and that Maraithon should notify them to reconnect."
  end

  defp gmail_recommended_next_step("ok", true, %DateTime{} = _freshest_visible_email_at) do
    "Open Gmail insights look stale relative to live inbox mail. Use gmail_search_messages before answering latest or today inbox questions."
  end

  defp gmail_recommended_next_step("ok", _insights_stale, _freshest_visible_email_at), do: nil

  defp normalize_source("gmail:" <> _rest), do: "gmail"
  defp normalize_source("gmail"), do: "gmail"
  defp normalize_source(source) when is_binary(source), do: source
  defp normalize_source(_source), do: nil

  defp datetime_to_iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_to_iso8601(_value), do: nil

  defp parse_iso8601_datetime(%DateTime{} = value), do: value

  defp parse_iso8601_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_iso8601_datetime(_value), do: nil

  defp most_recent_datetime(datetimes) when is_list(datetimes) do
    datetimes
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp normalize_limit(value, _default, max_limit) when is_integer(value),
    do: value |> max(1) |> min(max_limit)

  defp normalize_limit(_value, default, _max_limit), do: default

  defp normalize_timeout(value) when is_integer(value), do: value |> max(1_000) |> min(30_000)
  defp normalize_timeout(_value), do: 12_000

  defp required_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "missing_#{key}"}
    end
  end

  defp optional_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp optional_string_arg(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> :missing
      "" -> :missing
      _ -> {:error, "invalid_#{key}"}
    end
  end

  defp resolve_snooze_until(args) do
    case Map.get(args, "snooze_until") do
      %DateTime{} = value ->
        {:ok, value}

      value when is_binary(value) ->
        case DateTime.from_iso8601(String.trim(value)) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          _ -> {:error, "invalid_snooze_until"}
        end

      _ ->
        {:error, "missing_snooze_until"}
    end
  end

  defp serialize_todo_summary(todo) do
    %{
      id: todo.id,
      source: todo.source,
      source_account_id: todo.source_account_id,
      source_account_label: todo.source_account_label,
      kind: todo.kind,
      attention_mode: todo.attention_mode,
      status: todo.status,
      title: todo.title,
      next_action: todo.next_action,
      due_at: todo.due_at,
      owner_user_id: todo.owner_user_id,
      owner_label: todo.owner_label,
      priority: todo.priority
    }
  end

  defp serialize_todo_detail(todo) do
    %{
      id: todo.id,
      source: todo.source,
      source_account_id: todo.source_account_id,
      source_account_label: todo.source_account_label,
      kind: todo.kind,
      attention_mode: todo.attention_mode,
      status: todo.status,
      title: todo.title,
      summary: todo.summary,
      next_action: todo.next_action,
      due_at: todo.due_at,
      notes: todo.notes,
      action_plan: todo.action_plan,
      action_draft: todo.action_draft || %{},
      owner_user_id: todo.owner_user_id,
      owner_label: todo.owner_label,
      priority: todo.priority,
      source_item_id: todo.source_item_id,
      source_occurred_at: todo.source_occurred_at,
      metadata: todo.metadata || %{},
      updated_at: todo.updated_at
    }
  end

  defp tool_definition(name, description, parameters) do
    %{
      "name" => name,
      "description" => description,
      "parameters" => parameters
    }
  end

  defp maybe_put_default(args, key, value) when is_binary(value) and value != "" do
    Map.put_new(args, key, value)
  end

  defp maybe_put_default(args, _key, _value), do: args

  defp preference_snapshot(user_id) when is_binary(user_id) do
    active_rules = PreferenceMemory.active_rules(user_id)
    pending_rules = PreferenceMemory.pending_rules(user_id)

    %{
      active_count: length(active_rules),
      active_rules: active_rules,
      pending_count: length(pending_rules),
      pending_rules: pending_rules,
      preference_summary: PreferenceMemory.prompt_context(user_id),
      operator_memory: OperatorMemory.summaries_for_prompt(user_id),
      user_memory: UserMemory.prompt_context(user_id),
      deep_memory: Memory.prompt_context(user_id)
    }
  end

  defp preference_snapshot(_user_id) do
    %{
      active_count: 0,
      active_rules: [],
      pending_count: 0,
      pending_rules: [],
      preference_summary: %{},
      operator_memory: [],
      user_memory: %{},
      deep_memory: %{}
    }
  end

  defp remember_preferences_message(active, pending, saved) do
    cond do
      pending != [] ->
        "I think this should become durable memory. Reply `yes` to save it, or `no` to keep it local only."

      active != [] ->
        "Saved durable preference memory for future operator decisions."

      saved != [] ->
        "Captured the preference update."

      true ->
        "I couldn't persist a durable preference from that yet."
    end
  end

  defp maybe_mark_pending_preference_confirmation(runtime_context, pending_rules)
       when is_list(pending_rules) do
    case {pending_rules, conversation_for_runtime(runtime_context)} do
      {[], _conversation} ->
        :ok

      {[_ | _], %Conversation{} = conversation} ->
        pending_rule_ids =
          pending_rules
          |> Enum.map(&Map.get(&1, "rule_id"))
          |> Enum.filter(&is_binary/1)

        TelegramConversations.mark_awaiting_confirmation(conversation, %{
          "metadata" => %{
            "mode" => "assistant",
            "active_run_id" => Map.get(runtime_context, :run_id),
            "pending_rule_ids" => pending_rule_ids
          }
        })

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_mark_pending_preference_confirmation(_runtime_context, _pending_rules), do: :ok

  defp conversation_for_runtime(%{conversation_id: conversation_id})
       when is_binary(conversation_id) do
    Repo.get(Conversation, conversation_id)
  end

  defp conversation_for_runtime(_runtime_context), do: nil

  defp linked_delivery_id(runtime_context) when is_map(runtime_context) do
    get_in(runtime_context, [:context, :linked_item, :delivery, :id]) ||
      get_in(runtime_context, [:context, "linked_item", "delivery", "id"])
  end

  defp stringify_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), stringify_value(value))
    end)
  end

  defp stringify_map(_map), do: %{}

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_value(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify_value(%Time{} = value), do: Time.to_iso8601(value)
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)
end
