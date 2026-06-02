defmodule Maraithon.Behaviors.InboxCalendarAdvisorTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Behaviors.InboxCalendarAdvisor
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.OAuth
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.Todos

  setup do
    original_gmail_config = Application.get_env(:maraithon, :gmail)

    on_exit(fn ->
      if original_gmail_config do
        Application.put_env(:maraithon, :gmail, original_gmail_config)
      else
        Application.delete_env(:maraithon, :gmail)
      end
    end)

    user_id = "advisor-user@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "inbox_calendar_advisor",
        config: %{}
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: DateTime.utc_now(),
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      event: nil
    }

    %{user_id: user_id, agent: agent, context: context}
  end

  describe "handle_wakeup/2" do
    test "produces llm effect from gmail pubsub payload", %{context: context} do
      state = InboxCalendarAdvisor.init(%{"user_id" => context.user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-1",
              "thread_id" => "thread-1",
              "subject" => "Urgent: customer escalation",
              "snippet" => "Need response ASAP",
              "from" => "ceo@example.com",
              "to" => "ops@example.com, success@example.com",
              "labels" => ["INBOX", "IMPORTANT", "UNREAD"],
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      context = %{context | event: %{payload: payload}}

      {:effect, {:llm_call, params}, new_state} =
        InboxCalendarAdvisor.handle_wakeup(state, context)

      assert is_map(params)
      assert params["model"] == Maraithon.LLM.chat_model()
      assert params["max_tokens"] == 6_000
      assert params["reasoning_effort"] == "none"
      assert params["temperature"] == 0.15
      assert length(new_state.pending_candidates) >= 1
      prompt = get_in(params, ["messages", Access.at(0), "content"])
      assert prompt =~ "thread-1"
      assert prompt =~ "IMPORTANT"
      assert prompt =~ "ops@example.com"
      assert prompt =~ "automated transactional receipts"
      assert prompt =~ "Uber Eats"
      assert prompt =~ "false_positive_risk"
      assert prompt =~ "executive chief-of-staff assistant"
      assert prompt =~ "direct operator action now"
      assert prompt =~ "operator response actions"
      assert prompt =~ "A real human sender does not imply a reply owed"
      assert prompt =~ "evidence_for_reply_owed"
      assert prompt =~ "evidence_against_reply_owed"
      assert prompt =~ "unsolicited sales outreach"
      assert prompt =~ "Return at most 5 items"
      assert prompt =~ "Keep every string field to one short sentence"
      refute prompt =~ "founder accountability assistant"
      refute prompt =~ "direct founder action"
      refute prompt =~ "founder response actions"
      refute prompt =~ "founder interruption"
      refute prompt =~ "founder commitment"
    end

    test "bounds advisor triage prompts before the llm call", %{context: context} do
      state = InboxCalendarAdvisor.init(%{"user_id" => context.user_id})
      large_body = String.duplicate("Can you send the promised deck today? ", 2_000)

      messages =
        for index <- 1..30 do
          %{
            "message_id" => "msg-bounded-#{index}",
            "thread_id" => "thread-bounded-#{index}",
            "subject" => "Urgent: customer escalation #{index}",
            "snippet" => String.duplicate("Need response ASAP ", 200),
            "text_body" => large_body,
            "from" => "customer-#{index}@example.com",
            "to" => context.user_id,
            "labels" => ["INBOX", "IMPORTANT", "UNREAD"],
            "internal_date" => DateTime.utc_now()
          }
        end

      payload = %{"source" => "gmail", "data" => %{"messages" => messages}}

      {:effect, {:llm_call, params}, new_state} =
        InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      prompt = get_in(params, ["messages", Access.at(0), "content"])

      assert params["model"] == Maraithon.LLM.chat_model()
      assert params["max_tokens"] == 6_000
      assert length(new_state.pending_candidates) in 1..20
      assert String.length(prompt) < 80_000
      refute prompt =~ String.duplicate("Can you send the promised deck today? ", 100)
    end

    test "titles sent commitments as missing follow-through instead of missing reply", %{
      context: context
    } do
      sent_at = DateTime.add(DateTime.utc_now(), -2, :hour)

      sent_message = %{
        "message_id" => "sent-commitment-title-1",
        "thread_id" => "thread-sent-commitment-title",
        "subject" => "Investor deck",
        "snippet" => "I'll send the deck to Sarah today.",
        "text_body" => "I'll send the deck to Sarah today.",
        "from" => context.user_id,
        "to" => "Sarah <sarah@example.com>",
        "labels" => ["SENT"],
        "internal_date" => sent_at
      }

      source_bundle =
        context
        |> SourceBundle.empty()
        |> SourceBundle.put_gmail(%{"sent_messages" => [sent_message]})

      state = InboxCalendarAdvisor.init(%{"user_id" => context.user_id})

      {:effect, {:llm_call, _params}, new_state} =
        InboxCalendarAdvisor.handle_wakeup(state, Map.put(context, :source_bundle, source_bundle))

      candidate =
        Enum.find(new_state.pending_candidates, &(&1["category"] == "commitment_unresolved"))

      assert candidate["title"] =~ "No follow-through is recorded yet."
      refute candidate["title"] =~ "No reply has gone out yet"
    end

    test "includes Telegram feedback context in the llm prompt", %{
      user_id: user_id,
      agent: agent,
      context: context
    } do
      {:ok, [prior_insight]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Customer escalation follow-up",
            "summary" => "The user previously wanted fast escalation notices.",
            "recommended_action" => "Reply with a same-day update.",
            "priority" => 92,
            "confidence" => 0.9,
            "dedupe_key" => "feedback:prior:1"
          }
        ])

      Repo.insert!(
        Delivery.changeset(%Delivery{}, %{
          insight_id: prior_insight.id,
          user_id: user_id,
          channel: "telegram",
          destination: "12345",
          score: 0.91,
          threshold: 0.78,
          status: "feedback_helpful",
          feedback: "helpful",
          feedback_at: DateTime.utc_now()
        })
      )

      {:ok, _preference} =
        PreferenceMemory.apply_explicit_instruction(
          user_id,
          "treat investors as urgent",
          llm_complete: fn _prompt ->
            {:ok,
             Jason.encode!(%{
               "reply" => "Understood. I'll bias investor-related loops toward urgency.",
               "rules" => [
                 %{
                   "id" => "treat_investors_urgent",
                   "kind" => "urgency_boost",
                   "label" => "Treat investors as urgent",
                   "instruction" =>
                     "Bias investor-related Gmail, Calendar, and Slack loops toward higher urgency and faster interruption.",
                   "applies_to" => ["gmail", "calendar", "slack", "telegram"],
                   "confidence" => 0.94,
                   "filters" => %{"topics" => ["investor"], "priority_bias" => "high"}
                 }
               ]
             })}
          end
        )

      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-feedback",
              "subject" => "Urgent: board prep",
              "snippet" => "Need an agenda today",
              "from" => "ceo@example.com",
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      {:effect, {:llm_call, params}, _new_state} =
        InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      prompt = get_in(params, ["messages", Access.at(0), "content"])

      assert prompt =~ "Recent Telegram feedback JSON"
      assert prompt =~ "Durable preference memory JSON"
      assert prompt =~ "Customer escalation follow-up"
      assert prompt =~ "Treat investors as urgent"
      assert prompt =~ "telegram_fit_score"
    end

    test "includes calendar context in the llm prompt", %{context: context} do
      state = InboxCalendarAdvisor.init(%{"user_id" => context.user_id})

      payload = %{
        "source" => "google_calendar",
        "data" => %{
          "events" => [
            %{
              "event_id" => "evt-1",
              "summary" => "Customer QBR",
              "description" => "Discuss renewals, risks, and open escalations.",
              "location" => "Zoom",
              "organizer" => "vp@example.com",
              "start" => DateTime.add(DateTime.utc_now(), -2, :hour),
              "end" => DateTime.add(DateTime.utc_now(), -1, :hour),
              "attendees" => [
                %{
                  "email" => "vp@example.com",
                  "display_name" => "VP",
                  "response_status" => "accepted"
                },
                %{
                  "email" => "ae@example.com",
                  "display_name" => "AE",
                  "response_status" => "tentative"
                }
              ]
            }
          ]
        }
      }

      {:effect, {:llm_call, params}, _new_state} =
        InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      prompt = get_in(params, ["messages", Access.at(0), "content"])

      assert prompt =~ "Zoom"
      assert prompt =~ "vp@example.com"
      assert prompt =~ "response_counts"
    end

    test "returns idle when user id missing", %{context: context} do
      state = InboxCalendarAdvisor.init(%{})
      context = %{context | user_id: nil, event: nil}

      assert {:idle, _state} = InboxCalendarAdvisor.handle_wakeup(state, context)
    end

    test "downgrades Gmail reply debt when another participant already replied in the thread", %{
      user_id: user_id,
      context: context
    } do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "google-access",
          refresh_token: "google-refresh",
          expires_in: 3600
        })

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"messages" => []}))
      end)

      thread_started_at = DateTime.utc_now() |> DateTime.add(-2, :hour)
      teammate_reply_at = DateTime.add(thread_started_at, 30, :minute)

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/threads/thread-1", fn conn ->
        assert conn.query_string == "format=metadata"

        body = %{
          "messages" => [
            gmail_thread_message(
              "msg-1",
              "thread-1",
              "David <david@example.com>",
              user_id,
              "Cowrie Agora Update",
              "Can you send the update today?",
              thread_started_at
            ),
            gmail_thread_message(
              "msg-2",
              "thread-1",
              "Charlie <charlie@example.com>",
              "David <david@example.com>, #{user_id}",
              "Re: Cowrie Agora Update",
              "I'll handle this and send the update by today.",
              teammate_reply_at
            )
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-1",
              "thread_id" => "thread-1",
              "subject" => "Cowrie Agora Update",
              "snippet" => "Can you send the update today?",
              "from" => "David <david@example.com>",
              "to" => user_id,
              "labels" => ["INBOX", "IMPORTANT", "UNREAD"],
              "internal_date" => thread_started_at
            }
          ]
        }
      }

      {:effect, {:llm_call, _params}, new_state} =
        InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      [candidate] = new_state.pending_candidates

      assert get_in(candidate, ["metadata", "conversation_context", "notification_posture"]) ==
               "heads_up"

      assert candidate["attention_mode"] == "monitor"
      assert candidate["summary"] =~ "Charlie has already responded"
      assert candidate["summary"] =~ "conversation is moving"
      assert candidate["recommended_action"] =~ "Monitor the thread"
      assert candidate["metadata"]["why_now"] =~ "Keep watching for a blocker"

      assert get_in(candidate, ["metadata", "detail", "conversation_summary"]) =~
               "Charlie has already responded"
    end

    test "suppresses clear cold sales outreach before the llm call", %{
      user_id: user_id,
      context: context
    } do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "google-access",
          refresh_token: "google-refresh",
          expires_in: 3600
        })

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"messages" => []}))
      end)

      first_touch_at = DateTime.utc_now() |> DateTime.add(-2, :day)
      follow_up_at = DateTime.add(first_touch_at, 1, :day)

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/threads/thread-cold-1", fn conn ->
        assert conn.query_string == "format=metadata"

        body = %{
          "messages" => [
            gmail_thread_message(
              "msg-cold-1",
              "thread-cold-1",
              "Ayoub Rezala <ayoub@outly.com>",
              user_id,
              "shipping while Claude is thinking",
              "Saw your post about shipping while Claude is thinking.",
              first_touch_at
            ),
            gmail_thread_message(
              "msg-cold-2",
              "thread-cold-1",
              "Ayoub Rezala <ayoub@outly.com>",
              user_id,
              "Re: shipping while Claude is thinking",
              "Following up. Worth a quick call? Here's my Calendly and outbound sales on autopilot pitch.",
              follow_up_at
            )
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-cold-2",
              "thread_id" => "thread-cold-1",
              "subject" => "Re: shipping while Claude is thinking",
              "snippet" =>
                "Following up. Worth a quick call? Here's my Calendly and outbound sales on autopilot pitch.",
              "from" => "Ayoub Rezala <ayoub@outly.com>",
              "to" => user_id,
              "labels" => ["INBOX", "UNREAD"],
              "internal_date" => follow_up_at
            }
          ]
        }
      }

      assert {:effect, {:llm_call, params}, new_state} =
               InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      assert new_state.pending_candidates == []
      assert new_state.pending_llm_kind == :relationships
      prompt = get_in(params, ["messages", Access.at(0), "content"])
      assert prompt =~ "RELATIONSHIP_INTELLIGENCE_JSON_V1"
      assert prompt =~ "Ayoub Rezala"
    end

    test "persists high-impact account-risk Gmail as important_fyi without an llm pass", %{
      user_id: user_id,
      context: context
    } do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-meta-risk",
              "thread_id" => "thread-meta-risk",
              "subject" => "Meta Ad Account Blocked",
              "snippet" =>
                "Your ad account is blocked and access is restricted pending verification.",
              "from" => "Meta Support <security@facebookmail.com>",
              "to" => user_id,
              "labels" => ["INBOX"],
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      assert {:emit, {:insights_recorded, result}, final_state} =
               InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      assert result.count == 1
      assert final_state.pending_candidates == []
      assert final_state.pending_direct_insights == []

      [stored | _] = Insights.list_open_for_user(user_id)
      assert stored.category == "important_fyi"
      assert stored.title =~ "Account risk"
      assert stored.recommended_action =~ "coordinate the unblock owner"
      assert stored.metadata["ackable"] == false
      assert stored.metadata["fyi_class"] == "account_risk"
      assert stored.metadata["telegram_fit_score"] == 0.95
      assert stored.metadata["why_now"] =~ "blocked or restricted account"
    end

    test "uses saved watch rules to surface hockey Gmail as important_fyi", %{
      user_id: user_id,
      context: context
    } do
      {:ok, [_rule]} =
        PreferenceMemory.save_interpreted_rules(
          user_id,
          [
            %{
              "id" => "watch_hockey_email",
              "kind" => "urgency_boost",
              "label" => "Watch hockey emails",
              "instruction" =>
                "Surface hockey-related emails as important FYI so they appear in Gmail triage and Telegram digests.",
              "applies_to" => ["gmail", "telegram"],
              "confidence" => 0.97,
              "filters" => %{
                "topics" => ["sports", "hockey"],
                "keywords" => ["hockey", "playoff", "game"],
                "delivery_mode" => "important_fyi",
                "ackable" => true,
                "priority_bias" => "high"
              }
            }
          ],
          "explicit_telegram",
          explicit?: true
        )

      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-hockey-1",
              "thread_id" => "thread-hockey-1",
              "subject" => "Team Green next Playoff game = Tuesday March 17 @ 7:15 PM",
              "snippet" => "Hockey schedule update for this week.",
              "from" => "Paul Michel <paul@example.com>",
              "to" => user_id,
              "labels" => ["INBOX"],
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      assert {:emit, {:insights_recorded, result}, _final_state} =
               InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      assert result.count == 1

      [stored | _] = Insights.list_open_for_user(user_id)
      assert stored.category == "important_fyi"
      assert stored.title =~ "Watch hockey emails"
      assert stored.metadata["ackable"] == true
      assert stored.metadata["fyi_class"] == "watch_topic"
      assert stored.metadata["watch_rule_ids"] != []
      assert stored.metadata["why_now"] =~ "Watch hockey emails"
      assert stored.recommended_action =~ "Review the update and decide the next step"
    end

    test "does not surface hockey Gmail without a saved watch rule", %{
      user_id: user_id,
      context: context
    } do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-hockey-unsaved-1",
              "thread_id" => "thread-hockey-unsaved-1",
              "subject" => "Team Green next Playoff game = Tuesday March 17 @ 7:15 PM",
              "snippet" => "Hockey schedule update for this week.",
              "from" => "Paul Michel <paul@example.com>",
              "to" => user_id,
              "labels" => ["INBOX"],
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      assert {:effect, {:llm_call, params}, new_state} =
               InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      assert new_state.pending_candidates == []
      assert new_state.pending_llm_kind == :relationships
      prompt = get_in(params, ["messages", Access.at(0), "content"])
      assert prompt =~ "RELATIONSHIP_INTELLIGENCE_JSON_V1"
      assert prompt =~ "Hockey schedule update"

      assert Insights.list_open_for_user(user_id) == []
    end

    test "does not auto-create finance todos from keyword-only Gmail", %{
      user_id: user_id,
      context: context
    } do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-rrsp-1",
              "thread_id" => "thread-rrsp-1",
              "subject" => "Your RRSP contribution receipt is ready",
              "snippet" =>
                "Your RRSP contribution and contribution room details are now available.",
              "from" => "Wealthsimple <no-reply@wealthsimple.com>",
              "to" => user_id,
              "labels" => ["INBOX"],
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      assert {:effect, {:llm_call, params}, new_state} =
               InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      assert new_state.pending_candidates == []
      assert new_state.pending_direct_insights == []
      assert new_state.pending_llm_kind == :relationships
      prompt = get_in(params, ["messages", Access.at(0), "content"])
      assert prompt =~ "RELATIONSHIP_INTELLIGENCE_JSON_V1"
      assert prompt =~ "Wealthsimple"

      assert Insights.list_open_for_user(user_id) == []
    end

    test "uses full Gmail body for school newsletter model review", %{
      user_id: user_id,
      context: context
    } do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-school-4m-1",
              "thread_id" => "thread-school-4m-1",
              "subject" => "4M Weekly Newsletter May 11-15",
              "snippet" => "Weekly update",
              "text_body" =>
                "Hi 4M families. Emma's field trip permission form is due Friday. Can you please send the signed consent back by Friday?",
              "from" => "Marla Maharaj <teacher@example.com>",
              "to" => user_id,
              "labels" => ["INBOX"],
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      assert {:effect, {:llm_call, params}, new_state} =
               InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      assert new_state.pending_direct_insights == []
      prompt = get_in(params, ["messages", Access.at(0), "content"])
      assert prompt =~ "Emma's field trip permission form is due Friday"
      assert prompt =~ ~s("body_excerpt")
      assert prompt =~ "class name such as \"4M\""
      assert prompt =~ "not finance evidence"
      refute prompt =~ "Finance update"
      assert Insights.list_open_for_user(user_id) == []
    end

    test "surfaces App Store Connect notifications as important_fyi", %{
      user_id: user_id,
      context: context
    } do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-app-store-1",
              "thread_id" => "thread-app-store-1",
              "subject" => "Apple Connect Notifications: App Store Connect In Review",
              "snippet" => "Your app is now In Review in App Store Connect.",
              "from" => "App Store Connect <no_reply@email.apple.com>",
              "to" => user_id,
              "labels" => ["INBOX"],
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      assert {:emit, {:insights_recorded, result}, _final_state} =
               InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      assert result.count == 1

      [stored | _] = Insights.list_open_for_user(user_id)
      assert stored.category == "important_fyi"
      assert stored.title =~ "Platform status"
      assert stored.metadata["ackable"] == true
      assert stored.metadata["fyi_class"] == "platform_status"
      assert stored.metadata["why_now"] =~ "release planning"
      assert stored.recommended_action =~ "monitor it"
    end
  end

  describe "handle_effect_result/3" do
    test "persists refined insights", %{user_id: user_id, context: context} do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-2",
              "subject" => "Urgent follow-up needed",
              "snippet" => "Please respond today",
              "from" => "ops@example.com",
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      {:effect, {:llm_call, _params}, state_after_wakeup} =
        InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      dedupe_key = hd(state_after_wakeup.pending_candidates)["dedupe_key"]

      llm_response = %{
        content:
          Jason.encode!([
            %{
              "dedupe_key" => dedupe_key,
              "title" => "Reply to ops today",
              "summary" => "This looks time-sensitive and should be acknowledged quickly.",
              "recommended_action" =>
                "Reply now, confirm next steps, and suggest a same-day checkpoint if needed.",
              "priority" => 95,
              "confidence" => 0.91,
              "actionability" => "actionable",
              "obligation_type" => "direct_human_request",
              "human_counterparty" => true,
              "missing_followthrough_evidence" => true,
              "interrupt_now" => true,
              "thread_type" => "customer_work",
              "solicited" => false,
              "prior_user_engagement" => false,
              "explicit_user_commitment" => false,
              "reply_obligation" => true,
              "importance" => "important",
              "evidence_for_reply_owed" => [
                "Reply request terms: urgent, please respond today.",
                "Thread is unread in Gmail."
              ],
              "evidence_against_reply_owed" => [],
              "decision_reason" =>
                "A direct human request remains unanswered and no outreach-style disqualifiers were found.",
              "false_positive_risk" => 0.12,
              "reasoning_summary" =>
                "Human sender requested a same-day response and no reply evidence exists.",
              "telegram_fit_score" => 0.93,
              "telegram_fit_reason" => "User tends to value urgent email follow-ups in Telegram.",
              "why_now" => "The sender is asking for a same-day response on an active thread.",
              "follow_up_ideas" => [
                "Draft the reply with a clear owner and ETA.",
                "Flag any blockers before the next customer touchpoint."
              ]
            }
          ])
      }

      {:emit, {:insights_recorded, payload}, final_state} =
        InboxCalendarAdvisor.handle_effect_result(
          {:llm_call, llm_response},
          state_after_wakeup,
          context
        )
        |> complete_relationship_learning(context)

      assert payload.count == 1
      assert payload.user_id == user_id
      assert final_state.pending_candidates == []

      [stored | _] = Insights.list_open_for_user(user_id)
      assert stored.title == "Reply to ops today"
      assert stored.priority == 95
      assert stored.category in ["reply_urgent", "commitment_unresolved", "meeting_follow_up"]
      assert stored.metadata["telegram_fit_score"] == 0.93
      assert stored.metadata["telegram_fit_reason"] =~ "urgent email"
      assert stored.metadata["feedback_tuned"] == true
      assert stored.metadata["why_now"] =~ "same-day response"
      assert stored.metadata["obligation_type"] == "direct_human_request"
      assert stored.metadata["human_counterparty"] == true
      assert stored.metadata["missing_followthrough_evidence"] == true
      assert stored.metadata["interrupt_now"] == true
      assert stored.metadata["false_positive_risk"] == 0.12
      assert stored.metadata["reasoning_summary"] =~ "no reply evidence"
      assert stored.metadata["thread_type"] == "customer_work"
      assert stored.metadata["reply_obligation"] == true
      assert stored.metadata["importance"] == "important"
      assert stored.metadata["record"]["status"] == "unresolved"
      assert is_binary(stored.metadata["record"]["commitment"])
      assert stored.metadata["record"]["next_action"] =~ "Reply"

      assert stored.metadata["follow_up_ideas"] == [
               "Draft the reply with a clear owner and ETA.",
               "Flag any blockers before the next customer touchpoint."
             ]
    end

    test "does not fall back to heuristic candidates when llm output is invalid", %{
      user_id: user_id,
      context: context
    } do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-heuristic-fallback",
              "subject" => "Urgent follow-up needed",
              "snippet" => "Please respond today",
              "from" => "ops@example.com",
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      {:effect, {:llm_call, _params}, state_after_wakeup} =
        InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      assert state_after_wakeup.pending_candidates != []

      {:emit, {:insights_recorded, result}, final_state} =
        InboxCalendarAdvisor.handle_effect_result(
          {:llm_call, %{content: "not-json"}},
          state_after_wakeup,
          context
        )
        |> complete_relationship_learning(context)

      assert result.count == 0
      assert final_state.pending_candidates == []
      assert Insights.list_open_for_user(user_id) == []
    end

    test "drops llm items marked non-actionable", %{user_id: user_id, context: context} do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-receipt-no-action",
              "subject" => "Urgent follow-up needed",
              "snippet" => "Please respond today",
              "from" => "ops@example.com",
              "internal_date" => DateTime.utc_now()
            }
          ]
        }
      }

      {:effect, {:llm_call, _params}, state_after_wakeup} =
        InboxCalendarAdvisor.handle_wakeup(state, %{context | event: %{payload: payload}})

      dedupe_key = hd(state_after_wakeup.pending_candidates)["dedupe_key"]

      llm_response = %{
        content:
          Jason.encode!([
            %{
              "dedupe_key" => dedupe_key,
              "actionability" => "non_actionable",
              "confidence" => 0.95
            }
          ])
      }

      {:emit, {:insights_recorded, result}, final_state} =
        InboxCalendarAdvisor.handle_effect_result(
          {:llm_call, llm_response},
          state_after_wakeup,
          context
        )
        |> complete_relationship_learning(context)

      assert result.count == 0
      assert final_state.pending_candidates == []
      assert Insights.list_open_for_user(user_id) == []
    end

    test "checks off an existing Gmail todo when the latest sync finds a sent reply", %{
      user_id: user_id,
      agent: agent,
      context: context
    } do
      state = InboxCalendarAdvisor.init(%{"user_id" => user_id})

      occurred_at =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      reply_at = DateTime.add(occurred_at, 1800, :second)

      {:ok, [_insight]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply to billing about payment status",
            "summary" => "Billing asked for the payment status today.",
            "recommended_action" => "Reply in the source thread with the payment status.",
            "source_occurred_at" => occurred_at,
            "dedupe_key" => "gmail:thread:thread-billing-sync:reply_owed:v1",
            "tracking_key" => "gmail:thread:thread-billing-sync:reply_owed",
            "source_id" => "msg-billing-request"
          }
        ])

      [todo] = Todos.list_open_for_user(user_id)

      sent_reply = %{
        "message_id" => "msg-billing-reply",
        "thread_id" => "thread-billing-sync",
        "subject" => "Re: Payment status",
        "snippet" => "Sent the payment status and next step.",
        "from" => user_id,
        "to" => "billing@example.com",
        "internal_date" => reply_at
      }

      source_bundle =
        context
        |> SourceBundle.empty()
        |> SourceBundle.put_gmail(%{"sent_messages" => [sent_reply]})

      payload = %{
        "source" => "gmail",
        "data" => %{
          "messages" => [
            %{
              "message_id" => "msg-billing-request",
              "thread_id" => "thread-billing-sync",
              "subject" => "Payment status",
              "snippet" => "Can you please send the payment status today?",
              "from" => "Billing <billing@example.com>",
              "to" => user_id,
              "labels" => ["INBOX", "IMPORTANT"],
              "internal_date" => occurred_at
            }
          ]
        }
      }

      _result =
        InboxCalendarAdvisor.handle_wakeup(
          state,
          context
          |> Map.put(:source_bundle, source_bundle)
          |> Map.put(:event, %{payload: payload})
        )

      assert Insights.list_open_for_user(user_id) == []
      assert Todos.list_open_for_user(user_id) == []
      assert [done_todo | _] = Todos.list_recent_for_user(user_id)
      assert done_todo.id == todo.id
      assert done_todo.status == "done"
      assert get_in(done_todo.metadata, ["auto_resolution", "status"]) == "done"
    end

    test "persists heads_up Gmail insights when the LLM keeps interrupt_now false", %{
      user_id: user_id,
      context: context
    } do
      state =
        InboxCalendarAdvisor.init(%{"user_id" => user_id})
        |> Map.put(:pending_candidates, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Gmail thread moving with Charlie",
            "summary" =>
              "Charlie has already responded and the conversation is moving. You may still need to handle the remaining follow-through.",
            "recommended_action" =>
              "Monitor the thread and handle the remaining follow-through if the owner, artifact, or ETA is still yours.",
            "priority" => 82,
            "confidence" => 0.86,
            "dedupe_key" => "heads-up-gmail-1",
            "metadata" => %{
              "thread_type_hint" => "direct_human_request",
              "solicited_hint" => false,
              "prior_user_engagement" => false,
              "explicit_user_commitment" => false,
              "importance_hint" => "important",
              "reply_obligation_hint" => true,
              "evidence_for_reply_owed" => ["David asked for the update today."],
              "evidence_against_reply_owed" => [],
              "conversation_context" => %{
                "notification_posture" => "heads_up",
                "latest_actor" => "Charlie"
              },
              "record" => %{
                "commitment" => "Reply to David on Cowrie Agora Update",
                "person" => "David",
                "source" => "gmail_thread:thread-1",
                "status" => "unresolved",
                "evidence" => ["Charlie replied later in the conversation."],
                "next_action" =>
                  "Monitor the thread and handle the remaining follow-through if the owner, artifact, or ETA is still yours."
              }
            }
          }
        ])

      llm_response = %{
        content:
          Jason.encode!([
            %{
              "dedupe_key" => "heads-up-gmail-1",
              "title" => "Gmail thread moving with Charlie",
              "summary" =>
                "Charlie has already responded and the conversation is moving. You may still need to handle the remaining follow-through.",
              "recommended_action" =>
                "Monitor the thread and handle the remaining follow-through if the owner, artifact, or ETA is still yours.",
              "priority" => 82,
              "confidence" => 0.87,
              "telegram_fit_score" => 0.83,
              "telegram_fit_reason" =>
                "Still worth surfacing, but no longer an unattended thread.",
              "why_now" =>
                "Charlie has already responded and the conversation is moving. The final follow-through may still be yours.",
              "commitment" => "Reply to David on Cowrie Agora Update",
              "person" => "David",
              "source" => "gmail_thread:thread-1",
              "deadline" => Date.utc_today() |> Date.to_iso8601(),
              "status" => "unresolved",
              "evidence" => ["Charlie replied later in the conversation."],
              "next_action" =>
                "Monitor the thread and handle the remaining follow-through if the owner, artifact, or ETA is still yours.",
              "actionability" => "actionable",
              "obligation_type" => "direct_human_request",
              "human_counterparty" => true,
              "missing_followthrough_evidence" => true,
              "interrupt_now" => false,
              "notification_posture" => "heads_up",
              "thread_type" => "customer_work",
              "solicited" => false,
              "prior_user_engagement" => false,
              "explicit_user_commitment" => false,
              "reply_obligation" => true,
              "importance" => "important",
              "evidence_for_reply_owed" => ["David asked for the update today."],
              "evidence_against_reply_owed" => ["Charlie already replied in the thread."],
              "decision_reason" =>
                "The thread still matters, but another participant already replied so it should stay heads_up only.",
              "false_positive_risk" => 0.14,
              "reasoning_summary" =>
                "Another participant replied, so the thread is active even though the final close may still depend on you."
            }
          ])
      }

      {:emit, {:insights_recorded, result}, final_state} =
        InboxCalendarAdvisor.handle_effect_result({:llm_call, llm_response}, state, context)

      assert result.count == 1
      assert final_state.pending_candidates == []

      [stored | _] = Insights.list_open_for_user(user_id)
      assert stored.metadata["conversation_context"]["notification_posture"] == "heads_up"
      assert stored.metadata["interrupt_now"] == false
      assert stored.metadata["importance"] == "important"
      assert stored.summary =~ "conversation is moving"
    end

    test "rejects llm output that classifies a reply candidate as digest or non-obligatory", %{
      user_id: user_id,
      context: context
    } do
      state =
        InboxCalendarAdvisor.init(%{"user_id" => user_id})
        |> Map.put(:pending_candidates, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply owed: Quick follow-up",
            "summary" => "This might be a reply debt, but the thread looks like outreach.",
            "recommended_action" => "Review before replying.",
            "priority" => 80,
            "confidence" => 0.84,
            "dedupe_key" => "cold-outreach-digest-1",
            "metadata" => %{
              "thread_type_hint" => "cold_sales_outreach",
              "solicited_hint" => false,
              "prior_user_engagement" => false,
              "explicit_user_commitment" => false,
              "importance_hint" => "digest",
              "reply_obligation_hint" => false,
              "evidence_for_reply_owed" => ["A real person followed up."],
              "evidence_against_reply_owed" => [
                "No self-authored message appears earlier in the thread.",
                "Cold outreach indicators: calendly."
              ],
              "record" => %{
                "commitment" => "Reply to seller@example.com on Quick follow-up",
                "person" => "seller@example.com",
                "source" => "gmail_thread:msg-cold-like",
                "status" => "unresolved",
                "evidence" => ["Cold outreach indicators: calendly."],
                "next_action" => "Review before replying."
              }
            }
          }
        ])

      llm_response = %{
        content:
          Jason.encode!([
            %{
              "dedupe_key" => "cold-outreach-digest-1",
              "title" => "Possible follow-up",
              "summary" => "This looks like outreach and should not interrupt.",
              "recommended_action" => "No action needed.",
              "priority" => 80,
              "confidence" => 0.9,
              "actionability" => "actionable",
              "obligation_type" => "sales_outreach",
              "human_counterparty" => true,
              "missing_followthrough_evidence" => true,
              "interrupt_now" => false,
              "notification_posture" => "heads_up",
              "thread_type" => "cold_sales_outreach",
              "solicited" => false,
              "prior_user_engagement" => false,
              "explicit_user_commitment" => false,
              "reply_obligation" => false,
              "importance" => "digest",
              "evidence_for_reply_owed" => ["A real person followed up."],
              "evidence_against_reply_owed" => [
                "No self-authored message appears earlier in the thread.",
                "Cold outreach indicators: calendly."
              ],
              "decision_reason" => "This is cold outreach, not a real reply obligation.",
              "false_positive_risk" => 0.2
            }
          ])
      }

      {:emit, {:insights_recorded, result}, final_state} =
        InboxCalendarAdvisor.handle_effect_result({:llm_call, llm_response}, state, context)

      assert result.count == 0
      assert final_state.pending_candidates == []
      assert Insights.list_open_for_user(user_id) == []
    end
  end

  defp complete_relationship_learning({:effect, {:llm_call, _params}, state}, context) do
    InboxCalendarAdvisor.handle_effect_result(
      {:llm_call,
       %{
         content:
           Jason.encode!(%{
             "summary" => "No durable relationship context from this fixture.",
             "people" => [],
             "memories" => [],
             "links" => []
           })
       }},
      state,
      context
    )
  end

  defp complete_relationship_learning(result, _context), do: result

  defp gmail_thread_message(id, thread_id, from, to, subject, snippet, occurred_at) do
    %{
      "id" => id,
      "threadId" => thread_id,
      "snippet" => snippet,
      "internalDate" => occurred_at |> DateTime.to_unix(:millisecond) |> Integer.to_string(),
      "payload" => %{
        "headers" => [
          %{"name" => "From", "value" => from},
          %{"name" => "To", "value" => to},
          %{"name" => "Subject", "value" => subject}
        ]
      }
    }
  end
end
