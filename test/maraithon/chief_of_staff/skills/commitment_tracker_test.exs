defmodule Maraithon.ChiefOfStaff.Skills.CommitmentTrackerTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.Skills
  alias Maraithon.ChiefOfStaff.Skills.CommitmentTracker
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.Crm
  alias Maraithon.LLM.RequestBudget
  alias Maraithon.Todos

  setup do
    Skills.clear_process_override()

    user_id = "commitment-tracker-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{}
      })

    %{user_id: user_id, agent: agent}
  end

  test "is registered and enabled by default" do
    assert Skills.get!("commitment_tracker") == CommitmentTracker
    assert "commitment_tracker" in Skills.default_enabled_ids()
  end

  test "tracker input uses the active local timezone for named zones", %{user_id: user_id} do
    now = ~U[2026-05-09 15:00:00Z]

    state =
      CommitmentTracker.init(%{
        "user_id" => user_id,
        "timezone" => "America/Toronto",
        "timezone_offset_hours" => -5
      })

    input =
      CommitmentTracker.build_tracker_input(
        user_id,
        now,
        state,
        %{source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now})}
      )

    assert input["date"] == "2026-05-09"
    assert input["timezone"] == "ET"
    assert input["timezone_offset_hours"] == -4
  end

  test "bounds the complete LLM request for oversized multi-source evidence", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-09 15:00:00Z]

    large_body =
      String.duplicate("Source-backed \"quoted\" commitment evidence at C:\\work\\file. ", 300)

    messages =
      Enum.map(1..40, fn index ->
        %{
          "message_id" => "large-message-#{index}",
          "thread_id" => "large-thread-#{index}",
          "labels" => ["INBOX"],
          "from" => "Counterparty #{index} <counterparty#{index}@example.com>",
          "to" => "Operator <operator@example.com>",
          "subject" => "Commitment evidence #{index}",
          "text_body" => large_body,
          "internal_date" => DateTime.add(now, -index, :minute),
          "account" => "operator@example.com"
        }
      end)

    source_items =
      Enum.map(1..20, fn index ->
        %{
          "guid" => "source-item-#{index}",
          "text" => large_body,
          "text_resolved" => large_body,
          "summary" => large_body,
          "body" => large_body,
          "snippet" => large_body,
          "transcript" => large_body,
          "notes" => large_body,
          "text_content" => large_body,
          "title" => large_body,
          "filename" => "commitment-#{index}.txt",
          "sender_handle" => "+1555000#{index}",
          "sent_at" => DateTime.add(now, -index, :minute),
          "date" => DateTime.add(now, -index, :minute),
          "created_at" => DateTime.to_iso8601(DateTime.add(now, -index, :minute)),
          "modified_at" => DateTime.to_iso8601(DateTime.add(now, -index, :minute)),
          "last_visited_at" => DateTime.to_iso8601(DateTime.add(now, -index, :minute)),
          "start" => DateTime.add(now, index, :hour),
          "end" => DateTime.add(now, index + 1, :hour),
          "search_mode" => "self_authored",
          "ts" => Integer.to_string(1_700_000_000 + index),
          "channel_id" => "channel-#{index}"
        }
      end)

    source_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        # Deliberately reverse connector order: prompt selection must sort by
        # source timestamp rather than trusting transport order.
        "inbox_messages" => Enum.reverse(messages),
        "sent_messages" =>
          messages
          |> Enum.map(fn message ->
            message
            |> Map.put("labels", ["SENT"])
            |> Map.put("from", "Operator <operator@example.com>")
          end)
          |> Enum.reverse(),
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_calendar(%{
        "events" => source_items,
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_calendar_local(%{
        "events" => source_items,
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_slack(%{
        "messages" => source_items,
        "mentions" => source_items,
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_imessage(%{
        "messages" => source_items,
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_notes(%{
        "notes" => source_items,
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_voice_memos(%{
        "memos" => source_items,
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_reminders(%{
        "reminders" => source_items,
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_files(%{
        "files" => source_items,
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_browser_history(%{
        "visits" => source_items,
        "status" => "ready",
        "fetched_at" => now
      })

    state =
      CommitmentTracker.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "commitment_review_hour_local" => 7
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: source_bundle,
      assistant_cycle_id: "cycle-large-commitments"
    }

    assert {:effect, {:llm_call, params}, _state} =
             CommitmentTracker.handle_wakeup(state, context)

    assert {:ok, bounded} = RequestBudget.validate(params)
    assert byte_size(Jason.encode!(bounded)) <= 128_000

    prompt = get_in(params, ["messages", Access.at(0), "content"])

    [_instructions, input_json] =
      String.split(prompt, "Commitment tracker input JSON:\n", parts: 2)

    input = Jason.decode!(String.trim(input_json))

    input_bytes = byte_size(Jason.encode!(input))
    assert input_bytes in 78_000..82_000
    assert length(get_in(input, ["gmail", "recent_inbox"])) == 16
    assert length(get_in(input, ["gmail", "recent_sent"])) == 16
    assert get_in(input, ["gmail", "counts", "recent_inbox"]) == 40
    assert get_in(input, ["gmail", "counts", "recent_sent"]) == 40

    [first_inbox | _rest] = get_in(input, ["gmail", "recent_inbox"])
    assert first_inbox["subject"] == "Commitment evidence 1"
    assert first_inbox["from"] =~ "Counterparty 1"
    assert first_inbox["body"] =~ ~s(Source-backed "quoted" commitment evidence)
  end

  test "prompt retrieval promotes full-body obligations beyond newer Gmail noise", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-09 15:00:00Z]

    noise_messages =
      Enum.map(1..20, fn index ->
        %{
          "message_id" => "noise-message-#{index}",
          "thread_id" => "noise-thread-#{index}",
          "labels" => ["INBOX"],
          "from" => "Digest <digest@example.com>",
          "to" => "Operator <operator@example.com>",
          "subject" => "Weekly update #{index}",
          "text_body" => "This is a routine informational digest with no action required.",
          "internal_date" => DateTime.add(now, -index, :minute),
          "account" => "operator@example.com"
        }
      end)

    subject_only = %{
      "message_id" => "subject-only-message",
      "thread_id" => "subject-only-thread",
      "labels" => ["INBOX"],
      "from" => "Automated <automated@example.com>",
      "to" => "Operator <operator@example.com>",
      "subject" => "Please sign by Friday or launch is blocked",
      "snippet" => "Please sign by Friday or launch is blocked",
      "internal_date" => DateTime.add(now, -21, :minute),
      "account" => "operator@example.com"
    }

    actionable = %{
      "message_id" => "actionable-message",
      "thread_id" => "actionable-thread",
      "labels" => ["INBOX"],
      "from" => "Dana <dana@example.com>",
      "to" => "Operator <operator@example.com>",
      "subject" => "Agreement",
      "text_body" =>
        "Please sign the agreement by Friday; the customer launch is blocked waiting on you.",
      "internal_date" => DateTime.add(now, -22, :minute),
      "account" => "operator@example.com"
    }

    source_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "inbox_messages" => noise_messages ++ [subject_only, actionable],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    state =
      CommitmentTracker.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "commitment_review_hour_local" => 7
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: source_bundle,
      assistant_cycle_id: "cycle-priority-commitments"
    }

    assert {:effect, {:llm_call, params}, _state} =
             CommitmentTracker.handle_wakeup(state, context)

    assert {:ok, bounded} = RequestBudget.validate(params)
    assert byte_size(Jason.encode!(bounded)) <= 128_000

    prompt = get_in(params, ["messages", Access.at(0), "content"])

    [_instructions, input_json] =
      String.split(prompt, "Commitment tracker input JSON:\n", parts: 2)

    input = Jason.decode!(String.trim(input_json))
    inbox = get_in(input, ["gmail", "recent_inbox"])
    thread_ids = Enum.map(inbox, & &1["thread_id"])

    assert length(inbox) == 16
    assert hd(thread_ids) == "actionable-thread"
    assert "actionable-thread" in thread_ids
    refute "subject-only-thread" in thread_ids
    assert "noise-thread-1" in thread_ids
  end

  test "tracker input resolves iMessage sender phone numbers from People", %{user_id: user_id} do
    now = ~U[2026-05-09 15:00:00Z]

    {:ok, person} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Charlie Smith",
        "phone" => "+1 (416) 526-1454",
        "relationship" => "Customer sponsor"
      })

    source_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_imessage(%{
        "messages" => [
          %{
            "guid" => "msg-charlie",
            "source" => "imessage",
            "sender_handle" => "+14165261454",
            "text" => "Can you send the pricing answer?",
            "sent_at" => now,
            "source_item_id" => "msg-charlie"
          }
        ],
        "chats" => [
          %{
            "chat_key" => "+14165261454",
            "latest_sender" => "+14165261454",
            "latest_snippet" => "Can you send the pricing answer?",
            "latest_sent_at" => DateTime.to_iso8601(now)
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })

    state =
      CommitmentTracker.init(%{
        "user_id" => user_id,
        "timezone" => "America/Toronto",
        "timezone_offset_hours" => -4
      })

    input =
      CommitmentTracker.build_tracker_input(
        user_id,
        now,
        state,
        %{source_bundle: source_bundle}
      )

    [message] = get_in(input, ["imessage", "recent_messages"])
    assert message["sender_handle"] == "+14165261454"
    assert message["sender_display_name"] == "Charlie Smith"
    assert message["sender_person_id"] == person.id
    assert message["sender_relationship"] == "Customer sponsor"

    [chat] = get_in(input, ["imessage", "chats"])
    assert chat["latest_sender"] == "+14165261454"
    assert chat["latest_sender_display_name"] == "Charlie Smith"
    assert chat["latest_sender_person_id"] == person.id
  end

  test "builds a checked prompt and persists model-emitted commitment work items", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-09 15:00:00Z]

    source_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "inbox_messages" => [
          %{
            "message_id" => "aa11",
            "thread_id" => "cc33",
            "google_provider" => "google:kent@runner.now",
            "labels" => ["INBOX"],
            "from" => "Elena Saradidis <elena@example.com>",
            "to" => "Kent <kent@runner.now>",
            "subject" => "Ambassador agreement",
            "snippet" => "Can you send the revised agreement?",
            "text_body" =>
              "Kent, can you send the revised Runner ambassador agreement by tomorrow?",
            "internal_date" => now,
            "account" => "kent@runner.now"
          }
        ],
        "sent_messages" => [
          %{
            "message_id" => "bb22",
            "thread_id" => "cc33",
            "google_provider" => "google:kent@runner.now",
            "labels" => ["SENT"],
            "from" => "Kent <kent@runner.now>",
            "to" => "Elena Saradidis <elena@example.com>",
            "subject" => "Re: Ambassador agreement",
            "text_body" => "I'll send the revised version tomorrow.",
            "internal_date" => now,
            "account" => "kent@runner.now"
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_calendar(%{
        "events" => [
          %{
            "event_id" => "evt-elena",
            "summary" => "Send Elena agreement",
            "start" => ~U[2026-05-10 13:00:00Z],
            "end" => ~U[2026-05-10 13:30:00Z],
            "attendees" => [%{"email" => "elena@example.com"}],
            "account" => "kent@runner.now"
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })

    state =
      CommitmentTracker.init(%{
        "user_id" => user_id,
        "timezone" => "America/Toronto",
        "timezone_offset_hours" => -4,
        "commitment_review_hour_local" => 7
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: source_bundle,
      assistant_cycle_id: "cycle-commitments"
    }

    {:effect, {:llm_call, params}, state} = CommitmentTracker.handle_wakeup(state, context)

    assert params["max_tokens"] == 32_000
    assert params["reasoning_effort"] == "high"

    prompt = get_in(params, ["messages", Access.at(0), "content"])
    assert prompt =~ "Commitment Tracker"
    assert prompt =~ "Commitment tracker input JSON"
    assert prompt =~ "Return only valid JSON"
    assert prompt =~ "Return at most 12 todo objects"
    assert prompt =~ "Open work review"
    assert prompt =~ "do not write \"Commitment"
    assert prompt =~ "source_access"
    assert prompt =~ "iMessage, WhatsApp, OmniFocus"
    assert prompt =~ "actionable personal, family/home, or business obligation"
    assert prompt =~ "Skip content consumption and educational material"
    assert prompt =~ "podcasts, videos, reports, course/webinar announcements"
    assert prompt =~ "can you send the revised Runner ambassador agreement"
    assert prompt =~ "I'll send the revised version tomorrow."
    assert prompt =~ "Send Elena agreement"

    response = %{
      content:
        Jason.encode!(%{
          "title" => "Commitment tracker - 2026-05-09",
          "summary" => "One Runner commitment was found and logged.",
          "body" =>
            "Commitment Tracker - 2026-05-09\n\nNew commitments:\n- Send Elena the revised Runner ambassador agreement by tomorrow.",
          "todos" => [
            %{
              "source" => "gmail",
              "title" => "Send Elena the revised Runner ambassador agreement",
              "summary" => "Kent owes Elena the revised Runner ambassador agreement by tomorrow.",
              "next_action" => "Open the latest agreement, confirm terms, and send it.",
              "due_at" => "2026-05-10T13:00:00Z",
              "notes" =>
                "To: Elena Saradidis\nDirection: i_owe\nSource: gmail\nRef: thread-elena\nQuote: I'll send the revised version tomorrow.",
              "action_plan" =>
                "Find the latest agreement, verify the date, and email it to Elena.",
              "action_draft" => %{
                "text" =>
                  "You should email Elena and say: \"Thanks, I have the revised Runner ambassador agreement ready. Sending it over for your review.\""
              },
              "owner_label" => "Kent",
              # Model-provided account hints are not authoritative; matched
              # source provenance must replace a stale or hallucinated label.
              "source_account_label" => "wrong@example.com",
              "source_item_id" => "bb22",
              "source_occurred_at" => "2026-05-09T15:00:00Z",
              "dedupe_key" => "commitment:gmail:thread-elena:send-revised-agreement",
              "people" => [
                %{
                  "first_name" => "Elena",
                  "last_name" => "Saradidis",
                  "relationship" => "Runner ambassador",
                  "preferred_communication_method" => "email"
                }
              ],
              "metadata" => %{
                "commitment_direction" => "i_owe",
                "explicit_user_commitment" => true,
                "source_ref" => "gmail thread-elena",
                "quote" => "I'll send the revised version tomorrow.",
                "omni_project" => "Runner",
                "why_it_matters" =>
                  "Elena is waiting on a revised Runner ambassador agreement the operator promised to send.",
                "source_tags" => ["runner", "gmail"],
                "completion_check" => %{
                  "status" => "open",
                  "reasoning" =>
                    "Checked later Gmail and calendar evidence in the supplied window; there is no later sent message delivering the agreement or canceling the commitment.",
                  "latest_source_checked_at" => "2026-05-09T15:00:00Z",
                  "later_evidence" => []
                }
              }
            }
          ]
        })
    }

    {:emit, {:briefs_recorded, payload}, _state} =
      CommitmentTracker.handle_effect_result({:llm_call, response}, state, context)

    assert payload.cadences == ["commitment_tracker"]
    assert payload.generation_mode == "llm"
    assert payload.generation_error == false
    assert payload.proposed_todo_count == 1
    assert payload.pending_reply_count == 0
    assert payload.already_tracked_count == 0
    assert payload.missing_source_count == 0
    assert payload.todo_count == 1
    assert payload.todo_skipped_count == 0

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.cadence == "commitment_tracker"
    assert brief.title == "Open work review - 2026-05-09"
    assert brief.body =~ "Added to open work:"
    assert brief.body =~ "- Send Elena the revised Runner ambassador agreement"
    refute brief.body =~ "Maraithon list"
    refute brief.body =~ "todos"
    refute brief.body =~ "Commitment Tracker"
    assert brief.metadata["origin_skill_id"] == "commitment_tracker"
    assert get_in(brief.metadata, ["tracker_input", "counts", "gmail_recent_inbox"]) == 1
    assert get_in(brief.metadata, ["tracker_input", "counts", "gmail_recent_sent"]) == 1
    assert get_in(brief.metadata, ["tracker_input", "counts", "calendar_upcoming_events"]) == 1

    [todo] = Todos.list_for_user(user_id, source: "gmail", limit: 5)
    refute brief.body =~ todo.id
    assert todo.title == "Send Elena the revised Runner ambassador agreement"
    assert todo.summary == "You owe Elena the revised Runner ambassador agreement by tomorrow."
    assert todo.metadata["origin_skill_id"] == "commitment_tracker"
    assert todo.metadata["commitment_direction"] == "i_owe"
    assert todo.metadata["omni_project"] == "Runner"
    assert todo.source_item_id == "cc33"
    assert todo.source_account_label == "kent@runner.now"
    assert todo.metadata["gmail_message_id"] == "bb22"
    assert todo.metadata["gmail_thread_id"] == "cc33"
    assert todo.metadata["google_provider"] == "google:kent@runner.now"
    assert todo.metadata["google_account_email"] == "kent@runner.now"

    assert get_in(todo.metadata, ["todo_intelligence", "source"]) ==
             "chief_of_staff_commitment_tracker"

    assert payload.linked_todo_ids == [todo.id]
    assert brief.metadata["linked_todo_ids"] == [todo.id]
    assert brief.metadata["todo_digest"] == true
    assert brief.metadata["todo_digest_count"] == 1

    [person] = Crm.list_people(user_id, query: "Elena", limit: 5)
    assert person.display_name == "Elena Saradidis"

    assert {:ok, relationship} =
             Crm.relationship_context(user_id, %{"person_id" => person.id, "link_limit" => 5})

    assert relationship.open_todo_count == 1
    assert Enum.any?(relationship.todos, &(&1.id == todo.id))

    oversized_response =
      response.content
      |> Jason.decode!()
      |> Map.update!("todos", fn [todo_payload] -> List.duplicate(todo_payload, 13) end)
      |> then(&%{content: Jason.encode!(&1)})

    {:emit, {:briefs_recorded, capped_payload}, _state} =
      CommitmentTracker.handle_effect_result({:llm_call, oversized_response}, state, context)

    assert capped_payload.proposed_todo_count == 12
  end

  test "captures future-dated Slack self-commitments as snoozed follow-up work", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2099-06-18 21:15:00Z]
    message_ts = "4085500260.000100"
    source_item_id = "C-gtm:#{message_ts}"
    snoozed_until = ~U[2099-06-19 20:00:00Z]
    early_model_snooze = ~U[2099-06-19 13:00:00Z]

    source_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_slack(%{
        "workspaces" => [
          %{
            "team_id" => "T-agora",
            "team_name" => "Agora",
            "channels" => [
              %{
                "id" => "C-gtm",
                "name" => "runner-gtm",
                "messages" => [
                  %{
                    "conversation_kind" => "private_channel",
                    "ts" => message_ts,
                    "thread_ts" => "4085498460.000000",
                    "date" => "2099-06-18T21:11:00Z",
                    "user" => "U-kent",
                    "user_display_name" => "Kent",
                    "text" => "I am going to message Sheila tomorrow.",
                    "text_resolved" => "I am going to message Sheila tomorrow.",
                    "search_mode" => "self_authored",
                    "search_query" => "\"I am going to\"",
                    "reply_count" => 0,
                    "permalink" => "https://example.slack.com/archives/C-gtm/p4085500260000100"
                  },
                  %{
                    "conversation_kind" => "private_channel",
                    "ts" => "4085500140.000000",
                    "thread_ts" => "4085498460.000000",
                    "date" => "2099-06-18T21:09:00Z",
                    "user" => "U-charlie",
                    "user_display_name" => "Charlie",
                    "text" => "Oh that's kinda interesting!",
                    "text_resolved" => "Oh that's kinda interesting!",
                    "reply_count" => 0
                  }
                ]
              }
            ]
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })

    state =
      CommitmentTracker.init(%{
        "user_id" => user_id,
        "timezone" => "America/Toronto",
        "timezone_offset_hours" => -4,
        "commitment_review_hour_local" => 7
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: source_bundle,
      assistant_cycle_id: "cycle-slack-self-commitment"
    }

    {:effect, {:llm_call, params}, state} = CommitmentTracker.handle_wakeup(state, context)

    prompt = get_in(params, ["messages", Access.at(0), "content"])
    assert prompt =~ "I am going to message Sheila tomorrow."

    assert prompt =~ "The operator's own Slack thread or channel message"
    assert prompt =~ "\"self_authored_recent\""
    assert prompt =~ "do not create work from the search query or phrase match alone"
    assert prompt =~ "save that as work even when nobody explicitly"
    assert prompt =~ "I am going to message Pat tomorrow"
    assert prompt =~ "status to \"snoozed\""
    assert prompt =~ "snoozed_until"
    assert prompt =~ "around 4 PM local"

    response = %{
      content:
        Jason.encode!(%{
          "title" => "Open work review - 2099-06-18",
          "summary" => "One Slack commitment was saved for tomorrow follow-up.",
          "body" =>
            "Open work review - 2099-06-18\n\nNew commitments:\n- Message Sheila tomorrow about the free-license idea.",
          "pending_replies" => [],
          "already_tracked" => [],
          "missing_sources" => [],
          "todos" => [
            %{
              "source" => "slack",
              "title" => "Message Sheila about the EA license idea",
              "summary" =>
                "You said you would message Sheila tomorrow about giving a few EAs free licenses.",
              "next_action" =>
                "Message Sheila tomorrow about the free-license idea, then mark this done.",
              "due_at" => DateTime.to_iso8601(early_model_snooze),
              "status" => "snoozed",
              "snoozed_until" => DateTime.to_iso8601(early_model_snooze),
              "notes" =>
                "Channel: runner-gtm\nDirection: i_owe\nSource: slack\nRef: #{source_item_id}\nQuote: I am going to message Sheila tomorrow.",
              "action_plan" =>
                "Send Sheila a short note about whether a few EAs should get free licenses.",
              "action_draft" => %{
                "text" =>
                  "You should message Sheila and say: \"Thinking about giving a few Athena EAs free Runner licenses. Worth trying?\""
              },
              "owner_label" => "Kent",
              "source_account_label" => "Agora / runner-gtm",
              "source_item_id" => source_item_id,
              "source_occurred_at" => "2099-06-18T21:11:00Z",
              "dedupe_key" => "commitment:slack:#{source_item_id}:message-sheila",
              "people" => [
                %{
                  "first_name" => "Sheila",
                  "relationship" => "EA license idea counterparty",
                  "preferred_communication_method" => "message"
                }
              ],
              "metadata" => %{
                "commitment_direction" => "i_owe",
                "explicit_user_commitment" => true,
                "source_ref" => "slack #{source_item_id}",
                "slack_channel_id" => "C-gtm",
                "slack_channel_name" => "runner-gtm",
                "slack_thread_ts" => "4085498460.000000",
                "quote" => "I am going to message Sheila tomorrow.",
                "source_tags" => ["slack", "gtm", "sales"],
                "why_it_matters" =>
                  "This is a concrete GTM follow-up the operator committed to in-thread.",
                "completion_check" => %{
                  "status" => "open",
                  "reasoning" =>
                    "Checked later Slack thread context in the supplied window; there is no later message showing Sheila was contacted or that the idea was dropped.",
                  "latest_source_checked_at" => "2099-06-18T21:15:00Z",
                  "later_evidence" => []
                }
              }
            }
          ]
        })
    }

    {:emit, {:briefs_recorded, payload}, _state} =
      CommitmentTracker.handle_effect_result({:llm_call, response}, state, context)

    assert payload.todo_count == 1
    assert payload.todo_skipped_count == 0

    [todo] = Todos.list_for_user(user_id, statuses: ["snoozed"], limit: 5)
    assert todo.source == "slack"
    assert todo.source_item_id == source_item_id
    assert todo.status == "snoozed"
    assert DateTime.compare(todo.snoozed_until, snoozed_until) == :eq
    assert DateTime.compare(todo.due_at, snoozed_until) == :eq
    assert todo.metadata["explicit_user_commitment"] == true
    assert todo.metadata["commitment_direction"] == "i_owe"
    assert todo.metadata["quote"] == "I am going to message Sheila tomorrow."
    assert get_in(todo.metadata, ["completion_check", "status"]) == "open"

    assert Todos.list_open_for_user(user_id, limit: 5) == []
  end

  test "accepts markdown-fenced model JSON as a real commitment report", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-09 15:00:00Z]

    state =
      CommitmentTracker.init(%{
        "user_id" => user_id,
        "timezone" => "America/Toronto",
        "timezone_offset_hours" => -4,
        "commitment_review_hour_local" => 7
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now}),
      assistant_cycle_id: "cycle-fenced-json"
    }

    {:effect, {:llm_call, _params}, state} = CommitmentTracker.handle_wakeup(state, context)

    report_json =
      Jason.encode!(%{
        "title" => "Commitment tracker - 2026-05-09",
        "summary" => "No new commitments are ready to save.",
        "body" =>
          "## Context Used\n- Gmail and calendar context was available.\n\n## Unknowns\n- Anything outside available context remains unknown.",
        "todos" => []
      })

    response = %{
      content: """
      Here is the checked commitment report.

      ```json
      #{report_json}
      ```
      """
    }

    {:emit, {:briefs_recorded, payload}, _state} =
      CommitmentTracker.handle_effect_result({:llm_call, response}, state, context)

    assert payload.generation_mode == "llm"
    assert payload.todo_count == 0
    refute payload.error_message

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title == "Open work review - 2026-05-09"
    assert brief.summary =~ "did not complete a fresh context refresh"
    assert brief.body =~ "## Context Used"
    assert brief.body =~ "## Unknowns"
    assert brief.body =~ "Today's move: run a fresh context refresh"
    assert brief.metadata["generation_mode"] == "llm"
    refute brief.error_message
    refute brief.body =~ "Open work review: fresh context refresh needed"
    refute brief.body =~ "Commitment Tracker"
    refute brief.summary =~ "No new commitments were found"
    refute brief.summary =~ "No reliable commitment review"
    refute brief.body =~ "refresh Gmail"
  end

  test "invalid model output records an available-context fallback without heuristic todo creation",
       %{
         user_id: user_id,
         agent: agent
       } do
    now = ~U[2026-05-09 15:00:00Z]

    state =
      CommitmentTracker.init(%{
        "user_id" => user_id,
        "timezone" => "America/Toronto",
        "timezone_offset_hours" => -4,
        "commitment_review_hour_local" => 7
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now}),
      assistant_cycle_id: "cycle-error"
    }

    {:effect, {:llm_call, _params}, state} = CommitmentTracker.handle_wakeup(state, context)

    {:emit, {:briefs_recorded, payload}, _state} =
      CommitmentTracker.handle_effect_result({:llm_call, %{content: "not json"}}, state, context)

    assert payload.generation_mode == "source_fallback"
    assert payload.todo_count == 0
    assert payload.error_message =~ "available-context fallback"
    assert payload.error_message =~ "model_response_invalid"
    refute payload.error_message =~ "model synthesis"

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title == "Open work review: fresh context refresh needed"
    assert brief.cadence == "commitment_tracker"
    assert brief.error_message =~ "available-context fallback"
    assert brief.error_message =~ "model_response_invalid"
    refute brief.error_message =~ "model synthesis"
    assert brief.metadata["generation_mode"] == "source_fallback"
    assert brief.summary =~ "did not complete a fresh context refresh"
    assert brief.body =~ "## Needs Your Attention"
    assert brief.body =~ "## Unknowns"
    assert brief.body =~ "No open commitment is already saved"
    assert brief.body =~ "Treat this review as incomplete"
    assert brief.body =~ "Today's move:"

    assert brief.body =~
             "No new commitments were saved because the available context did not clearly show a new promise"

    refute brief.summary =~ "No reliable commitment review"
    refute brief.body =~ "refresh Gmail"
    refute brief.body =~ "your list"

    refute brief.body =~ "classified safely"
    refute brief.body =~ "could not produce"
    refute brief.body =~ "model_response_invalid"
    refute brief.body =~ "configured model"
    refute brief.body =~ "structured JSON"
    refute brief.body =~ "heuristic"
    refute brief.body =~ "keyword"
    refute brief.body =~ "finish_reason"

    telegram_payload = Briefs.telegram_payload(brief)
    buttons = telegram_payload.reply_markup["inline_keyboard"] |> List.flatten()

    assert Enum.any?(buttons, &(&1["text"] == "Open Maraithon"))
    refute telegram_payload.text =~ "model_response_invalid"
    refute telegram_payload.text =~ "finish_reason"
    assert Todos.list_for_user(user_id, limit: 5) == []
  end

  test "invalid model output still briefs existing open work without creating new todos", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-09 15:00:00Z]

    {:ok, [existing_todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Send Jordan the investor update",
          "todo" => "Jordan is waiting for the latest investor metrics before Monday.",
          "summary" => "You owe Jordan the latest investor metrics before Monday.",
          "next_action" => "Reply with the current metrics and flag any missing numbers.",
          "due_at" => "2026-05-11T13:00:00Z",
          "dedupe_key" => "commitment:jordan:investor-update",
          "source_account_label" => "kent@runner.now",
          "priority" => 94
        }
      ])

    source_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "inbox_messages" => [
          %{
            "message_id" => "msg-jordan",
            "thread_id" => "thread-jordan",
            "from" => "Jordan <jordan@example.com>",
            "to" => "Kent <kent@runner.now>",
            "subject" => "Investor update",
            "snippet" => "Can you send the current metrics?",
            "text_body" => "Can you send the current metrics before Monday?",
            "internal_date" => now,
            "account" => "kent@runner.now"
          }
        ],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_calendar(%{
        "events" => [
          %{
            "event_id" => "evt-board",
            "summary" => "Board prep",
            "start" => ~U[2026-05-10 13:00:00Z],
            "end" => ~U[2026-05-10 13:30:00Z],
            "account" => "kent@runner.now"
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })

    state =
      CommitmentTracker.init(%{
        "user_id" => user_id,
        "timezone" => "America/Toronto",
        "timezone_offset_hours" => -4,
        "commitment_review_hour_local" => 7
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: source_bundle,
      assistant_cycle_id: "cycle-existing-open-work"
    }

    {:effect, {:llm_call, _params}, state} = CommitmentTracker.handle_wakeup(state, context)

    {:emit, {:briefs_recorded, payload}, _state} =
      CommitmentTracker.handle_effect_result({:llm_call, %{content: "not json"}}, state, context)

    assert payload.generation_mode == "source_fallback"
    assert payload.todo_count == 0
    assert payload.linked_todo_ids == [existing_todo.id]

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title == "Open work review: check existing work"
    assert brief.metadata["generation_mode"] == "source_fallback"
    assert brief.metadata["linked_todo_ids"] == [existing_todo.id]
    assert brief.summary =~ "Start with 1 existing open item"
    assert brief.summary =~ "already in open work"
    assert brief.body =~ "Send Jordan the investor update"
    assert brief.body =~ "Due May 11, 2026 at 9:00 AM ET"
    refute brief.body =~ "1:00 PM UTC"
    refute brief.body =~ "2026-05-11T13:00:00Z"
    assert brief.body =~ "Next: Reply with the current metrics"
    assert brief.body =~ "From Gmail (kent@runner.now)."
    refute brief.body =~ "Source: kent@runner.now"
    assert brief.body =~ "Gmail context: 1 recent inbox message and 0 recent sent messages"
    assert brief.body =~ "Calendar context: 1 upcoming event"
    assert brief.body =~ "Existing open work: 1 open item"
    assert brief.body =~ "## Unknowns"
    assert brief.body =~ "Today's move: clear or explicitly keep the first open item"
    refute brief.body =~ "classified safely"
    refute brief.body =~ "model_response_invalid"
    refute brief.body =~ "structured JSON"
    refute brief.body =~ "finish_reason"

    telegram_payload = Briefs.telegram_payload(brief)
    buttons = telegram_payload.reply_markup["inline_keyboard"] |> List.flatten()

    assert Enum.any?(buttons, &(&1["text"] == "Open Maraithon"))
    assert Enum.any?(buttons, &(&1["text"] == "Review open work"))
    assert Enum.any?(buttons, &(&1["text"] == "Show list"))
    refute telegram_payload.text =~ "model_response_invalid"

    [todo] = Todos.list_for_user(user_id, limit: 5)
    assert todo.id == existing_todo.id
  end

  test "fallback open-work lines humanize local source names", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-09 15:00:00Z]

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "voice_memos",
          "kind" => "local_voice_memo",
          "title" => "Review the launch voice note",
          "summary" => "The launch note includes a pricing follow-up.",
          "next_action" => "Extract the pricing follow-up and decide who owns it.",
          "dedupe_key" => "commitment:voice-note:launch-pricing",
          "priority" => 78
        }
      ])

    state =
      CommitmentTracker.init(%{
        "user_id" => user_id,
        "timezone" => "America/Toronto",
        "timezone_offset_hours" => -4,
        "commitment_review_hour_local" => 7
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now}),
      assistant_cycle_id: "cycle-local-source-fallback"
    }

    {:effect, {:llm_call, _params}, state} = CommitmentTracker.handle_wakeup(state, context)

    {:emit, {:briefs_recorded, _payload}, _state} =
      CommitmentTracker.handle_effect_result({:llm_call, %{content: "not json"}}, state, context)

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)

    assert brief.body =~ "Review the launch voice note"
    assert brief.body =~ "From Voice Memos."
    refute brief.body =~ "voice_memos"
    refute brief.body =~ "Source:"
  end
end
