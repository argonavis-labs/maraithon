defmodule Maraithon.ChiefOfStaff.Skills.MorningBriefingTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.Skills.MorningBriefing
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.Commitments
  alias Maraithon.ConnectedAccounts

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

    assert params["max_tokens"] == 12_000
    assert params["reasoning_effort"] == "high"

    prompt = get_in(params, ["messages", Access.at(0), "content"])
    assert prompt =~ "Brief input JSON"
    assert prompt =~ "Skill instructions"
    assert prompt =~ "Email review rule"
    assert prompt =~ "body_available"
    assert prompt =~ "Instagram reported a new login"
    assert prompt =~ "Promotional retail offer"
    assert prompt =~ ~s({"title":"...","summary":"...","body":"..."})
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
end
