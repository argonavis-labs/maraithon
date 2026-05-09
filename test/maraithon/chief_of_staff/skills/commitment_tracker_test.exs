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

  test "builds a source-backed prompt and persists model-emitted commitment todos", %{
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
    assert brief.body =~ "Logged in Maraithon:"
    assert brief.metadata["origin_skill_id"] == "commitment_tracker"
    assert get_in(brief.metadata, ["tracker_input", "counts", "gmail_recent_inbox"]) == 1
    assert get_in(brief.metadata, ["tracker_input", "counts", "gmail_recent_sent"]) == 1
    assert get_in(brief.metadata, ["tracker_input", "counts", "calendar_upcoming_events"]) == 1

    [todo] = Todos.list_for_user(user_id, source: "gmail", limit: 5)
    assert brief.body =~ todo.id
    assert todo.title == "Send Elena the revised Runner ambassador agreement"
    assert todo.metadata["origin_skill_id"] == "commitment_tracker"
    assert todo.metadata["commitment_direction"] == "i_owe"
    assert todo.metadata["omni_project"] == "Runner"

    assert get_in(todo.metadata, ["todo_intelligence", "source"]) ==
             "chief_of_staff_commitment_tracker"

    [person] = Crm.list_people(user_id, query: "Elena", limit: 5)
    assert person.display_name == "Elena Saradidis"

    assert {:ok, relationship} =
             Crm.relationship_context(user_id, %{"person_id" => person.id, "link_limit" => 5})

    assert relationship.open_todo_count == 1
    assert Enum.any?(relationship.todos, &(&1.id == todo.id))
  end

  test "invalid model output records an explicit error without heuristic todo creation", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-09 15:00:00Z]

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
      source_bundle: SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now}),
      assistant_cycle_id: "cycle-error"
    }

    {:effect, {:llm_call, _params}, state} = CommitmentTracker.handle_wakeup(state, context)

    {:emit, {:brief_generation_failed, payload}, _state} =
      CommitmentTracker.handle_effect_result({:llm_call, %{content: "not json"}}, state, context)

    assert payload.generation_mode == "error"
    assert payload.todo_count == 0
    assert payload.error_message =~ "model_response_invalid"

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.title == "Commitment tracker generation failed"
    assert brief.cadence == "commitment_tracker"
    assert brief.error_message =~ "model_response_invalid"
    assert brief.body =~ "No heuristic or keyword-based fallback was used."
    assert Todos.list_for_user(user_id, limit: 5) == []
  end
end
