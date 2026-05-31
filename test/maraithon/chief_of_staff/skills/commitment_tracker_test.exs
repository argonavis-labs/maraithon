defmodule Maraithon.ChiefOfStaff.Skills.CommitmentTrackerTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.Skills
  alias Maraithon.ChiefOfStaff.Skills.CommitmentTracker
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.Crm
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
            "message_id" => "msg-ask",
            "thread_id" => "thread-elena",
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
            "message_id" => "msg-sent",
            "thread_id" => "thread-elena",
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

    assert params["max_tokens"] == 8_000
    assert params["reasoning_effort"] == "high"

    prompt = get_in(params, ["messages", Access.at(0), "content"])
    assert prompt =~ "Commitment Tracker"
    assert prompt =~ "Commitment tracker input JSON"
    assert prompt =~ "Return only valid JSON"
    assert prompt =~ "Open work review"
    assert prompt =~ "do not write \"Commitment"
    assert prompt =~ "source_access"
    assert prompt =~ "iMessage, WhatsApp, OmniFocus"
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
              "owner_label" => "Kent",
              "source_account_label" => "kent@runner.now",
              "source_item_id" => "thread-elena",
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
                "source_ref" => "gmail thread-elena",
                "quote" => "I'll send the revised version tomorrow.",
                "omni_project" => "Runner",
                "source_tags" => ["runner", "gmail"]
              }
            }
          ]
        })
    }

    {:emit, {:briefs_recorded, payload}, _state} =
      CommitmentTracker.handle_effect_result({:llm_call, response}, state, context)

    assert payload.cadences == ["commitment_tracker"]
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
