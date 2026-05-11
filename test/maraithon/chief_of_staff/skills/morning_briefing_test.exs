defmodule Maraithon.ChiefOfStaff.Skills.MorningBriefingTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.Skills.MorningBriefing
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.Commitments
  alias Maraithon.Companion
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Crm
  alias Maraithon.LocalBrowserHistory
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalFiles
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
  alias Maraithon.LocalReminders
  alias Maraithon.LocalVoiceMemos
  alias Maraithon.Memory
  alias Maraithon.Todos

  setup do
    user_id = "morning-briefing-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{}
      })

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "444123"})

    %{user_id: user_id, agent: agent}
  end

  test "builds a source-backed input and records an LLM synthesized brief", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-07 14:00:00Z]

    {:ok, _commitment} =
      Commitments.upsert(user_id, %{
        "source" => "omnifocus",
        "source_id" => "of-runner-1",
        "title" => "Send Sarah the deck",
        "owed_to" => "Sarah",
        "project" => "Runner",
        "due_at" => "2026-05-07T20:00:00Z"
      })

    source_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_calendar(%{
        "events" => [
          %{
            "event_id" => "evt-1",
            "summary" => "Runner GTM",
            "start" => ~U[2026-05-07 16:00:00Z],
            "end" => ~U[2026-05-07 16:30:00Z],
            "attendees" => [%{"email" => "sarah@example.com"}]
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_gmail(%{
        "messages" => [
          %{
            "message_id" => "msg-1",
            "thread_id" => "thread-1",
            "labels" => ["INBOX", "UNREAD"],
            "from" => "Instagram <security@mail.instagram.com>",
            "subject" => "New login to Instagram",
            "snippet" => "We noticed a new login.",
            "text_body" => "Instagram reported a new login from an unknown device.",
            "body_available" => true,
            "body_status" => "available",
            "internal_date" => now
          }
        ],
        "inbox_messages" => [
          %{
            "message_id" => "msg-1",
            "thread_id" => "thread-1",
            "labels" => ["INBOX", "UNREAD"],
            "from" => "Instagram <security@mail.instagram.com>",
            "subject" => "New login to Instagram",
            "snippet" => "We noticed a new login.",
            "text_body" => "Instagram reported a new login from an unknown device.",
            "body_available" => true,
            "body_status" => "available",
            "internal_date" => now
          },
          %{
            "message_id" => "msg-2",
            "thread_id" => "thread-2",
            "labels" => ["INBOX", "UNREAD"],
            "from" => "SKIMS <no-reply@emails.skims.com>",
            "subject" => "Dive Into SKIMS Swim",
            "snippet" => "Limited time offer.",
            "text_body" => "Promotional retail offer for swimwear.",
            "body_available" => true,
            "body_status" => "available",
            "internal_date" => now
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_slack(%{
        "workspaces" => [
          %{
            "team_id" => "T123",
            "team_name" => "Agora",
            "key_channels" => [
              %{
                "id" => "C123",
                "name" => "runner-general",
                "messages" => [
                  %{"ts" => "1778162400.0", "text" => "Can Kent review the launch note?"}
                ]
              }
            ]
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_news(%{
        "items" => [
          %{
            "source" => "Techmeme",
            "title" => "OpenAI ships briefing-relevant updates",
            "summary" => "A concise product update worth scanning.",
            "url" => "https://example.com/news",
            "published_at" => DateTime.to_iso8601(now)
          }
        ],
        "feeds" => [%{"name" => "Techmeme", "url" => "https://example.com/feed.xml"}],
        "status" => "ready",
        "fetched_at" => now
      })

    {:ok, _person} =
      Crm.upsert_person(user_id, %{
        "first_name" => "Charlie",
        "last_name" => "Jones",
        "slack_id" => "UCHARLIE",
        "preferred_communication_method" => "slack",
        "relationship" => "Runner teammate",
        "communication_frequency" => "weekly"
      })

    {:ok, _memory} =
      Memory.write(user_id, %{
        "title" => "Generic retail promotions are briefing noise",
        "content" =>
          "Retail promotions should not appear in the morning briefing unless they create a real obligation.",
        "kind" => "relevance_feedback",
        "polarity" => "negative",
        "importance" => 82
      })

    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "morning_brief_hour_local" => 8
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: source_bundle,
      assistant_cycle_id: "cycle-1"
    }

    {:effect, {:llm_call, params}, state} = MorningBriefing.handle_wakeup(state, context)

    assert params["max_tokens"] == 8_000
    assert params["reasoning_effort"] == "high"

    prompt = get_in(params, ["messages", Access.at(0), "content"])
    assert prompt =~ "Brief input JSON"
    assert prompt =~ "Skill instructions"
    assert prompt =~ "Email review rule"
    assert prompt =~ "Treat meeting prep as CRM-first"
    assert prompt =~ "Required external meetings are a hard coverage contract"
    assert prompt =~ "\"schedule_coverage\""
    assert prompt =~ "\"required_meetings\""
    assert prompt =~ "body_available"
    assert prompt =~ "meeting_prep"
    assert prompt =~ "Instagram reported a new login"
    assert prompt =~ "Promotional retail offer"
    assert prompt =~ ~s({"title":"...","summary":"...","body":"...","todos":[)
    assert prompt =~ "Write like a sharp Chief of Staff"
    assert prompt =~ "This is not a digest"
    assert prompt =~ "## Needs Your Attention"
    assert prompt =~ "## Decisions / Follow-ups"
    assert prompt =~ "never include internal scores, thresholds"
    assert prompt =~ "Today's move:"
    assert prompt =~ "Instagram"
    assert prompt =~ "SKIMS"
    assert prompt =~ "runner-general"
    assert prompt =~ "OpenAI ships briefing-relevant updates"
    assert prompt =~ "Include news only when it affects Runner"
    assert prompt =~ "relationships"
    assert prompt =~ "Charlie Jones"
    assert prompt =~ "Runner teammate"
    assert prompt =~ "deep_memory"
    assert prompt =~ "Generic retail promotions are briefing noise"

    response = %{
      content:
        Jason.encode!(%{
          "title" => "Thursday, May 7 — Check the security alert",
          "summary" => "One account-security item and one Runner commitment need attention.",
          "body" =>
            "## Needs Your Attention\n- 🔴 Check the Instagram login.\n\nProtect the morning block."
        })
    }

    {:emit, {:briefs_recorded, payload}, _state} =
      MorningBriefing.handle_effect_result({:llm_call, response}, state, context)

    assert payload.source_backed == true

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title =~ "Check the security alert"
    assert brief.metadata["source_backed"] == true
    assert brief.metadata["generation_mode"] == "llm"
    assert get_in(brief.metadata, ["brief_input", "counts", "gmail_recent_unread"]) == 2
    assert get_in(brief.metadata, ["brief_input", "counts", "slack_key_threads"]) == 1
    assert get_in(brief.metadata, ["brief_input", "counts", "news_items"]) == 1
    assert get_in(brief.metadata, ["brief_input", "counts", "relationships"]) == 1
    assert get_in(brief.metadata, ["brief_input", "counts", "deep_memory"]) == 1
    assert get_in(brief.metadata, ["brief_input", "counts", "meeting_prep_meetings"]) == 1

    assert get_in(brief.metadata, [
             "brief_input",
             "counts",
             "meeting_prep_required_schedule_meetings"
           ]) == 1

    assert get_in(brief.metadata, ["brief_input", "counts", "schedule_coverage_required_meetings"]) ==
             1
  end

  test "persists model-emitted morning todos through todo intelligence", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-07 14:00:00Z]

    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "morning_brief_hour_local" => 8
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now}),
      assistant_cycle_id: "cycle-todos"
    }

    {:effect, {:llm_call, _params}, state} = MorningBriefing.handle_wakeup(state, context)

    response = %{
      content:
        Jason.encode!(%{
          "title" => "Thursday, May 7 - Review the launch note",
          "summary" => "One Slack follow-up belongs on the todo list.",
          "body" => "## Needs Your Attention\n- Review the Runner launch note.",
          "todos" => [
            %{
              "source" => "slack",
              "title" => "Review Runner launch note",
              "summary" => "The GTM channel needs Kent to review the Runner launch note.",
              "next_action" => "Open the launch note and leave approval or edits.",
              "notes" => "Mentioned in #runner-gtm.",
              "action_plan" => "Scan claims, check launch timing, then approve or comment.",
              "dedupe_key" => "morning:slack:runner-launch-note",
              "metadata" => %{"channel_name" => "runner-gtm"}
            }
          ]
        })
    }

    {:emit, {:briefs_recorded, payload}, _state} =
      MorningBriefing.handle_effect_result({:llm_call, response}, state, context)

    assert payload.todo_count == 1
    assert payload.todo_skipped_count == 0

    [todo] = Todos.list_for_user(user_id, source: "slack", limit: 5)
    assert todo.title == "Review Runner launch note"
    assert todo.action_plan =~ "Scan claims"
    assert todo.metadata["origin_skill_id"] == "morning_briefing"

    assert get_in(todo.metadata, ["todo_intelligence", "source"]) ==
             "chief_of_staff_morning_briefing"
  end

  test "invalid model output records an explicit generation error instead of a heuristic fallback",
       %{
         user_id: user_id,
         agent: agent
       } do
    now = ~U[2026-05-07 14:00:00Z]

    {:ok, _commitment} =
      Commitments.upsert(user_id, %{
        "source" => "omnifocus",
        "source_id" => "of-overdue-1",
        "title" => "Notify Justin Dean about the Gmail send-bug fix",
        "owed_to" => "Justin Dean",
        "project" => "Runner",
        "due_at" => "2026-05-05T20:00:00Z",
        "metadata" => %{"next_action" => "Send the email today."}
      })

    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "morning_brief_hour_local" => 8
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now}),
      assistant_cycle_id: "cycle-error"
    }

    {:effect, {:llm_call, _params}, state} = MorningBriefing.handle_wakeup(state, context)

    {:emit, {:brief_generation_failed, payload}, _state} =
      MorningBriefing.handle_effect_result({:llm_call, %{content: "not json"}}, state, context)

    assert payload.generation_mode == "error"
    assert payload.error_message =~ "model_response_invalid"

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)

    assert brief.title == "Morning briefing generation failed"
    assert brief.status == "pending"
    assert brief.error_message =~ "model_response_invalid"
    assert brief.metadata["generation_mode"] == "error"
    assert brief.metadata["error_message"] =~ "model_response_invalid"
    assert brief.body =~ "No heuristic or keyword-based fallback was used."
    refute brief.body =~ "## Inbox"
    refute brief.body =~ "## Slack"
    refute brief.body =~ "## News"
    refute brief.body =~ "Notify Justin Dean"
  end

  test "model provider errors record an explicit generation error", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-07 14:00:00Z]

    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "morning_brief_hour_local" => 8
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now}),
      assistant_cycle_id: "cycle-provider-error"
    }

    {:effect, {:llm_call, _params}, state} = MorningBriefing.handle_wakeup(state, context)

    {:emit, {:brief_generation_failed, payload}, _state} =
      MorningBriefing.handle_effect_error(
        :llm_call,
        {:incomplete_response, %{"reason" => "max_output_tokens"}},
        state,
        context
      )

    assert payload.generation_mode == "error"
    assert payload.error_message =~ "max_output_tokens"

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title == "Morning briefing generation failed"
    assert brief.error_message =~ "max_output_tokens"
    assert brief.metadata["llm_finish_reason"] == "error"
    assert brief.body =~ "No heuristic or keyword-based fallback was used."
  end

  test "lets skill config override the LLM budget and intelligence", %{user_id: user_id} do
    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "morning_brief_hour_local" => 8,
        "llm_model" => "gpt-5.4",
        "llm_max_tokens" => 4096,
        "llm_reasoning_effort" => "xhigh"
      })

    context = %{
      agent_id: "agent-llm-config",
      user_id: user_id,
      timestamp: ~U[2026-05-07 14:00:00Z],
      source_bundle:
        SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: ~U[2026-05-07 14:00:00Z]})
    }

    {:effect, {:llm_call, params}, _state} = MorningBriefing.handle_wakeup(state, context)

    assert params["model"] == "gpt-5.4"
    assert params["max_tokens"] == 4096
    assert params["reasoning_effort"] == "xhigh"
  end

  test "caps oversized morning briefing output budgets", %{user_id: user_id} do
    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "morning_brief_hour_local" => 8,
        "llm_max_tokens" => 64_000
      })

    context = %{
      agent_id: "agent-llm-max-token-cap",
      user_id: user_id,
      timestamp: ~U[2026-05-07 14:00:00Z],
      source_bundle:
        SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: ~U[2026-05-07 14:00:00Z]})
    }

    {:effect, {:llm_call, params}, _state} = MorningBriefing.handle_wakeup(state, context)

    assert params["max_tokens"] == 8_000
  end

  test "keeps morning briefing on the high-reasoning path", %{user_id: user_id} do
    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "morning_brief_hour_local" => 8,
        "llm_reasoning_effort" => "medium"
      })

    context = %{
      agent_id: "agent-llm-minimum-reasoning",
      user_id: user_id,
      timestamp: ~U[2026-05-07 14:00:00Z],
      source_bundle:
        SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: ~U[2026-05-07 14:00:00Z]})
    }

    {:effect, {:llm_call, params}, _state} = MorningBriefing.handle_wakeup(state, context)

    assert params["reasoning_effort"] == "high"
  end

  test "does not generate a morning brief when Telegram is not connected", %{agent: agent} do
    user_id = "morning-briefing-no-telegram-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "morning_brief_hour_local" => 8
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: ~U[2026-05-07 14:00:00Z],
      trigger: %{type: :wakeup},
      source_bundle:
        SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: ~U[2026-05-07 14:00:00Z]})
    }

    assert {:idle, _state} = MorningBriefing.handle_wakeup(state, context)
    assert [] = Briefs.list_recent_for_user(user_id, limit: 1)
  end

  describe "local source ingestion" do
    setup %{user_id: user_id} = ctx do
      device_id = Ecto.UUID.generate()

      now = ~U[2026-05-07 14:00:00Z]

      state =
        MorningBriefing.init(%{
          "user_id" => user_id,
          "timezone_offset_hours" => -4,
          "morning_brief_hour_local" => 8
        })

      Map.merge(ctx, %{device_id: device_id, now: now, state: state})
    end

    test "includes iMessage chats and counts in build_brief_input", %{
      user_id: user_id,
      device_id: device_id,
      now: now,
      state: state
    } do
      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          %{
            "guid" => "msg-imsg-1",
            "local_id" => "p:1",
            "service" => "iMessage",
            "is_from_me" => false,
            "sender_handle" => "+14165550199",
            "chat_handles" => ["+14165550199"],
            "chat_display_name" => "Charlie Jones",
            "chat_style" => "im",
            "text" => "Can you confirm pricing today?",
            "sent_at" => DateTime.to_iso8601(DateTime.add(now, -3_600, :second))
          }
        ])

      input = MorningBriefing.build_brief_input(user_id, now, state, %{})

      assert %{"chats" => [chat | _], "counts" => %{"chats" => 1}} = input["imessage"]
      assert chat["chat_display_name"] == "Charlie Jones"
      assert chat["latest_snippet"] =~ "Can you confirm pricing"
      assert chat["latest_is_from_me"] == false
      refute is_nil(chat["latest_sent_at"])
    end

    test "includes local notes with snippet, folder, and pinned flag", %{
      user_id: user_id,
      device_id: device_id,
      now: now,
      state: state
    } do
      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          %{
            "guid" => "note-1",
            "local_id" => "n:1",
            "title" => "Runner Q3 plan",
            "snippet" => "Heartbeat GA + ambassador push",
            "folder" => "Work",
            "is_pinned" => true,
            "modified_at" => DateTime.to_iso8601(DateTime.add(now, -3_600, :second))
          }
        ])

      input = MorningBriefing.build_brief_input(user_id, now, state, %{})

      assert %{"items" => [note], "counts" => %{"count" => 1}} = input["notes"]
      assert note["title"] == "Runner Q3 plan"
      assert note["snippet"] =~ "Heartbeat GA"
      assert note["folder"] == "Work"
      assert note["is_pinned"] == true
    end

    test "includes recent voice memos with duration and transcript flag", %{
      user_id: user_id,
      device_id: device_id,
      now: now,
      state: state
    } do
      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          %{
            "guid" => "memo-1",
            "local_id" => "v:1",
            "title" => "Standup recap",
            "snippet" => "Walks through Runner priorities for the week",
            "duration_seconds" => 92,
            "created_at" => DateTime.to_iso8601(DateTime.add(now, -2 * 3_600, :second)),
            "transcript" => "We need to ship heartbeat GA.",
            "transcript_engine" => "whisper",
            "transcript_lang" => "en"
          }
        ])

      input = MorningBriefing.build_brief_input(user_id, now, state, %{})

      assert %{"items" => [memo], "counts" => %{"count" => 1}} = input["voice_memos"]
      assert memo["title"] == "Standup recap"
      assert memo["duration_seconds"] == 92
      assert memo["has_transcript"] == true
    end

    test "prefers local calendar over Google source bundle when local events exist", %{
      user_id: user_id,
      device_id: device_id,
      now: now,
      state: state
    } do
      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          %{
            "guid" => "evt-local-1",
            "local_id" => "evt:1",
            "calendar_name" => "Personal",
            "calendar_color" => "#ffaa00",
            "title" => "Runner GTM sync",
            "notes" => "Pricing and rollout cadence",
            "location" => "Zoom",
            "start_at" => DateTime.to_iso8601(DateTime.add(now, 2 * 3_600, :second)),
            "end_at" => DateTime.to_iso8601(DateTime.add(now, 3 * 3_600, :second)),
            "is_all_day" => false,
            "is_recurring" => false,
            "organizer_email" => "charlie@example.com",
            "attendees_count" => 2,
            "attendee_emails" => ["kent@example.com", "charlie@example.com"]
          }
        ])

      source_bundle =
        %{trigger: %{type: :wakeup}, timestamp: now}
        |> SourceBundle.empty(%{})
        |> SourceBundle.put_calendar(%{
          "events" => [
            %{
              "event_id" => "google-evt-1",
              "summary" => "Should be ignored when local is present",
              "start" => DateTime.add(now, 2 * 3_600, :second),
              "end" => DateTime.add(now, 3 * 3_600, :second)
            }
          ],
          "status" => "ready",
          "fetched_at" => now
        })

      input =
        MorningBriefing.build_brief_input(user_id, now, state, %{source_bundle: source_bundle})

      assert input["calendar"]["preferred_source"] == "local"
      assert [%{"summary" => "Runner GTM sync"} | _] = input["calendar"]["upcoming_local"]

      assert Enum.any?(input["calendar"]["today_events"], fn event ->
               event["summary"] == "Runner GTM sync"
             end)

      refute Enum.any?(input["calendar"]["today_events"] || [], fn event ->
               event["summary"] == "Should be ignored when local is present"
             end)
    end

    test "falls back to Google calendar when no local events", %{
      user_id: user_id,
      now: now,
      state: state
    } do
      source_bundle =
        %{trigger: %{type: :wakeup}, timestamp: now}
        |> SourceBundle.empty(%{})
        |> SourceBundle.put_calendar(%{
          "events" => [
            %{
              "event_id" => "google-evt-2",
              "summary" => "Runner standup (Google)",
              "start" => DateTime.add(now, 2 * 3_600, :second),
              "end" => DateTime.add(now, 3 * 3_600, :second)
            }
          ],
          "status" => "ready",
          "fetched_at" => now
        })

      input =
        MorningBriefing.build_brief_input(user_id, now, state, %{source_bundle: source_bundle})

      assert input["calendar"]["preferred_source"] == "google"

      assert Enum.any?(input["calendar"]["today_events"], fn event ->
               event["summary"] == "Runner standup (Google)"
             end)
    end

    test "reports due-soon reminders with priority and due timestamps", %{
      user_id: user_id,
      device_id: device_id,
      now: now,
      state: state
    } do
      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          %{
            "guid" => "r-due-1",
            "local_id" => "r:1",
            "list_name" => "Work",
            "title" => "Ship heartbeat docs",
            "notes" => nil,
            "priority" => 1,
            "due_at" => DateTime.to_iso8601(DateTime.add(now, 6 * 3_600, :second)),
            "is_completed" => false,
            "has_alarm" => true
          },
          %{
            "guid" => "r-done-1",
            "local_id" => "r:2",
            "list_name" => "Work",
            "title" => "Already done",
            "is_completed" => true,
            "completed_at" => DateTime.to_iso8601(DateTime.add(now, -3_600, :second)),
            "due_at" => DateTime.to_iso8601(DateTime.add(now, -3_600, :second))
          }
        ])

      input = MorningBriefing.build_brief_input(user_id, now, state, %{})

      assert %{"due_soon" => [reminder | _], "counts" => counts} = input["reminders"]
      assert reminder["title"] == "Ship heartbeat docs"
      assert reminder["priority"] == 1
      assert reminder["list_name"] == "Work"
      assert counts["open"] == 1
      assert counts["due_today"] == 1
    end

    test "lists recent files but only with allowlist extensions", %{
      user_id: user_id,
      device_id: device_id,
      now: now,
      state: state
    } do
      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          %{
            "guid" => "file-allow",
            "local_id" => "~/Documents/Runner/spec.md",
            "path" => "~/Documents/Runner/spec.md",
            "filename" => "spec.md",
            "extension" => "md",
            "mime_type" => "text/markdown",
            "byte_size" => 1024,
            "modified_at" => DateTime.to_iso8601(DateTime.add(now, -3_600, :second))
          },
          %{
            "guid" => "file-deny",
            "local_id" => "~/Downloads/image.png",
            "path" => "~/Downloads/image.png",
            "filename" => "image.png",
            "extension" => "png",
            "mime_type" => "image/png",
            "byte_size" => 32_000,
            "modified_at" => DateTime.to_iso8601(DateTime.add(now, -3_600, :second))
          }
        ])

      input = MorningBriefing.build_brief_input(user_id, now, state, %{})

      assert %{"items" => files, "counts" => %{"recent_count" => 1}} = input["files"]
      assert [%{"extension" => "md"}] = files
    end

    test "groups top hosts from recent browser history", %{
      user_id: user_id,
      device_id: device_id,
      now: now,
      state: state
    } do
      visits =
        for i <- 1..4 do
          %{
            "guid" => "visit-#{i}",
            "local_id" => "v:#{i}",
            "browser" => "chrome",
            "url" => "https://news.example.com/article-#{i}",
            "title" => "Article #{i}",
            "host" => "news.example.com",
            "visit_count" => 1,
            "last_visited_at" => DateTime.to_iso8601(DateTime.add(now, -(i * 600), :second))
          }
        end

      other =
        %{
          "guid" => "visit-blog",
          "local_id" => "v:blog",
          "browser" => "chrome",
          "url" => "https://blog.example.org/x",
          "title" => "Blog",
          "host" => "blog.example.org",
          "last_visited_at" => DateTime.to_iso8601(DateTime.add(now, -120, :second))
        }

      {:ok, _} = LocalBrowserHistory.ingest_batch(user_id, device_id, [other | visits])

      input = MorningBriefing.build_brief_input(user_id, now, state, %{})

      assert %{"top_hosts" => [%{"host" => "news.example.com", "visits" => 4} | _]} =
               input["browser_history"]

      assert input["browser_history"]["counts"]["visits_last_24h"] == 5
    end

    test "marks unsynced local sources as error when no device has checked in", %{
      user_id: user_id,
      now: now,
      state: state
    } do
      input = MorningBriefing.build_brief_input(user_id, now, state, %{})

      health = input["source_health"]
      assert health["imessage"]["status"] == "error"
      assert health["notes"]["status"] == "error"
      assert health["voice_memos"]["status"] == "error"
      assert health["calendar_local"]["status"] == "error"
      assert health["reminders"]["status"] == "error"
      assert health["files"]["status"] == "error"
      assert health["browser_history"]["status"] == "error"
    end

    test "marks unsynced sources as stale when device last checked in over 2h ago", %{
      user_id: user_id,
      now: now,
      state: state
    } do
      {:ok, %{device: device}} =
        Companion.Devices.register(user_id, Ecto.UUID.generate(), device_name: "MacBook Pro")

      stale_at = DateTime.add(now, -3 * 3_600, :second)

      Maraithon.Repo.update_all(
        Ecto.Query.from(d in Companion.Device, where: d.id == ^device.id),
        set: [last_seen_at: stale_at]
      )

      input = MorningBriefing.build_brief_input(user_id, now, state, %{})

      assert input["source_health"]["imessage"]["status"] == "stale"
      assert input["source_health"]["notes"]["status"] == "stale"
    end

    test "marks local sources as connected when data is present even if device is stale", %{
      user_id: user_id,
      device_id: device_id,
      now: now,
      state: state
    } do
      {:ok, %{device: device}} =
        Companion.Devices.register(user_id, Ecto.UUID.generate(), device_name: "Stale Mac")

      stale_at = DateTime.add(now, -4 * 3_600, :second)

      Maraithon.Repo.update_all(
        Ecto.Query.from(d in Companion.Device, where: d.id == ^device.id),
        set: [last_seen_at: stale_at]
      )

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          %{
            "guid" => "note-stale",
            "local_id" => "n:1",
            "title" => "Synced before stale",
            "snippet" => "Still useful data",
            "modified_at" => DateTime.to_iso8601(DateTime.add(now, -3_600, :second))
          }
        ])

      input = MorningBriefing.build_brief_input(user_id, now, state, %{})

      assert input["source_health"]["notes"]["status"] == "connected"
      # iMessage has no rows for this user, device is stale -> stale.
      assert input["source_health"]["imessage"]["status"] == "stale"
    end

    test "compact metadata counts all local sources", %{
      user_id: user_id,
      device_id: device_id,
      now: now,
      agent: agent
    } do
      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          %{
            "guid" => "n-meta-1",
            "title" => "Note for metadata",
            "snippet" => "Body",
            "modified_at" => DateTime.to_iso8601(now)
          }
        ])

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          %{
            "guid" => "r-meta-1",
            "title" => "Reminder for metadata",
            "due_at" => DateTime.to_iso8601(DateTime.add(now, 60 * 60, :second)),
            "is_completed" => false
          }
        ])

      state =
        MorningBriefing.init(%{
          "user_id" => user_id,
          "timezone_offset_hours" => -4,
          "morning_brief_hour_local" => 8
        })

      context = %{
        agent_id: agent.id,
        user_id: user_id,
        timestamp: now,
        trigger: %{type: :wakeup},
        source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now}),
        assistant_cycle_id: "cycle-meta"
      }

      {:effect, {:llm_call, _params}, state} = MorningBriefing.handle_wakeup(state, context)

      response = %{
        content:
          Jason.encode!(%{
            "title" => "Day with local sources",
            "summary" => "Notes and reminders considered.",
            "body" => "## Needs Your Attention\n- placeholder"
          })
      }

      {:emit, {:briefs_recorded, _}, _state} =
        MorningBriefing.handle_effect_result({:llm_call, response}, state, context)

      [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
      counts = brief.metadata["brief_input"]["counts"]
      assert counts["notes"] == 1
      assert counts["reminders_due_soon"] == 1
    end

    test "prompt now contains the local-source citation rule", %{
      user_id: user_id,
      now: now,
      agent: agent
    } do
      state =
        MorningBriefing.init(%{
          "user_id" => user_id,
          "timezone_offset_hours" => -4,
          "morning_brief_hour_local" => 8
        })

      context = %{
        agent_id: agent.id,
        user_id: user_id,
        timestamp: now,
        trigger: %{type: :wakeup},
        source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now}),
        assistant_cycle_id: "cycle-prompt"
      }

      {:effect, {:llm_call, params}, _} = MorningBriefing.handle_wakeup(state, context)
      prompt = get_in(params, ["messages", Access.at(0), "content"])

      assert prompt =~
               "Prefer first-party local sources over scraped equivalents"
    end

    test "SourceBundle.put_imessage stores chats, messages, counts and freshness", %{now: now} do
      bundle =
        %{trigger: %{type: :wakeup}, timestamp: now}
        |> SourceBundle.empty(%{})
        |> SourceBundle.put_imessage(%{
          "chats" => [%{"chat_key" => "+15555550100", "chat_display_name" => "Sarah"}],
          "messages" => [%{"guid" => "g1", "text" => "hi"}],
          "status" => "ready",
          "fetched_at" => now
        })

      assert [%{"chat_key" => "+15555550100"}] = SourceBundle.imessage_chats(bundle)
      assert [%{"guid" => "g1"}] = SourceBundle.imessage_messages(bundle)
      assert get_in(SourceBundle.freshness(bundle), ["imessage", "status"]) == "ready"
    end

    test "SourceBundle.put_notes / put_voice_memos / put_reminders / put_files / put_browser_history populate the bundle",
         %{now: now} do
      bundle =
        %{trigger: %{type: :wakeup}, timestamp: now}
        |> SourceBundle.empty(%{})
        |> SourceBundle.put_notes(%{
          "notes" => [%{"note_id" => "n1", "title" => "t"}],
          "status" => "ready",
          "fetched_at" => now
        })
        |> SourceBundle.put_voice_memos(%{
          "memos" => [%{"memo_id" => "v1", "title" => "m"}],
          "status" => "ready",
          "fetched_at" => now
        })
        |> SourceBundle.put_reminders(%{
          "reminders" => [%{"reminder_id" => "r1", "title" => "r"}],
          "status" => "ready",
          "fetched_at" => now
        })
        |> SourceBundle.put_files(%{
          "files" => [%{"file_id" => "f1", "filename" => "spec.md"}],
          "status" => "ready",
          "fetched_at" => now
        })
        |> SourceBundle.put_browser_history(%{
          "visits" => [%{"host" => "example.com"}],
          "status" => "ready",
          "fetched_at" => now
        })
        |> SourceBundle.put_calendar_local(%{
          "events" => [%{"summary" => "Local meeting"}],
          "status" => "ready",
          "fetched_at" => now
        })

      assert [%{"note_id" => "n1"}] = SourceBundle.notes(bundle)
      assert [%{"memo_id" => "v1"}] = SourceBundle.voice_memos(bundle)
      assert [%{"reminder_id" => "r1"}] = SourceBundle.reminders(bundle)
      assert [%{"file_id" => "f1"}] = SourceBundle.files(bundle)
      assert [%{"host" => "example.com"}] = SourceBundle.browser_visits(bundle)
      assert [%{"summary" => "Local meeting"}] = SourceBundle.calendar_local_events(bundle)

      freshness = SourceBundle.freshness(bundle)
      assert freshness["notes"]["status"] == "ready"
      assert freshness["voice_memos"]["status"] == "ready"
      assert freshness["reminders"]["status"] == "ready"
      assert freshness["files"]["status"] == "ready"
      assert freshness["browser_history"]["status"] == "ready"
      assert freshness["calendar_local"]["status"] == "ready"
    end

    test "build_brief_input reads SourceBundle local sections when the bundle is populated", %{
      user_id: user_id,
      now: now,
      state: state
    } do
      source_bundle =
        %{trigger: %{type: :wakeup}, timestamp: now}
        |> SourceBundle.empty(%{})
        |> SourceBundle.put_imessage(%{
          "chats" => [
            %{
              "chat_key" => "k1",
              "chat_display_name" => "Bundle Charlie",
              "latest_snippet" => "from bundle"
            }
          ],
          "status" => "ready",
          "fetched_at" => now
        })
        |> SourceBundle.put_notes(%{
          "notes" => [%{"note_id" => "bn", "title" => "Bundle note"}],
          "status" => "ready",
          "fetched_at" => now
        })

      input =
        MorningBriefing.build_brief_input(user_id, now, state, %{source_bundle: source_bundle})

      assert [%{"chat_display_name" => "Bundle Charlie"}] = input["imessage"]["chats"]
      assert [%{"title" => "Bundle note"}] = input["notes"]["items"]
    end
  end
end
