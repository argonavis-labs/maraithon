defmodule Maraithon.Behaviors.ChiefOfStaffBriefAgentTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Behaviors.ChiefOfStaffBriefAgent
  alias Maraithon.Briefs
  alias Maraithon.Insights

  setup do
    user_id = "chief-of-staff@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    %{user_id: user_id, agent: agent}
  end

  test "records a morning brief from open insights when the schedule is due", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-03-11 13:05:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send the investor deck",
          "summary" =>
            "You promised Sarah the updated deck and no sent follow-up has been found.",
          "recommended_action" => "Reply in the same thread with the deck or a firm ETA.",
          "priority" => 94,
          "confidence" => 0.91,
          "dedupe_key" => "brief-test:deck",
          "due_at" => scheduled_at,
          "metadata" => %{"account" => user_id}
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert payload.count == 1
    assert payload.user_id == user_id
    assert payload.cadences == ["morning"]
    assert next_state.last_generated_keys["morning"] == "2026-03-11"

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.cadence == "morning"
    assert brief.title == "Morning brief: 1 action to move"
    assert brief.summary =~ "Most urgent"
    refute brief.summary =~ "0 overdue"
    refute brief.summary =~ "0 threads on radar"
    refute brief.title =~ "1 items"
    refute brief.title =~ "worth watching"
    assert brief.body =~ "Best use of today:"
    assert brief.body =~ "Send the investor deck"
    assert is_list(brief.metadata["linked_todo_ids"])
    assert length(brief.metadata["linked_todo_ids"]) == 1
    assert brief.metadata["timezone_offset_hours"] == -5
  end

  test "named timezones drive DST-aware brief schedules and due-time copy", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-05-15 12:05:00Z]
    due_at = ~U[2026-05-15 14:30:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send Sarah the pricing plan",
          "summary" => "Sarah needs the plan before the customer call.",
          "recommended_action" =>
            "Reply in-thread with the pricing plan and the exact next step.",
          "priority" => 93,
          "confidence" => 0.91,
          "dedupe_key" => "brief-test:named-timezone-dst",
          "due_at" => due_at,
          "metadata" => %{
            "record" => %{
              "commitment" => "Send Sarah the pricing plan.",
              "person" => "Sarah",
              "status" => "unresolved",
              "next_action" => "Reply in-thread with the pricing plan and the exact next step."
            }
          }
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone" => "America/Toronto",
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert payload.cadences == ["morning"]

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.cadence == "morning"
    assert brief.body =~ "Due today by 10:30 AM ET."
    refute brief.body =~ "due date has already passed"
    assert brief.metadata["timezone_offset_hours"] == -4
    assert brief.metadata["timezone"] == "ET"
    assert brief.metadata["timezone_name"] == "America/Toronto"
  end

  test "morning briefs include all material default items instead of hiding work", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-03-11 13:05:00Z]

    insights =
      Enum.map(1..7, fn index ->
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send follow-through #{index}",
          "summary" => "Person #{index} is still waiting on a concrete owner or timing.",
          "recommended_action" =>
            "Reply to Person #{index} with the owner, status, and exact timing.",
          "priority" => 90 - index,
          "confidence" => 0.9,
          "dedupe_key" => "brief-test:all-material-default:#{index}",
          "due_at" => DateTime.add(scheduled_at, index, :minute),
          "metadata" => %{
            "record" => %{
              "commitment" => "Send follow-through #{index}.",
              "person" => "Person #{index}",
              "status" => "unresolved",
              "next_action" =>
                "Reply to Person #{index} with the owner, status, and exact timing."
            }
          }
        }
      end)

    {:ok, _insights} = Insights.record_many(user_id, agent.id, insights)

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16"
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert payload.cadences == ["morning"]

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title == "Morning brief: 7 actions to move"
    assert brief.summary =~ "6 more open items"

    for index <- 1..7 do
      assert brief.body =~ "Send follow-through #{index}"
    end

    refute brief.body =~ "open loop"

    assert length(brief.metadata["linked_todo_ids"]) == 7
    assert length(brief.metadata["linked_insight_ids"]) == 7
  end

  test "clean morning briefs avoid false all-clear and zero-count pressure copy" do
    user_id = "chief-clean-morning-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    scheduled_at = ~U[2026-03-11 13:05:00Z]

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert payload.cadences == ["morning"]

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title == "Morning brief: no direct action ready"

    assert brief.summary ==
             "No direct action or changed thread is ready for this brief."

    assert brief.body =~ "Best use of today:"
    assert brief.body =~ "No direct action is ready for this brief."
    assert brief.body =~ "Status:"
    assert brief.body =~ "No direct action is ready for this brief."

    refute brief.summary =~ "urgent"
    refute brief.title =~ "found"
    refute brief.summary =~ "found"
    refute brief.body =~ "Pressure:"
    refute brief.body =~ "0 items"
    refute brief.body =~ "Gmail, Calendar"
    refute brief.body =~ "No active work found"
    refute brief.body =~ "Nothing needs"
    refute brief.title =~ "clean slate"
  end

  test "morning briefs with only watched items avoid all-clear language" do
    user_id = "chief-watching-morning-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    scheduled_at = ~U[2026-03-11 13:05:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "attention_mode" => "monitor",
          "category" => "important_fyi",
          "title" => "Watch account recovery thread",
          "summary" => "The account recovery thread may need action if the owner does not reply.",
          "recommended_action" => "Watch for the owner's reply before interrupting.",
          "priority" => 82,
          "confidence" => 0.88,
          "dedupe_key" => "brief-test:watching-morning",
          "metadata" => %{"record" => %{"person" => "Growth team"}}
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert payload.cadences == ["morning"]

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title == "Morning brief: 1 thread on radar"

    assert brief.summary ==
             "1 important thread is on radar, with no direct action needed from you right now."

    assert brief.body =~ "On radar, not blocking right now:"
    refute brief.title =~ "clear"
    refute brief.summary =~ "clear"
    refute brief.summary =~ "founder"
  end

  test "clean end-of-day briefs avoid all-clear claims when no work surfaced" do
    user_id = "chief-clean-evening-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    scheduled_at = ~U[2026-03-11 23:05:00Z]

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })
      |> Map.put(:last_generated_keys, %{"morning" => "2026-03-11"})

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert payload.cadences == ["end_of_day"]

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title == "End-of-day review: no unresolved work ready"

    assert brief.summary ==
             "No unresolved action item is ready for tonight's review."

    assert brief.body =~ "Tonight's move:"
    assert brief.body =~ "No direct action is ready for tonight's review."
    assert brief.body =~ "Status:"
    assert brief.body =~ "No unresolved work is ready for tonight's review."

    refute brief.body =~ "Pressure:"
    refute brief.body =~ "0 items"
    refute brief.title =~ "found"
    refute brief.summary =~ "found"
    refute brief.body =~ "No active work found"
    refute brief.body =~ "Nothing important"
    refute brief.title =~ "all clear"
  end

  test "end-of-day briefs with only watched items avoid clear-list and founder language" do
    user_id = "chief-watching-evening-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    scheduled_at = ~U[2026-03-11 23:05:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "attention_mode" => "monitor",
          "category" => "important_fyi",
          "title" => "Watch legal response",
          "summary" => "Legal has the next move unless the response does not arrive.",
          "recommended_action" => "Watch for the response before interrupting.",
          "priority" => 82,
          "confidence" => 0.88,
          "dedupe_key" => "brief-test:watching-evening-legal"
        },
        %{
          "source" => "slack",
          "attention_mode" => "monitor",
          "category" => "important_fyi",
          "title" => "Watch launch channel",
          "summary" => "The launch channel is being monitored for a decision.",
          "recommended_action" => "Watch for a decision request before interrupting.",
          "priority" => 79,
          "confidence" => 0.84,
          "dedupe_key" => "brief-test:watching-evening-launch"
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })
      |> Map.put(:last_generated_keys, %{"morning" => "2026-03-11"})

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert payload.cadences == ["end_of_day"]

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title == "End-of-day review: 2 threads on radar"

    assert brief.summary ==
             "2 important threads are on radar, with no direct action needed from you tonight."

    assert brief.body =~ "On radar, not blocking right now:"
    refute brief.title =~ "clear"
    refute brief.summary =~ "clear"
    refute brief.summary =~ "founder"
  end

  test "renders end-of-day briefs as concrete operator guidance with structured context", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-03-11 23:05:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "important_fyi",
          "title" => "Account risk: Meta Ad Account Blocked",
          "summary" =>
            "This looks like an account restriction or access issue that can block work or revenue.",
          "recommended_action" =>
            "Open the notice now, confirm the exact restriction, and coordinate the unblock owner today.",
          "priority" => 96,
          "confidence" => 0.94,
          "dedupe_key" => "brief-test:meta-blocked",
          "due_at" => DateTime.add(scheduled_at, -2, :hour),
          "metadata" => %{
            "why_now" =>
              "A blocked or restricted account can stop important work until someone resolves it.",
            "record" => %{
              "commitment" => "Resolve the Meta ad account restriction",
              "person" => "Growth team",
              "status" => "unresolved",
              "evidence" => ["Restriction notice is still active in the account inbox."],
              "next_action" =>
                "Open the notice now, confirm the exact restriction, and coordinate the unblock owner today."
            }
          }
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert "end_of_day" in payload.cadences

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.cadence == "end_of_day"
    assert brief.title == "End-of-day review: 1 item to close or reset"
    assert brief.summary =~ "Most urgent"
    refute brief.summary =~ "0 threads on radar"
    refute brief.title =~ "1 items"
    refute brief.title =~ "still open"
    assert brief.body =~ "Tonight's move:"
    assert brief.body =~ "Close or reset:"
    assert brief.body =~ "Waiting on: Growth team"
    assert brief.body =~ "Do: Open the notice now"
    assert brief.body =~ "Why: A blocked or restricted account can stop important work"
    assert brief.body =~ "Overdue since Wed, Mar 11 at 4:05 PM"
    assert brief.body =~ "Context: Restriction notice is still active"
    assert is_list(brief.metadata["linked_todo_ids"])
    assert length(brief.metadata["linked_todo_ids"]) == 1
    assert brief.metadata["timezone_offset_hours"] == -5
    refute Regex.match?(~r/\b\d{1,2}\/\d{1,2}\b/, brief.body)
  end

  test "keeps monitor items out of top actions and includes them in Watching", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-03-11 23:05:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send the investor deck",
          "summary" => "You still owe the investor deck today.",
          "recommended_action" => "Reply in the same thread with the deck or a firm ETA.",
          "priority" => 94,
          "confidence" => 0.91,
          "dedupe_key" => "brief-test:act-now",
          "due_at" => DateTime.add(scheduled_at, -2, :hour),
          "metadata" => %{"why_now" => "Overdue since the promised send time."}
        },
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Monitoring: Meta Ad Account thread",
          "summary" => "The thread is active and being handled, but it still matters.",
          "recommended_action" =>
            "Watch for a blocker, a direct ask back to you, or a stall in progress.",
          "priority" => 88,
          "confidence" => 0.87,
          "attention_mode" => "monitor",
          "dedupe_key" => "brief-test:monitor",
          "tracking_key" => "brief-test:monitor",
          "due_at" => DateTime.add(scheduled_at, -1, :hour),
          "metadata" => %{
            "why_now" => "Breck acknowledged the thread and is checking his side."
          }
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })
      |> Map.put(:last_generated_keys, %{"morning" => "2026-03-11"})

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, _payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)

    assert brief.body =~ "Close or reset:"
    assert brief.body =~ "[Gmail] Send the investor deck"
    assert brief.body =~ "On radar, not blocking right now:"
    assert brief.body =~ "[Gmail] Monitoring: Meta Ad Account thread"
    assert brief.body =~ "Track: Watch for a blocker"
    assert brief.body =~ "1 thread is on radar"
  end

  test "records an adaptive daytime check-in when important work is still open", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-03-11 20:30:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send revised pricing to David",
          "summary" => "David is still waiting on the revised pricing and exact timing.",
          "recommended_action" =>
            "Reply in-thread with the revised pricing, owner, and exact send timing.",
          "priority" => 92,
          "confidence" => 0.93,
          "dedupe_key" => "brief-test:check-in-pricing",
          "due_at" => DateTime.add(scheduled_at, -3, :hour),
          "metadata" => %{
            "record" => %{
              "commitment" => "Send revised pricing and timing to David.",
              "person" => "David",
              "status" => "unresolved",
              "evidence" => ["The thread still has no revised pricing or final timing update."],
              "next_action" =>
                "Reply in-thread with the revised pricing, owner, and exact send timing."
            }
          }
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })
      |> Map.put(:last_generated_keys, %{"morning" => "2026-03-11"})

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert payload.cadences == ["check_in"]
    assert next_state.last_generated_keys["check_in"] =~ "2026-03-11:slot:"

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.cadence == "check_in"
    assert brief.title == "Check-in: 1 item ready for a decision"
    assert brief.summary =~ "Most urgent"
    assert brief.body =~ "Why this check-in matters:"
    assert brief.body =~ "Move now:"
    assert brief.body =~ "1 item is waiting on a decision or reply"
    assert brief.body =~ "Reply here when one is handled; Maraithon will refresh the rest."
    assert brief.body =~ "Send revised pricing to David"
    refute brief.body =~ "Why I'm"
    refute brief.body =~ "I'll"
    refute brief.body =~ "act-now"
    refute brief.body =~ "score"
    refute brief.body =~ "signal"
    assert is_list(brief.metadata["linked_todo_ids"])
    assert length(brief.metadata["linked_todo_ids"]) == 1
    assert brief.metadata["timezone_offset_hours"] == -5
  end

  test "weekly review body uses operator language instead of scorecard language", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-03-13 21:05:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send revised pricing to David",
          "summary" => "David is still waiting on the revised pricing.",
          "recommended_action" => "Reply with the owner, timing, and next step.",
          "priority" => 92,
          "confidence" => 0.93,
          "dedupe_key" => "brief-test:weekly-pricing",
          "due_at" => DateTime.add(scheduled_at, -3, :hour),
          "metadata" => %{
            "record" => %{
              "commitment" => "Send revised pricing to David.",
              "person" => "David",
              "status" => "unresolved",
              "next_action" => "Reply with the owner, timing, and next step."
            }
          }
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })
      |> Map.put(:last_generated_keys, %{"morning" => "2026-03-13"})

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert payload.cadences == ["weekly_review"]

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.cadence == "weekly_review"
    assert brief.title == "Weekly review: 1 item ready for a decision"
    assert brief.summary == "1 item reviewed this week, and 1 remains open."
    assert brief.body =~ "Week in review:"
    assert brief.body =~ "- 1 Gmail item"
    assert brief.body =~ "Next week's move:"
    assert brief.body =~ "Start Monday by sending the owner, status, or ETA reset"
    assert brief.body =~ "Most important open items:"
    refute brief.body =~ "0 Calendar"
    refute brief.body =~ "0 Slack"
    refute brief.title =~ "1 items"
    refute brief.summary =~ "0 were"
    refute brief.body =~ "scorecard"
    refute brief.body =~ "score"
    refute brief.body =~ "confidence"
  end

  test "clean weekly reviews avoid zero-count open-work titles" do
    user_id = "chief-clean-weekly-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    scheduled_at = ~U[2026-03-13 21:05:00Z]

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })
      |> Map.put(:last_generated_keys, %{"morning" => "2026-03-13"})

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    assert payload.cadences == ["weekly_review"]

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title == "Weekly review: no open work ready"
    assert brief.summary == "No open work is ready from this week's review."
    assert brief.body =~ "Next week's move:"
    assert brief.body =~ "confirm calendar context and any new promises"
    assert brief.body =~ "- No activity needed review this week"
    assert brief.body =~ "Most important open items:"
    assert brief.body =~ "No open work is ready from this week's review."

    refute brief.title =~ "0 items"
    refute brief.summary =~ "0"
    refute brief.title =~ "found"
    refute brief.summary =~ "found"
    refute brief.body =~ "No open work found"
  end

  test "skips adaptive check-ins when only low-priority work is open", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-03-11 20:30:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_owed",
          "title" => "Low-priority follow-up",
          "summary" => "This can wait a bit.",
          "recommended_action" => "Reply later with a short follow-up.",
          "priority" => 52,
          "confidence" => 0.58,
          "dedupe_key" => "brief-test:check-in-low-priority",
          "due_at" => DateTime.add(scheduled_at, 2, :day),
          "metadata" => %{"why_now" => "This is still open, but not urgent."}
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })
      |> Map.put(:last_generated_keys, %{"morning" => "2026-03-11"})

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:idle, next_state} = ChiefOfStaffBriefAgent.handle_wakeup(state, context)
    assert next_state.last_generated_keys["check_in"] =~ "2026-03-11:slot:"
    assert Briefs.list_recent_for_user(user_id, limit: 5) == []
  end

  test "prefers structured commitments over generic reply-owed titles in briefs", %{
    user_id: user_id,
    agent: agent
  } do
    scheduled_at = ~U[2026-03-11 23:05:00Z]

    {:ok, _insights} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Reply owed: Re: Cowrie Agora Update - Week 10",
          "summary" => "The project update thread still needs a final owner and ETA.",
          "recommended_action" => "Reply now with the owner, current status, and a concrete ETA.",
          "priority" => 91,
          "confidence" => 0.9,
          "dedupe_key" => "brief-test:generic-title",
          "due_at" => DateTime.add(scheduled_at, -2, :hour),
          "metadata" => %{
            "record" => %{
              "commitment" => "Reply to David with the owner, status, and ETA for Week 10.",
              "person" => "David",
              "status" => "unresolved",
              "evidence" => ["The thread still has no final owner or ETA response."],
              "next_action" => "Reply now with the owner, current status, and a concrete ETA."
            }
          }
        }
      ])

    state =
      ChiefOfStaffBriefAgent.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => "-5",
        "morning_brief_hour_local" => "8",
        "end_of_day_brief_hour_local" => "18",
        "weekly_review_day_local" => "5",
        "weekly_review_hour_local" => "16",
        "brief_max_items" => "3"
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: scheduled_at,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    assert {:emit, {:briefs_recorded, _payload}, _next_state} =
             ChiefOfStaffBriefAgent.handle_wakeup(state, context)

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)

    assert brief.body =~ "Reply to David with the owner, status, and ETA for Week 10."
    refute brief.body =~ "Reply owed: Re: Cowrie Agora Update - Week 10"
  end
end
