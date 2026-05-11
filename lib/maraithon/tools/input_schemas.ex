defmodule Maraithon.Tools.InputSchemas do
  @moduledoc false

  @string %{"type" => "string"}
  @integer %{"type" => "integer"}
  @boolean %{"type" => "boolean"}
  @object %{"type" => "object", "additionalProperties" => true}
  @string_array %{"type" => "array", "items" => @string}

  def schema_for(name) when is_binary(name) do
    case name do
      "time" ->
        object(%{})

      "http_get" ->
        object(%{"url" => @string, "headers" => @object}, ["url"])

      "read_file" ->
        object(%{"path" => @string, "max_bytes" => @integer}, ["path"])

      "list_files" ->
        object(%{"path" => @string, "limit" => @integer}, ["path"])

      "file_tree" ->
        object(%{"path" => @string, "max_depth" => @integer, "limit" => @integer}, ["path"])

      "search_files" ->
        object(%{"path" => @string, "pattern" => @string, "limit" => @integer}, [
          "path",
          "pattern"
        ])

      "gmail_list_recent" ->
        user_object(%{"max_results" => @integer, "provider" => @string, "account" => @string})

      "gmail_search" ->
        user_object(%{"query" => @string, "max_results" => @integer}, ["query"])

      "gmail_get_message" ->
        user_object(google_account_fields(%{"message_id" => @string}), ["message_id"])

      "gmail_send_message" ->
        user_object(
          google_account_fields(%{
            "to" => @string,
            "subject" => @string,
            "body" => @string,
            "thread_id" => @string,
            "reply_to_message_id" => @string
          }),
          ["to", "subject", "body"]
        )

      "gmail_labels" ->
        user_object(
          google_account_fields(%{
            "action" => enum(~w(list create update delete)),
            "label_id" => @string,
            "name" => @string,
            "label_list_visibility" => @string,
            "message_list_visibility" => @string,
            "text_color" => @string,
            "background_color" => @string
          })
        )

      "gmail_drafts" ->
        user_object(
          google_account_fields(%{
            "action" => enum(~w(list get create update send delete)),
            "draft_id" => @string,
            "to" => @string,
            "subject" => @string,
            "body" => @string,
            "cc" => @string,
            "bcc" => @string,
            "thread_id" => @string,
            "max_results" => @integer
          })
        )

      "gmail_batch_modify" ->
        user_object(
          google_account_fields(%{
            "message_ids" => @string_array,
            "query" => @string,
            "actions" => @string_array,
            "add_label_ids" => @string_array,
            "remove_label_ids" => @string_array,
            "max_results" => @integer
          })
        )

      "gmail_filters" ->
        user_object(
          google_account_fields(%{
            "action" => enum(~w(list get create delete)),
            "filter_id" => @string,
            "from" => @string,
            "to" => @string,
            "subject" => @string,
            "query" => @string,
            "negated_query" => @string,
            "size" => @integer,
            "size_comparison" => @string,
            "add_label_ids" => @string_array,
            "remove_label_ids" => @string_array,
            "forward" => @string
          })
        )

      "google_contacts_search" ->
        user_object(google_account_fields(%{"query" => @string, "max_results" => @integer}), [
          "query"
        ])

      "google_calendar_list_events" ->
        user_object(
          google_account_fields(%{
            "calendar_id" => @string,
            "query" => @string,
            "time_min" => @string,
            "time_max" => @string,
            "max_results" => @integer
          })
        )

      "review_connected_context" ->
        user_object(%{
          "query" => @string,
          "person" => @string,
          "review_goal" => @string,
          "sources" => @string_array,
          "gmail_query" => @string,
          "time_min" => @string,
          "time_max" => @string,
          "since_days" => @integer,
          "max_results" => @integer
        })

      "get_open_loops" ->
        user_object(%{"query" => @string, "limit" => @integer, "include_memory" => @boolean})

      "list_todos" ->
        user_object(todo_filter_fields())

      "upsert_todos" ->
        user_object(%{"todos" => %{"type" => "array", "items" => todo_candidate_schema()}}, [
          "todos"
        ])

      "resolve_todo" ->
        user_object(
          %{
            "todo_id" => @string,
            "status" => enum(~w(done dismissed snoozed)),
            "snooze_until" => @string,
            "resolution_note" => @string,
            "include_remaining" => @boolean
          },
          ["todo_id"]
        )

      "list_people" ->
        user_object(people_filter_fields())

      "get_person" ->
        user_object(person_lookup_fields(%{"include_links" => @boolean}))

      "upsert_person" ->
        user_object(%{"person" => person_schema()} |> Map.merge(person_fields()))

      "delete_person" ->
        user_object(%{"person_id" => @string}, ["person_id"])

      "link_person_data" ->
        user_object(
          %{
            "person_id" => @string,
            "operation" => enum(~w(attach detach)),
            "link" => person_link_schema()
          }
          |> Map.merge(person_link_fields()),
          ["person_id"]
        )

      "get_relationship_context" ->
        user_object(person_lookup_fields(%{"link_limit" => @integer, "resource_type" => @string}))

      "learn_relationship_context" ->
        user_object(
          %{
            "source" => @string,
            "observations" => %{"type" => "array", "items" => relationship_observation_schema()}
          },
          ["observations"]
        )

      "list_memories" ->
        user_object(memory_filter_fields())

      "write_memory" ->
        user_object(%{"memory" => memory_schema()} |> Map.merge(memory_fields()))

      "recall_memory" ->
        user_object(%{
          "query" => @string,
          "text" => @string,
          "limit" => @integer,
          "kind" => @string,
          "scope" => @string,
          "tag" => @string
        })

      "forget_memory" ->
        user_object(%{
          "memory_id" => @string,
          "query" => @string,
          "status" => enum(~w(archived superseded rejected))
        })

      "record_memory_feedback" ->
        user_object(%{"feedback" => feedback_schema()} |> Map.merge(feedback_fields()))

      "github_create_issue_comment" ->
        object(
          %{
            "user_id" => @string,
            "owner" => @string,
            "repo" => @string,
            "issue_number" => @integer,
            "body" => @string
          },
          ["owner", "repo", "issue_number", "body"]
        )

      "slack_post_message" ->
        user_object(
          slack_base_fields(%{"channel" => @string, "text" => @string, "thread_ts" => @string}),
          ["team_id", "channel", "text"]
        )

      "slack_list_conversations" ->
        user_object(
          slack_base_fields(%{
            "types" => @string_array,
            "limit" => @integer,
            "exclude_archived" => @boolean
          }),
          ["team_id"]
        )

      "slack_list_messages" ->
        user_object(
          slack_base_fields(%{
            "channel" => @string,
            "limit" => @integer,
            "oldest" => @string,
            "latest" => @string,
            "inclusive" => @boolean
          }),
          ["team_id", "channel"]
        )

      "slack_get_thread_replies" ->
        user_object(
          slack_base_fields(%{
            "channel" => @string,
            "thread_ts" => @string,
            "limit" => @integer,
            "oldest" => @string,
            "latest" => @string,
            "inclusive" => @boolean
          }),
          ["team_id", "channel", "thread_ts"]
        )

      "slack_search_messages" ->
        user_object(
          slack_base_fields(%{
            "query" => @string,
            "count" => @integer,
            "page" => @integer,
            "sort" => @string,
            "sort_dir" => @string
          }),
          ["team_id", "query"]
        )

      "slack_open_conversation" ->
        user_object(slack_base_fields(%{"user_ids" => @string_array, "return_im" => @boolean}), [
          "team_id",
          "user_ids"
        ])

      "linear_create_comment" ->
        user_object(%{"issue_id" => @string, "body" => @string}, ["issue_id", "body"])

      "linear_create_issue" ->
        user_object(linear_issue_fields(%{"team_id" => @string, "title" => @string}), [
          "team_id",
          "title"
        ])

      "linear_get_issue" ->
        user_object(%{"issue_id" => @string}, ["issue_id"])

      "linear_list_issues" ->
        user_object(%{
          "limit" => @integer,
          "after" => @string,
          "team_id" => @string,
          "assignee_id" => @string,
          "state_id" => @string,
          "project_id" => @string,
          "label_id" => @string,
          "query" => @string,
          "created_after" => @string,
          "updated_after" => @string
        })

      "linear_list_teams" ->
        user_object(%{})

      "linear_update_issue" ->
        user_object(linear_issue_fields(%{"issue_id" => @string, "due_date" => @string}), [
          "issue_id"
        ])

      "linear_update_issue_state" ->
        user_object(%{"issue_id" => @string, "state_id" => @string}, ["issue_id", "state_id"])

      "notaui_list_tasks" ->
        user_object(%{
          "account_id" => @string,
          "statuses" => @string_array,
          "limit" => @integer,
          "query" => @string
        })

      "notaui_complete_task" ->
        user_object(%{"account_id" => @string, "task_id" => @string}, ["task_id"])

      "notaui_update_task" ->
        user_object(
          %{
            "account_id" => @string,
            "task_id" => @string,
            "title" => @string,
            "notes" => @string,
            "status" => @string,
            "due_at" => @string
          },
          ["task_id"]
        )

      "notion_search" ->
        user_object(
          notion_fields(%{"query" => @string, "page_size" => @integer, "start_cursor" => @string})
        )

      "notion_get_page" ->
        user_object(notion_fields(%{"page_id" => @string}), ["page_id"])

      "notion_query_database" ->
        user_object(
          notion_fields(%{
            "database_id" => @string,
            "filter" => @object,
            "sorts" => %{"type" => "array", "items" => @object},
            "page_size" => @integer,
            "start_cursor" => @string
          }),
          ["database_id"]
        )

      "notion_create_page" ->
        user_object(
          notion_fields(%{
            "parent" => @object,
            "properties" => @object,
            "children" => %{"type" => "array", "items" => @object}
          })
        )

      "notion_update_page" ->
        user_object(
          notion_fields(%{"page_id" => @string, "properties" => @object, "archived" => @boolean}),
          ["page_id"]
        )

      "notion_blocks" ->
        user_object(
          notion_fields(%{
            "action" => enum(~w(list_children append_children update archive)),
            "block_id" => @string,
            "children" => %{"type" => "array", "items" => @object},
            "block" => @object,
            "page_size" => @integer,
            "start_cursor" => @string
          }),
          ["block_id"]
        )

      "notes_search" ->
        user_object(
          %{"query" => @string, "limit" => @integer, "folder" => @string},
          ["query"]
        )

      "notes_get" ->
        user_object(%{"note_id" => @string}, ["note_id"])

      "notes_list_recent" ->
        user_object(%{"limit" => @integer, "folder" => @string})

      "voice_memos_search" ->
        user_object(%{"query" => @string, "limit" => @integer}, ["query"])

      "voice_memos_get" ->
        user_object(%{"memo_id" => @string}, ["memo_id"])

      "voice_memos_list_recent" ->
        user_object(%{"limit" => @integer})

      "files_search" ->
        user_object(
          %{
            "query" => @string,
            "limit" => @integer,
            "extension" => @string,
            "path_substring" => @string
          },
          ["query"]
        )

      "files_get" ->
        user_object(%{"file_id" => @string}, ["file_id"])

      "files_list_recent" ->
        user_object(%{"limit" => @integer, "extension" => @string})

      "messages_search" ->
        user_object(
          %{
            "query" => @string,
            "limit" => @integer,
            "from_handle" => @string,
            "since" => @string,
            "before" => @string
          },
          ["query"]
        )

      "messages_get" ->
        user_object(%{"message_id" => @string}, ["message_id"])

      "messages_list_recent" ->
        user_object(%{"limit" => @integer, "chat_key" => @string})

      "messages_chats_recent" ->
        user_object(%{"limit" => @integer})

      "reminders_open" ->
        user_object(%{"limit" => @integer, "list_name" => @string})

      "reminders_due_soon" ->
        user_object(%{
          "limit" => @integer,
          "days_ahead" => @integer,
          "list_name" => @string
        })

      "reminders_search" ->
        user_object(
          %{"query" => @string, "limit" => @integer, "list_name" => @string},
          ["query"]
        )

      "reminders_get" ->
        user_object(%{"reminder_id" => @string}, ["reminder_id"])

      "calendar_events_around" ->
        user_object(%{
          "since" => @string,
          "until" => @string,
          "limit" => @integer
        })

      "calendar_events_for_person" ->
        user_object(
          %{
            "email_or_substring" => @string,
            "since" => @string,
            "limit" => @integer
          },
          ["email_or_substring"]
        )

      "calendar_search" ->
        user_object(
          %{
            "query" => @string,
            "since" => @string,
            "limit" => @integer
          },
          ["query"]
        )

      "calendar_event_get" ->
        user_object(%{"event_id" => @string}, ["event_id"])

      "browser_history_recent" ->
        user_object(%{"limit" => @integer, "browser" => @string})

      "browser_history_by_host" ->
        user_object(
          %{"host" => @string, "limit" => @integer, "browser" => @string},
          ["host"]
        )

      "browser_history_search" ->
        user_object(
          %{"query" => @string, "limit" => @integer, "browser" => @string},
          ["query"]
        )

      "browser_history_get" ->
        user_object(%{"visit_id" => @string}, ["visit_id"])

      "recall_anywhere" ->
        user_object(
          %{
            "query" => @string,
            "limit" => @integer,
            "sources" => @string_array
          },
          ["query"]
        )

      "companion_devices_list" ->
        user_object(%{})

      "notes_semantic_search" ->
        user_object(
          %{"query" => @string, "limit" => @integer, "folder" => @string},
          ["query"]
        )

      "voice_memos_semantic_search" ->
        user_object(%{"query" => @string, "limit" => @integer}, ["query"])

      "messages_semantic_search" ->
        user_object(
          %{"query" => @string, "limit" => @integer, "from_handle" => @string},
          ["query"]
        )

      "calendar_semantic_search" ->
        user_object(
          %{"query" => @string, "limit" => @integer, "since" => @string},
          ["query"]
        )

      "reminders_semantic_search" ->
        user_object(
          %{"query" => @string, "limit" => @integer, "list_name" => @string},
          ["query"]
        )

      "files_semantic_search" ->
        user_object(
          %{
            "query" => @string,
            "limit" => @integer,
            "extension" => @string,
            "path_substring" => @string
          },
          ["query"]
        )

      _ ->
        object(%{})
    end
  end

  def schema_for(_name), do: object(%{})

  defp user_object(properties, required \\ []) do
    object(Map.put(properties, "user_id", @string), ["user_id" | required])
  end

  defp object(properties, required \\ []) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => Enum.uniq(required),
      "additionalProperties" => true
    }
  end

  defp enum(values), do: %{"type" => "string", "enum" => values}

  defp google_account_fields(properties) do
    Map.merge(properties, %{
      "provider" => @string,
      "google_provider" => @string,
      "account" => @string,
      "account_email" => @string,
      "google_account_email" => @string
    })
  end

  defp todo_filter_fields do
    %{
      "limit" => @integer,
      "query" => @string,
      "status" => @string,
      "statuses" => @string_array,
      "source" => @string,
      "source_account_id" => @integer,
      "kind" => @string,
      "attention_mode" => @string,
      "owner_user_id" => @string,
      "due_before" => @string,
      "due_after" => @string
    }
  end

  defp todo_candidate_schema do
    object(%{
      "source" => @string,
      "source_account_label" => @string,
      "title" => @string,
      "summary" => @string,
      "todo" => @string,
      "due_at" => @string,
      "notes" => @string,
      "next_action" => @string,
      "action_plan" => @string,
      "action_draft" => @object,
      "owner_user_id" => @string,
      "owner_label" => @string,
      "priority" => @integer,
      "dedupe_key" => @string,
      "metadata" => @object,
      "people" => %{"type" => "array", "items" => person_schema()},
      "memories" => %{"type" => "array", "items" => memory_schema()}
    })
  end

  defp people_filter_fields do
    %{
      "limit" => @integer,
      "query" => @string,
      "relationship" => @string,
      "preferred_communication_method" => @string,
      "communication_frequency" => @string,
      "contact_kind" => @string,
      "contact_value" => @string
    }
  end

  defp person_lookup_fields(extra) do
    Map.merge(
      person_fields(),
      Map.merge(extra, %{"person_id" => @string, "id" => @string, "query" => @string})
    )
  end

  defp person_fields do
    %{
      "first_name" => @string,
      "last_name" => @string,
      "display_name" => @string,
      "contact_details" => @object,
      "email" => @string,
      "emails" => @string_array,
      "phone" => @string,
      "phones" => @string_array,
      "slack_id" => @string,
      "slack_ids" => @string_array,
      "telegram_id" => @string,
      "telegram_ids" => @string_array,
      "preferred_communication_method" => @string,
      "relationship" => @string,
      "communication_frequency" => @string,
      "notes" => @string,
      "metadata" => @object
    }
  end

  defp person_schema, do: object(person_fields())

  defp person_link_fields do
    %{
      "resource_type" => @string,
      "resource_id" => @string,
      "todo_id" => @string,
      "resource_source" => @string,
      "title" => @string,
      "summary" => @string,
      "relationship_note" => @string,
      "metadata" => @object
    }
  end

  defp person_link_schema, do: object(person_link_fields())

  defp relationship_observation_schema do
    object(%{
      "source" => @string,
      "resource_type" => @string,
      "resource_id" => @string,
      "title" => @string,
      "summary" => @string,
      "from" => @string,
      "to" => @string,
      "account" => @string,
      "occurred_at" => @string,
      "body_excerpt" => @string,
      "metadata" => @object
    })
  end

  defp memory_filter_fields do
    %{
      "limit" => @integer,
      "query" => @string,
      "status" => @string,
      "kind" => @string,
      "scope" => @string,
      "tag" => @string
    }
  end

  defp memory_fields do
    %{
      "memory_id" => @string,
      "dedupe_key" => @string,
      "kind" => @string,
      "scope" => @string,
      "title" => @string,
      "content" => @string,
      "summary" => @string,
      "source" => @string,
      "source_ref_type" => @string,
      "source_ref_id" => @string,
      "author_type" => @string,
      "tags" => @string_array,
      "importance" => @integer,
      "confidence" => %{"type" => "number"},
      "polarity" => enum(~w(neutral positive negative)),
      "metadata" => @object,
      "expires_at" => @string
    }
  end

  defp memory_schema, do: object(memory_fields())

  defp feedback_fields do
    %{
      "feedback" => @string,
      "polarity" => @string,
      "subject" => @string,
      "content" => @string,
      "title" => @string,
      "reason" => @string,
      "resource_type" => @string,
      "resource_id" => @string,
      "tags" => @string_array,
      "metadata" => @object
    }
  end

  defp feedback_schema, do: object(feedback_fields())

  defp slack_base_fields(properties) do
    Map.merge(properties, %{
      "team_id" => @string,
      "token_preference" => @string,
      "slack_user_id" => @string
    })
  end

  defp linear_issue_fields(properties) do
    Map.merge(properties, %{
      "description" => @string,
      "priority" => @integer,
      "assignee_id" => @string,
      "project_id" => @string,
      "state_id" => @string,
      "label_ids" => @string_array
    })
  end

  defp notion_fields(properties) do
    Map.merge(properties, %{
      "provider" => @string,
      "notion_provider" => @string,
      "account" => @string
    })
  end
end
