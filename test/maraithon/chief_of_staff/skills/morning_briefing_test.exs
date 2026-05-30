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

  test "fresh tenant commercial briefing defaults do not include org-specific terms" do
    state = MorningBriefing.init(%{})

    refute "glossier" in state.commercial_thread_terms
    assert "enterprise" in state.commercial_thread_terms
    assert "intro" in state.commercial_thread_terms
  end

  test "configured commercial briefing terms merge with generic defaults" do
    state = MorningBriefing.init(%{"commercial_thread_terms" => ["glossier"]})

    assert "glossier" in state.commercial_thread_terms
    assert "enterprise" in state.commercial_thread_terms
    assert "intro" in state.commercial_thread_terms
  end

  test "brief input uses the active daylight offset for a named timezone", %{user_id: user_id} do
    now = ~U[2026-05-15 14:00:00Z]

    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone" => "America/Toronto",
        "timezone_offset_hours" => -5
      })

    input =
      MorningBriefing.build_brief_input(user_id, now, state, %{
        source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now})
      })

    assert input["timezone"] == "ET"
    assert input["timezone_offset_hours"] == -4
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
          },
          %{
            "message_id" => "msg-3",
            "thread_id" => "thread-3",
            "labels" => [],
            "from" => "Charlie Feng <charlie@runner.now>",
            "to" => "Morne <morne@cogniate.ai>, Kent Fenwick <kent@runner.now>",
            "subject" => "Cogniate Enterprise plan discussion",
            "snippet" => "Looping Kent for pricing guidance.",
            "text_body" => "Charlie looped Kent into the Cogniate Enterprise plan discussion.",
            "body_available" => true,
            "body_status" => "available",
            "internal_date" => DateTime.add(now, -3, :day)
          },
          %{
            "message_id" => "msg-4",
            "thread_id" => "thread-4",
            "labels" => [],
            "from" => "Vanta <vantateam@vanta.com>",
            "to" => "Kent Fenwick <kent@runner.now>",
            "subject" => "Vanta enterprise security discount",
            "snippet" => "Enterprise AI security promotion.",
            "text_body" =>
              "A generic enterprise discount marketing email sent to a Runner address.",
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
            "text_body" =>
              <<"Promotional retail offer in: ", 70, 114, 97, 110, 231, 97, 105, 115, ".">>,
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
        "morning_brief_hour_local" => 8,
        "commercial_counterparty_domain_markers" => ["cogniate"],
        "commercial_teammate_domains" => ["runner.now"],
        "slack_key_channels" => ["runner-general"]
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

    assert params["max_tokens"] == 16_000
    assert params["reasoning_effort"] == "high"
    assert params["timeout_ms"] == 1_200_000

    prompt = get_in(params, ["messages", Access.at(0), "content"])
    assert String.valid?(prompt)
    assert prompt =~ "Français"
    assert prompt =~ "Brief input JSON"
    assert prompt =~ "Skill instructions"
    assert prompt =~ "Email review rule"
    assert prompt =~ "Treat meeting prep as CRM-first"
    assert prompt =~ "source pages as the"
    assert prompt =~ "meeting dossier"
    assert prompt =~ "services, pricing, operating model"
    assert prompt =~ "fit hypothesis"
    assert prompt =~ "second briefing"
    assert prompt =~ "Fresh external commercial threads from close teammates"
    assert prompt =~ "Treat gmail.commercial_threads as a coverage list"
    assert prompt =~ "Inbox and Slack triage contract"
    assert prompt =~ "Required external meetings are a hard coverage contract"
    assert prompt =~ "Use display_start and display_end exactly"
    assert prompt =~ "Keep the JSON executive-grade and complete"
    assert prompt =~ "if there are ten material items"
    assert prompt =~ "\"schedule_coverage\""
    assert prompt =~ "\"required_meetings\""
    assert prompt =~ "Commercial coverage contract"
    assert prompt =~ "body_available"
    assert prompt =~ "meeting_prep"
    assert prompt =~ "Instagram reported a new login"
    assert prompt =~ "Promotional retail offer"
    assert prompt =~ ~s({"title":"...","summary":"...","body":"...","todos":[)
    assert prompt =~ "Write like a sharp Chief of Staff"
    assert prompt =~ "This is not a digest"
    assert prompt =~ "Reference briefing eval"
    assert prompt =~ "Open Commitments with active/overdue/due-today"
    assert prompt =~ "draft IDs, action-card IDs, OmniFocus IDs"
    assert prompt =~ "Not a draft job"
    assert prompt =~ "work_type"
    assert prompt =~ "## Needs Your Attention"
    assert prompt =~ "## Decisions / Follow-ups"
    assert prompt =~ "never include internal scores, thresholds"
    assert prompt =~ "Today's move:"
    assert prompt =~ "Instagram"
    assert prompt =~ "SKIMS"
    assert prompt =~ "Cogniate Enterprise plan discussion"
    refute prompt =~ "Vanta enterprise security discount"
    assert prompt =~ "runner-general"
    assert prompt =~ "OpenAI ships briefing-relevant updates"
    assert prompt =~ "Include news only when it affects the operator's company"
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

    brief = Maraithon.Repo.get!(Maraithon.Briefs.Brief, payload.brief_id)
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

  test "accepts markdown-fenced model JSON as the real morning brief", %{
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
      assistant_cycle_id: "cycle-fenced-json"
    }

    {:effect, {:llm_call, _params}, state} = MorningBriefing.handle_wakeup(state, context)

    response = %{
      content: """
      Here is the briefing JSON:

      ```json
      {"title":"Thursday, May 7 - Review the launch note","summary":"One source-backed priority is ready.","body":"## Needs Your Attention\\n- Review the Runner launch note before lower-signal inbox.","todos":[]}
      ```
      """
    }

    {:emit, {:briefs_recorded, payload}, _state} =
      MorningBriefing.handle_effect_result({:llm_call, response}, state, context)

    assert payload.generation_mode == "llm"
    assert payload.error_message == nil

    brief = Maraithon.Repo.get!(Maraithon.Briefs.Brief, payload.brief_id)
    assert brief.title == "Thursday, May 7 - Review the launch note"
    assert brief.body =~ "Runner launch note"
    assert brief.metadata["generation_mode"] == "llm"
    refute brief.body =~ "Only checked data is included"
  end

  test "quality verifier patches packed-day reference briefing gaps" do
    brief = %{
      "title" => "Wednesday, May 27 - Generic morning",
      "summary" => "A few things are happening.",
      "body" =>
        "A short generic brief that misses the operational stack. Leaked handle actc_c154.",
      "todos" => []
    }

    input = %{
      "date" => "2026-05-27",
      "calendar" => %{
        "today_events" => [
          %{
            "summary" => "Runner Weekly Planning",
            "start" => "2026-05-27T15:00:00Z",
            "end" => "2026-05-27T15:45:00Z",
            "display_start" => "11:00",
            "display_end" => "11:45",
            "calendar_name" => "Runner"
          },
          %{
            "summary" => "Sara Franca",
            "start" => "2026-05-27T15:30:00Z",
            "end" => "2026-05-27T16:00:00Z",
            "display_start" => "11:30",
            "display_end" => "12:00",
            "calendar_name" => "Runner"
          },
          %{
            "summary" => "Runner Weekly Planning exec",
            "start" => "2026-05-27T18:45:00Z",
            "end" => "2026-05-27T19:30:00Z",
            "display_start" => "14:45",
            "display_end" => "15:30",
            "calendar_name" => "Runner"
          },
          %{
            "summary" => "1:1 with Dash",
            "start" => "2026-05-27T19:00:00Z",
            "end" => "2026-05-27T20:00:00Z",
            "display_start" => "15:00",
            "display_end" => "16:00",
            "calendar_name" => "Agora"
          }
        ]
      },
      "commitments" => %{
        "active_count" => 61,
        "overdue" => [
          %{
            "title" => "Reply to Renat about Represent launch-video concept",
            "owed_to" => "Renat",
            "project" => "Runner",
            "due_at" => "2026-05-20T16:00:00Z",
            "source_id" => "k2_kp3zotvz",
            "metadata" => %{"action_card_id" => "actc_c198"}
          }
        ],
        "due_today" => [
          %{
            "title" => "Resolve duplicate 11:30 Sara Franca invite",
            "owed_to" => "Sara Franca",
            "project" => "Runner",
            "due_at" => "2026-05-27T15:00:00Z",
            "source_id" => "mTyUJw8V_S1",
            "metadata" => %{"action_card_id" => "actc_c154"}
          }
        ],
        "coming_up" => [
          %{
            "title" => "Pay TensorBoy first invoice",
            "owed_to" => "Manav Gupta",
            "project" => "Runner",
            "due_at" => "2026-05-28T16:00:00Z",
            "source_id" => "jZVZNqySITx",
            "metadata" => %{"action_card_id" => "actc_9deb"}
          }
        ]
      },
      "open_work" => %{
        "todos" => [
          %{
            "title" => "Resolve duplicate Sara Franca invite",
            "summary" => "Lock Google Meet and decline Teams before 11am.",
            "metadata" => %{
              "action_card_id" => "actc_c154",
              "work_type" => "draftable",
              "why_it_matters" => "Avoid joining the wrong 11:30 meeting."
            }
          },
          %{
            "title" => "Pydantic failed payment",
            "summary" => "$124 payment failed again.",
            "metadata" => %{
              "source_item_id" => "a58koyhpMAm",
              "work_type" => "payment",
              "why_it_matters" => "Update the card in Stripe."
            }
          }
        ]
      },
      "slack" => %{
        "key_threads" => [
          %{
            "channel" => "growthcrew-x-runner",
            "summary" => "Brent and Benji want event counts validated.",
            "metadata" => %{"action_card_id" => "actc_c9c8"}
          }
        ]
      }
    }

    {revised, verification} = MorningBriefing.verify_quality(brief, input, "llm")

    assert verification["status"] == "10/10"
    assert verification["score"] == 10
    assert "missing_needs_attention" in verification["initial_findings"]
    assert "missing_schedule_conflicts" in verification["initial_findings"]
    assert "missing_open_commitments" in verification["initial_findings"]
    assert "missing_action_stack" in verification["initial_findings"]
    assert "missing_non_draft_jobs" in verification["initial_findings"]
    assert verification["final_findings"] == []
    assert "schedule_conflicts_called_out_with_recommendations" in verification["criteria"]

    assert "action_card_and_draft_work_is_named_without_internal_handles" in verification[
             "criteria"
           ]

    assert revised["body"] =~ "## Needs Your Attention"
    refute revised["body"] =~ "Brief shape needs attention"
    refute revised["body"] =~ "original model"
    assert revised["body"] =~ "## Schedule Conflicts"
    assert revised["body"] =~ "Sara Franca"
    assert revised["body"] =~ "## Open Commitments"
    assert revised["body"] =~ "Reply to Renat"
    assert revised["body"] =~ "due May 20, 2026 at 4:00 PM UTC"
    refute revised["body"] =~ "k2_kp3zotvz"
    refute revised["body"] =~ "2026-05-20T16:00:00Z"
    assert revised["body"] =~ "## Action Card Stack"
    assert revised["body"] =~ "Resolve duplicate Sara Franca invite"
    assert revised["body"] =~ "Lock Google Meet and decline Teams before 11am."
    refute revised["body"] =~ "actc_"
    assert revised["body"] =~ "## Not a draft job"
    assert revised["body"] =~ "Pydantic failed payment"
  end

  test "quality verifier patches dropped required meetings and commercial threads" do
    brief = %{
      "title" => "Monday, May 11 - Generic morning",
      "summary" => "One generic priority.",
      "body" => "## Needs Your Attention\n- Clear the generic inbox first.",
      "todos" => []
    }

    input = %{
      "date" => "2026-05-11",
      "schedule_coverage" => %{
        "required_meetings" => [
          %{
            "summary" => "Dawn Nguyen",
            "display_start" => "12:00 PM PT",
            "display_end" => "12:30 PM PT",
            "external_attendees" => [
              %{"display_name" => "Dawn Nguyen", "email" => "dawn@gmail.com"}
            ],
            "crm_context" => [
              %{
                "person" => %{
                  "display_name" => "Dawn Nguyen",
                  "relationship" => "Runner enterprise design partner"
                }
              }
            ]
          }
        ]
      },
      "commercial_coverage" => %{
        "required_threads" => [
          %{
            "subject" => "Cogniate Enterprise plan discussion",
            "from" => "Charlie Feng <charlie@runner.now>",
            "to" => "Kent Fenwick <kent@runner.now>",
            "body" =>
              "Charlie looped Kent into Cogniate's Enterprise plan discussion for pricing guidance."
          }
        ]
      }
    }

    {revised, verification} = MorningBriefing.verify_quality(brief, input, "llm")

    assert "missing_required_meetings" in verification["initial_findings"]
    assert "missing_required_commercial_threads" in verification["initial_findings"]
    assert verification["final_findings"] == []
    assert "required_external_meetings_are_covered" in verification["criteria"]
    assert "required_commercial_threads_are_covered" in verification["criteria"]

    assert revised["body"] =~ "## Required Schedule Prep"
    assert revised["body"] =~ "Dawn Nguyen"
    assert revised["body"] =~ "12:00 PM PT"
    assert revised["body"] =~ "Runner enterprise design partner"
    assert revised["body"] =~ "## Decisions / Follow-ups"
    assert revised["body"] =~ "Cogniate Enterprise plan discussion"
    assert revised["body"] =~ "Charlie Feng"
  end

  test "quality verifier patches omitted body-backed inbox and Slack triage" do
    brief = %{
      "title" => "Tuesday, May 12 - Generic morning",
      "summary" => "A generic priority.",
      "body" => "## Needs Your Attention\n- Protect the work block before lower-signal inbox.",
      "todos" => []
    }

    input = %{
      "date" => "2026-05-12",
      "gmail" => %{
        "recent_unread" => [
          %{
            "message_id" => "msg-security",
            "thread_id" => "thread-security",
            "account" => "kent@runner.now",
            "from" => "Instagram <security@mail.instagram.com>",
            "subject" => "Instagram security alert",
            "body_available" => true,
            "body_status" => "available",
            "body" => "Instagram reported a new login from an unknown device."
          }
        ],
        "recent_inbox" => [
          %{
            "message_id" => "msg-security",
            "thread_id" => "thread-security",
            "account" => "kent@runner.now",
            "from" => "Instagram <security@mail.instagram.com>",
            "subject" => "Instagram security alert",
            "body_available" => true,
            "body_status" => "available",
            "body" => "Instagram reported a new login from an unknown device."
          },
          %{
            "message_id" => "msg-retail",
            "thread_id" => "thread-retail",
            "account" => "kent@runner.now",
            "from" => "SKIMS <no-reply@emails.skims.com>",
            "subject" => "Dive into swim sale",
            "body_available" => true,
            "body_status" => "available",
            "body" => "A promotional swim sale with no obligation."
          }
        ],
        "counts" => %{"recent_unread" => 1, "recent_inbox" => 2}
      },
      "slack" => %{
        "key_threads" => [
          %{
            "team_name" => "Runner",
            "channel_name" => "runner-general",
            "user" => "Charlie",
            "ts" => "1778162400.000000",
            "text" => "Launch is blocked by an outage; can Kent name the owner before noon?"
          }
        ],
        "mentions" => [],
        "counts" => %{"recent_messages" => 1, "mentions" => 0}
      }
    }

    {revised, verification} = MorningBriefing.verify_quality(brief, input, "llm")

    assert "missing_inbox_triage" in verification["initial_findings"]
    assert "missing_slack_triage" in verification["initial_findings"]
    assert verification["final_findings"] == []

    assert "scoped_inbox_triage_covers_body_backed_actionable_email" in verification[
             "criteria"
           ]

    assert "scoped_slack_triage_covers_actionable_threads" in verification["criteria"]

    assert revised["body"] =~ "## Inbox Triage"
    assert revised["body"] =~ "Instagram security alert"
    assert revised["body"] =~ "Confirm whether the security notice is expected"
    refute revised["body"] =~ "Dive into swim sale"

    assert revised["body"] =~ "## Slack Triage"
    assert revised["body"] =~ "#runner-general"
    assert revised["body"] =~ "Launch is blocked by an outage"
    assert revised["body"] =~ "Name the owner and the next unblock step"
    refute revised["body"] =~ "debug"
  end

  test "quality verifier drops person-only todo cards without memory-jogging context" do
    weak_todo = %{
      "source" => "gmail",
      "title" => "Alex Muller",
      "summary" => "",
      "next_action" => "Reply.",
      "dedupe_key" => "gmail:alex-muller"
    }

    contextual_todo = %{
      "source" => "gmail",
      "title" => "Follow up with Jordan Lee about Contoso pricing",
      "summary" =>
        "Jordan Lee at Contoso is waiting on the enterprise pricing answer for the renewal.",
      "next_action" =>
        "Reply to Jordan Lee with the renewal price, discount boundary, and concrete ETA.",
      "dedupe_key" => "gmail:jordan-contoso-pricing",
      "metadata" => %{
        "company" => "Contoso",
        "relationship_context" => "enterprise renewal lead",
        "why_it_matters" => "Renewal decision is due today."
      }
    }

    brief = %{
      "title" => "Monday, May 11 - Follow-up review",
      "summary" => "Review relationship follow-ups.",
      "body" => "## Needs Your Attention\n- Clear the relationship follow-ups first.",
      "todos" => [weak_todo, contextual_todo]
    }

    {revised, verification} = MorningBriefing.verify_quality(brief, %{}, "llm")

    assert "sparse_person_todo_context" in verification["initial_findings"]
    assert verification["final_findings"] == []
    assert revised["todos"] == [contextual_todo]
  end

  test "quality verifier uses chief-of-staff copy when adding a generic attention section" do
    brief = %{
      "title" => "Morning briefing",
      "summary" => "Short brief.",
      "body" => "A short generic brief with no attention section.",
      "todos" => []
    }

    {revised, verification} =
      MorningBriefing.verify_quality(brief, %{"date" => "2026-05-07"}, "llm")

    assert "missing_needs_attention" in verification["initial_findings"]
    assert verification["final_findings"] == []
    assert revised["body"] =~ "Start with source-backed priorities"
    refute revised["body"] =~ "Brief shape needs attention"
    refute revised["body"] =~ "original model"
    refute revised["body"] =~ "model output"
  end

  test "quality verifier puts model todo next actions into the primary brief" do
    brief = %{
      "title" => "Monday, May 11 - Schedule prep",
      "summary" => "One external meeting needs prep.",
      "body" => "## Today's Schedule\n- **Prep for Dawn Nguyen** and Charlie Feng.",
      "todos" => [
        %{
          "source" => "calendar",
          "title" => "Prep for Dawn Nguyen",
          "summary" =>
            "Dawn Nguyen at Kiln Studio is evaluating the Runner design partner workflow.",
          "next_action" => "Review Dawn and Kiln Studio context before the meeting.",
          "dedupe_key" => "calendar:dawn-nguyen-prep",
          "metadata" => %{
            "relationship_context" => "Runner design partner evaluator",
            "why_it_matters" => "Meeting prep affects the partner workflow decision."
          }
        }
      ]
    }

    {revised, verification} = MorningBriefing.verify_quality(brief, %{}, "llm")

    assert "missing_model_todo_next_actions" in verification["initial_findings"]
    assert verification["final_findings"] == []

    assert String.starts_with?(
             revised["body"],
             "## Needs Your Attention\n- **Prep for Dawn Nguyen**: Review Dawn and Kiln Studio context before the meeting."
           )

    assert revised["body"] =~ "## Today's Schedule"

    assert "model_todo_next_actions_visible_in_primary_brief" in verification[
             "criteria"
           ]
  end

  test "source-backed fallback opens with ranked executive attention items" do
    brief =
      MorningBriefing.build_compact_fallback_brief(%{
        "date" => "2026-05-27",
        "calendar" => %{
          "today_events" => [
            %{
              "summary" => "School pickup",
              "start" => "2026-05-27T15:00:00Z",
              "end" => "2026-05-27T15:30:00Z",
              "display_start" => "11:00 AM",
              "display_end" => "11:30 AM",
              "calendar_name" => "Family"
            },
            %{
              "summary" => "Runner Weekly Planning",
              "start" => "2026-05-27T15:00:00Z",
              "end" => "2026-05-27T15:45:00Z",
              "display_start" => "11:00 AM",
              "display_end" => "11:45 AM",
              "calendar_name" => "Runner"
            },
            %{
              "summary" => "Sara Franca",
              "start" => "2026-05-27T15:30:00Z",
              "end" => "2026-05-27T16:00:00Z",
              "display_start" => "11:30 AM",
              "display_end" => "12:00 PM",
              "calendar_name" => "Runner"
            }
          ]
        },
        "commitments" => %{
          "active_count" => 2,
          "overdue" => [
            %{
              "title" => "Reply to Renat about Represent launch-video concept",
              "owed_to" => "Renat",
              "project" => "Runner",
              "due_at" => "2026-05-20T16:00:00Z",
              "source_id" => "k2_kp3zotvz"
            }
          ],
          "due_today" => []
        },
        "open_work" => %{
          "todos" => [
            %{
              "title" => "Resolve duplicate Sara Franca invite",
              "summary" => "Lock Google Meet and decline Teams before the 11:30 call.",
              "next_action" => "Choose the canonical invite and decline the duplicate.",
              "priority" => 95,
              "metadata" => %{
                "action_card_id" => "actc_c154",
                "work_type" => "decision"
              }
            }
          ]
        },
        "commercial_coverage" => %{
          "required_threads" => [
            %{
              "subject" => "Cogniate Enterprise plan discussion",
              "from" => "Charlie Feng <charlie@runner.now>",
              "body" =>
                "Charlie looped Kent into Cogniate's Enterprise plan discussion for pricing guidance."
            }
          ]
        }
      })

    [attention_section | _rest] = String.split(brief["body"], "\n\n")
    attention_lines = attention_section |> String.split("\n") |> tl()

    assert String.starts_with?(brief["body"], "## Needs Your Attention")
    assert length(attention_lines) in 4..6
    assert attention_section =~ "School pickup"
    assert attention_section =~ "Schedule conflict"
    assert attention_section =~ "Reply to Renat"
    assert attention_section =~ "Resolve duplicate Sara Franca invite"
    assert attention_section =~ "Choose the canonical invite and decline the duplicate."
    refute attention_section =~ "actc_"
    assert attention_section =~ "Cogniate Enterprise plan discussion"
    assert brief["body"] =~ "## Personal / Family First"
    assert brief["body"] =~ "due May 20, 2026 at 4:00 PM UTC"
    refute brief["body"] =~ "k2_kp3zotvz"
    refute brief["body"] =~ "2026-05-20T16:00:00Z"
    assert brief["body"] =~ "## Unknowns"
    assert brief["body"] =~ "Today's move:"
  end

  test "invalid model output records a compact source-backed fallback briefing",
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

    {:emit, {:briefs_recorded, payload}, _state} =
      MorningBriefing.handle_effect_result({:llm_call, %{content: "not json"}}, state, context)

    assert payload.generation_mode == "source_fallback"
    assert payload.error_message =~ "model_response_invalid"

    brief = Maraithon.Repo.get!(Maraithon.Briefs.Brief, payload.brief_id)

    assert brief.title == "Morning briefing - 2026-05-07"
    assert brief.status == "pending"
    assert brief.error_message =~ "model_response_invalid"
    assert brief.metadata["generation_mode"] == "source_fallback"
    assert brief.metadata["error_message"] =~ "model_response_invalid"
    assert brief.summary =~ "Start with"
    assert brief.body =~ "## Unknowns"
    assert brief.body =~ "Only checked data is included"
    assert brief.body =~ "Today's move:"
    refute brief.body =~ "full narrative briefing"
    refute brief.body =~ "model_response_invalid"
    refute brief.body =~ "model synthesis"
    refute brief.body =~ "finish_reason"
  end

  test "model provider errors record a compact source-backed fallback briefing", %{
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

    {:emit, {:briefs_recorded, payload}, _state} =
      MorningBriefing.handle_effect_error(
        :llm_call,
        {:incomplete_response, %{"reason" => "max_output_tokens"}},
        state,
        context
      )

    assert payload.generation_mode == "source_fallback"
    assert payload.error_message =~ "max_output_tokens"

    brief = Maraithon.Repo.get!(Maraithon.Briefs.Brief, payload.brief_id)
    assert brief.title == "Morning briefing - 2026-05-07"
    assert brief.error_message =~ "max_output_tokens"
    assert brief.metadata["llm_finish_reason"] == "error"
    assert brief.metadata["max_tokens_used"] == 16_000
    assert brief.metadata["reasoning_effort_used"] == "high"
    assert brief.metadata["llm_request"]["max_tokens"] == 16_000
    assert brief.metadata["llm_request"]["reasoning_effort"] == "high"
    assert brief.metadata["generation_mode"] == "source_fallback"
    assert brief.body =~ "## Unknowns"
    assert brief.body =~ "Only checked data is included"
    assert brief.body =~ "Today's move:"
    refute brief.body =~ "full narrative briefing"
    refute brief.body =~ "max_output_tokens"
    refute brief.body =~ "model synthesis"
    refute brief.body =~ "finish_reason"
  end

  test "lets skill config override the LLM budget while capping risky intelligence", %{
    user_id: user_id
  } do
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
    assert params["reasoning_effort"] == "high"
  end

  test "caps oversized morning briefing output budgets", %{user_id: user_id} do
    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "morning_brief_hour_local" => 8,
        "llm_max_tokens" => 128_000
      })

    context = %{
      agent_id: "agent-llm-max-token-cap",
      user_id: user_id,
      timestamp: ~U[2026-05-07 14:00:00Z],
      source_bundle:
        SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: ~U[2026-05-07 14:00:00Z]})
    }

    {:effect, {:llm_call, params}, _state} = MorningBriefing.handle_wakeup(state, context)

    assert params["max_tokens"] == 16_000
  end

  test "bounds oversized connector payloads before building the LLM prompt", %{user_id: user_id} do
    now = ~U[2026-05-07 14:00:00Z]
    huge_body = String.duplicate("Important commercial detail. ", 12_000)

    inbox_messages =
      Enum.map(1..100, fn index ->
        %{
          "message_id" => "big-msg-#{index}",
          "thread_id" => "big-thread-#{index}",
          "labels" => ["INBOX", "UNREAD"],
          "from" => "Customer #{index} <customer#{index}@example.com>",
          "subject" => "Large source payload #{index}",
          "snippet" => huge_body,
          "text_body" => huge_body,
          "body_available" => true,
          "body_status" => "available",
          "internal_date" => DateTime.add(now, -index, :minute)
        }
      end)

    source_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "messages" => inbox_messages,
        "inbox_messages" => inbox_messages,
        "status" => "ready",
        "fetched_at" => now
      })

    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "morning_brief_hour_local" => 8
      })

    context = %{
      agent_id: "agent-large-prompt",
      user_id: user_id,
      timestamp: now,
      source_bundle: source_bundle
    }

    {:effect, {:llm_call, params}, state} = MorningBriefing.handle_wakeup(state, context)

    prompt = get_in(params, ["messages", Access.at(0), "content"])
    [_instructions, input_json] = String.split(prompt, "Brief input JSON:\n", parts: 2)
    input = Jason.decode!(String.trim(input_json))

    {:ok, pending_json} = Jason.encode(state.pending_brief_input)

    assert String.length(pending_json) < 500_000
    assert String.length(prompt) < 500_000
    assert length(get_in(input, ["gmail", "recent_inbox"])) == 50
    assert length(get_in(input, ["gmail", "recent_unread"])) == 50

    pending_body =
      get_in(state.pending_brief_input, ["gmail", "recent_inbox", Access.at(0), "body"])

    pending_status =
      get_in(state.pending_brief_input, ["gmail", "recent_inbox", Access.at(0), "body_status"])

    first_body = get_in(input, ["gmail", "recent_inbox", Access.at(0), "body"])
    first_snippet = get_in(input, ["gmail", "recent_inbox", Access.at(0), "snippet"])

    assert String.length(pending_body) < 1_600
    assert pending_body =~ "[truncated"
    assert pending_status == "available_truncated"
    assert String.length(first_body) < 1_600
    assert String.length(first_snippet) < 500
    assert first_body =~ "[truncated"
    assert first_snippet =~ "[truncated"
  end

  test "adds explicit local display times for a configured named timezone", %{user_id: user_id} do
    now = ~U[2026-05-11 15:00:00Z]

    {:ok, _person} =
      Crm.upsert_person(user_id, %{
        "first_name" => "Dawn",
        "last_name" => "Nguyen",
        "email" => "dawn@gmail.com",
        "relationship" => "Runner enterprise design partner",
        "notes" => "External partner context for executive meeting prep."
      })

    state =
      MorningBriefing.init(%{
        "user_id" => user_id,
        "timezone" => "America/Los_Angeles",
        "timezone_offset_hours" => -5,
        "morning_brief_hour_local" => 8
      })

    source_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_calendar(%{
        "events" => [
          %{
            "event_id" => "evt-dawn",
            "summary" => "Dawn Nguyen",
            "start" => ~U[2026-05-11 19:00:00Z],
            "end" => ~U[2026-05-11 19:30:00Z],
            "attendees" => [
              %{"display_name" => "Dawn Nguyen", "email" => "dawn@gmail.com"}
            ]
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })

    input =
      MorningBriefing.build_brief_input(user_id, now, state, %{source_bundle: source_bundle})

    assert input["timezone"] == "PT"

    assert [
             %{
               "summary" => "Dawn Nguyen",
               "display_start" => "12:00 PM PT",
               "display_end" => "12:30 PM PT",
               "display_timezone" => "PT"
             }
           ] = input["calendar"]["today_events"]

    assert get_in(input, ["meeting_prep", "counts", "required_schedule_meetings"]) == 1
    assert get_in(input, ["meeting_prep", "counts", "web_searches"]) == 0

    assert [
             %{
               "summary" => "Dawn Nguyen",
               "display_start" => "12:00 PM PT",
               "display_end" => "12:30 PM PT",
               "display_timezone" => "PT"
             }
           ] = get_in(input, ["schedule_coverage", "required_meetings"])
  end

  test "keeps morning briefing on the highest-reasoning path", %{user_id: user_id} do
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

  test "does not regenerate when a persisted morning brief already exists", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-07 14:00:00Z]

    {:ok, _brief} =
      Briefs.record(user_id, agent.id, %{
        "cadence" => "morning",
        "title" => "Thursday morning briefing",
        "summary" => "Existing source-backed briefing for the local day.",
        "body" => "The briefing already exists for this local date.",
        "status" => "sent",
        "scheduled_for" => now,
        "dedupe_key" => "morning_briefing:2026-05-07"
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
      source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now})
    }

    assert {:idle, state} = MorningBriefing.handle_wakeup(state, context)
    assert state.last_generated_keys["morning"] == "2026-05-07"
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

    test "merges local calendar with Google source bundle when both exist", %{
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
              "summary" => "FreshBooks discovery",
              "start" => DateTime.add(now, 2 * 3_600, :second),
              "end" => DateTime.add(now, 3 * 3_600, :second)
            }
          ],
          "status" => "ready",
          "fetched_at" => now
        })

      input =
        MorningBriefing.build_brief_input(user_id, now, state, %{source_bundle: source_bundle})

      assert input["calendar"]["preferred_source"] == "local+google"
      assert [%{"summary" => "Runner GTM sync"} | _] = input["calendar"]["upcoming_local"]

      assert Enum.any?(input["calendar"]["today_events"], fn event ->
               event["summary"] == "Runner GTM sync"
             end)

      assert Enum.any?(input["calendar"]["today_events"] || [], fn event ->
               event["summary"] == "FreshBooks discovery"
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
