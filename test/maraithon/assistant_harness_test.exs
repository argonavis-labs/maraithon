defmodule Maraithon.AssistantHarnessTest do
  use ExUnit.Case, async: true

  alias Maraithon.AssistantHarness

  describe "guard_tool_history/2 classification" do
    setup do
      test_pid = self()
      handler_id = "loop-classification-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:maraithon, :assistant_harness, :tool_loop],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:tool_loop, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "classifies a same-tool/same-args/same-outcome repeat as same_tool_args" do
      history =
        for _ <- 1..3 do
          %{
            "tool" => "list_todos",
            "arguments" => %{"limit" => 5},
            "result" => %{"todos" => []}
          }
        end

      assert {:error,
              {:assistant_harness_tool_loop_detected, "list_todos", 3, "same_tool_args", _}} =
               AssistantHarness.guard_tool_history(history)

      assert_receive {:tool_loop, %{count: 3},
                      %{tool: "list_todos", classification: "same_tool_args"}}
    end

    test "classifies an A→B→A→B alternation as ping_pong" do
      history = [
        %{"tool" => "list_todos", "arguments" => %{}, "result" => %{"todos" => []}},
        %{"tool" => "get_open_loops", "arguments" => %{}, "result" => %{"buckets" => %{}}},
        %{"tool" => "list_todos", "arguments" => %{}, "result" => %{"todos" => []}},
        %{"tool" => "get_open_loops", "arguments" => %{}, "result" => %{"buckets" => %{}}},
        %{"tool" => "list_todos", "arguments" => %{}, "result" => %{"todos" => []}}
      ]

      assert {:error, {:assistant_harness_tool_loop_detected, "list_todos", _, "ping_pong", _}} =
               AssistantHarness.guard_tool_history(history)

      assert_receive {:tool_loop, _, %{classification: "ping_pong"}}
    end

    test "classifies same-outcome with varying args as poll_no_progress" do
      outcome = %{"status" => "pending"}

      history = [
        %{"tool" => "get_status", "arguments" => %{"id" => 1}, "result" => outcome},
        %{"tool" => "get_status", "arguments" => %{"id" => 2}, "result" => outcome},
        %{"tool" => "get_status", "arguments" => %{"id" => 3}, "result" => outcome}
      ]

      assert {:error, _} = AssistantHarness.guard_tool_history(history)
      assert_receive {:tool_loop, _, %{classification: "polling_no_progress"}}
    end
  end

  test "exposes the executable runtime contract used by the loop" do
    policy = AssistantHarness.runtime_policy(max_llm_turns: 8, max_tool_steps: 12)

    assert policy.contract_version == 2
    assert policy.loop.max_llm_turns == 8
    assert policy.loop.max_tool_steps == 12
    assert policy.loop.max_wall_clock_ms > 0
    assert policy.tool_calls.max_per_step == 3
    assert policy.tool_calls.repeat_guard.window_size == 3
    assert policy.tool_evidence.history_limit == 12
    assert policy.model_failover.enabled == false
    assert "invalid_json" in policy.model_failover.retryable_errors
    assert "tool_calls" in policy.model_decision_contract.statuses
    assert "todo_digest" in policy.model_decision_contract.message_classes

    failover_policy = AssistantHarness.runtime_policy(model_fallbacks: ["fallback-model"])
    assert failover_policy.model_failover.enabled == true
    # max_attempts is the configured ceiling (default 3) — used as a retry
    # budget for same-model retries on transient errors as well as for fallbacks.
    assert failover_policy.model_failover.max_attempts == 3
  end

  test "failure messages preserve context instead of handing work back to the user" do
    disallowed = [
      "internal issue",
      "ran out of time",
      "try again",
      "ask me for a narrower",
      "taking longer than it should",
      "model",
      "llm",
      "reasoning",
      "tool",
      "budget",
      "run context",
      "same_tool_args"
    ]

    messages = [
      AssistantHarness.failure_message(:timeout),
      AssistantHarness.failure_message(:llm_turn_limit),
      AssistantHarness.failure_message(:tool_step_limit),
      AssistantHarness.failure_message({:llm_busy, 1_000}),
      AssistantHarness.failure_message({:assistant_harness_tool_loop_detected, "list_todos", 3}),
      AssistantHarness.failure_message(
        {:assistant_harness_tool_loop_detected, "get_open_loops", 3}
      ),
      AssistantHarness.failure_message(
        {:assistant_harness_tool_loop_detected, "not_real_tool", 3}
      ),
      AssistantHarness.failure_message(
        {:assistant_harness_tool_loop_detected, "list_todos", 3, "same_tool_args", %{}}
      ),
      AssistantHarness.failure_message(:unexpected)
    ]

    assert Enum.all?(messages, &String.contains?(&1, "saved"))
    assert Enum.all?(messages, &String.starts_with?(&1, "Maraithon saved"))

    refute Enum.any?(messages, fn message ->
             normalized = String.downcase(message)
             Enum.any?(disallowed, &String.contains?(normalized, &1))
           end)

    refute Enum.any?(messages, &String.contains?(&1, "I "))
    refute Enum.any?(messages, &String.contains?(&1, "partial evidence"))
    assert Enum.any?(messages, &String.contains?(&1, "open work"))
  end

  test "builds model requests with runtime policy instead of prompt text alone" do
    request =
      AssistantHarness.build_step_request(payload("What should I review?"),
        max_tokens: 900,
        reasoning_effort: "high"
      )

    assert request["max_tokens"] == 900
    assert request["reasoning_effort"] == "high"
    assert [%{"role" => "system"}, %{"role" => "user", "content" => prompt}] = request["messages"]
    assert prompt =~ "Runtime policy JSON"
    assert prompt =~ "\"contract_version\":2"
    assert prompt =~ "draft_message"
    assert prompt =~ "Do not use em dashes"
  end

  test "prompts enforce product language while preserving internal work-item contracts" do
    request = AssistantHarness.build_step_request(payload("What should I review?"))
    proactive_request = AssistantHarness.build_proactive_request(%{context: %{}})

    assert [%{"role" => "system", "content" => system}, %{"role" => "user", "content" => prompt}] =
             request["messages"]

    proactive_prompt = get_in(proactive_request, ["messages", Access.at(1), "content"])

    assert system =~ "durable work state lives in open work, projects, People, and deep memory"
    assert prompt =~ "Use product language in final text"
    assert prompt =~ "say `open work`, `work item`, `People`, or `relationship context`"
    assert prompt =~ "do not say `todo` or `CRM` unless quoting the operator"
    assert prompt =~ "Never reveal, quote, transform, summarize, or display API keys"

    assert prompt =~
             "Persist actionable work as durable work items through the internal todo tools"

    assert prompt =~ "People is the durable relationship layer"
    assert prompt =~ "what is known versus uncertain"
    assert prompt =~ "what is known versus still uncertain"
    assert prompt =~ "Do not stop at a contact label"
    assert prompt =~ "identity, company or project, why they are in view now, what you owe next"
    assert prompt =~ "message_class:\"todo_digest\""
    assert prompt =~ "state how the open work is ranked and what to start with"
    assert prompt =~ "orient the operator, not dump a second list"
    assert prompt =~ "After `create_scheduled_task` succeeds"
    assert prompt =~ "confirm the schedule, review scope, delivery expectation"
    assert proactive_prompt =~ "Reason over open work, open loops"
    assert proactive_prompt =~ "People relationship context"
    assert proactive_prompt =~ "work item cards from the listed todo_ids"
    assert proactive_prompt =~ "from the personal calendar"

    refute system =~ "control agents"
    refute system =~ "lives in todos, projects, CRM"
    refute prompt =~ "The built-in CRM is the durable relationship layer"
    refute prompt =~ "Persist actionable work as todos."
    refute prompt =~ "generic CRM labels"
    refute prompt =~ "I don't have Charlie in your CRM"
    refute prompt =~ "and confidence"
    refute prompt =~ "how confident you are"
    refute proactive_prompt =~ "kent.fenwick"
  end

  test "uses chat-tier models for proactive planning requests" do
    proactive_request =
      AssistantHarness.build_proactive_request(%{context: %{}}, chat_model: "chat-tier")

    delivery_request =
      AssistantHarness.build_delivery_plan_request(%{context: %{}, candidates: []},
        chat_model: "chat-tier"
      )

    override_request =
      AssistantHarness.build_proactive_request(%{context: %{}},
        chat_model: "chat-tier",
        proactive_model: "proactive-tier"
      )

    assert proactive_request["model"] == "chat-tier"
    assert delivery_request["model"] == "chat-tier"
    assert override_request["model"] == "proactive-tier"
  end

  test "proactive prompts encode backlog, weekend, and attention-stack policy" do
    proactive_request =
      AssistantHarness.build_proactive_request(%{
        trigger: %{"local_time" => %{"weekday" => "Saturday", "day_phase" => "evening"}},
        context: %{
          todos: [
            %{
              id: "todo-1",
              title: "Old Dan follow-up",
              attention_profile: %{stale_confirmation_candidate: true}
            }
          ]
        },
        recent_pushes: []
      })

    delivery_request =
      AssistantHarness.build_delivery_plan_request(%{
        candidates: [
          %{
            id: "candidate-1",
            planning_rank: 1,
            attention_profile: %{bucket: "personal_family"}
          }
        ],
        context: %{},
        recent_pushes: []
      })

    proactive_prompt = get_in(proactive_request, ["messages", Access.at(1), "content"])
    delivery_prompt = get_in(delivery_request, ["messages", Access.at(1), "content"])

    assert proactive_prompt =~ "Morning check-ins may include older backlog"
    assert proactive_prompt =~ "Highest attention order"
    assert proactive_prompt =~ "On weekends, personal and family items outrank routine work"
    assert proactive_prompt =~ "Is this still important to handle?"
    assert proactive_prompt =~ "private 10/10 verification loop"

    assert delivery_prompt =~ "pre-ranked with attention_profile hints"
    assert delivery_prompt =~ "old backlog during daytime/evening cycles"
    assert delivery_prompt =~ "allow at most one confirmation-style digest card"
  end

  test "builds loop request payloads with compact tool evidence" do
    state = %{
      iteration: 2,
      llm_turns: 1,
      tool_steps: 1,
      tool_history: [
        %{
          "tool" => "gmail_get_message",
          "arguments" => %{"id" => "msg-1"},
          "result" => %{"message" => %{"text_body" => String.duplicate("A", 80)}}
        }
      ]
    }

    payload =
      AssistantHarness.build_loop_request_payload(
        %{context: %{chat: %{id: "123"}}, tools: [%{"name" => "gmail_get_message"}]},
        state,
        tool_result_string_chars: 24
      )

    assert payload.iteration == 2
    assert [%{"result" => %{"message" => %{"text_body" => compacted}}}] = payload.tool_history
    assert compacted =~ "[truncated]"
    assert String.length(compacted) < 50
  end

  test "focuses connector-status turns on the current request and connection tools" do
    payload =
      AssistantHarness.build_loop_request_payload(
        %{
          context: %{
            user: %{id: "kent@example.com"},
            chat: %{id: "123"},
            recent_turns: [
              %{role: "assistant", text: "Earlier todo answer"},
              %{
                role: "user",
                text: "Which connections are currently connected?",
                turn_kind: "assistant_request",
                origin_type: "telegram"
              }
            ],
            connected_accounts: [%{provider: "telegram", status: "connected"}],
            source_freshness: [%{provider: "telegram", status: "fresh"}],
            defaults: %{
              default_slack_team_id: "TSECRET123",
              slack_team_ids: ["TSECRET123"],
              provider_ids: ["slack:TSECRET123:user:USECRET", "google"],
              providers: ["slack:TSECRET123", "google"],
              linear_connected: false
            },
            todos: [%{title: "Unrelated todo"}],
            relationships: [%{name: "Unrelated person"}]
          },
          tools: [
            %{"name" => "list_connected_accounts"},
            %{"name" => "upsert_todos"},
            %{"name" => "list_people"}
          ]
        },
        AssistantHarness.initial_loop_state(),
        request_focus: :connector_status,
        context_scope: :connector_status,
        tool_scope: :connector_status
      )

    assert payload.current_user_request.text == "Which connections are currently connected?"
    assert payload.request_focus == "connector_status"
    assert Map.has_key?(payload.context, :connected_accounts)
    assert Map.has_key?(payload.context, :source_freshness)
    refute Map.has_key?(payload.context, :todos)
    refute Map.has_key?(payload.context, :relationships)
    assert payload.context.defaults.providers == ["google", "slack"]
    refute Map.has_key?(payload.context.defaults, :default_slack_team_id)
    refute Map.has_key?(payload.context.defaults, :slack_team_ids)
    refute Map.has_key?(payload.context.defaults, :provider_ids)
    assert [%{"name" => "list_connected_accounts"}] = payload.tools

    prompt = AssistantHarness.build_prompt(payload)
    assert prompt =~ "Current user request JSON"
    assert prompt =~ "Which connections are currently connected?"
    assert prompt =~ "Request focus JSON"
    refute prompt =~ "TSECRET123"
    refute prompt =~ "USECRET"
  end

  test "prioritizes calendar-by-person for focused meeting prep" do
    payload =
      AssistantHarness.build_loop_request_payload(
        %{
          context: %{
            recent_turns: [
              %{
                role: "user",
                text: "What should I know before my meeting with Matthew tomorrow?"
              }
            ]
          },
          tools: [
            %{"name" => "list_todos"},
            %{"name" => "calendar_events_around"},
            %{"name" => "review_connected_context"},
            %{"name" => "calendar_events_for_person"},
            %{"name" => "get_open_loops"},
            %{"name" => "get_relationship_context"}
          ]
        },
        AssistantHarness.initial_loop_state(),
        request_focus: :meeting_prep,
        context_scope: :meeting_prep,
        tool_scope: :meeting_prep
      )

    names = Enum.map(payload.tools, & &1["name"])

    assert Enum.take(names, 3) == [
             "calendar_events_for_person",
             "get_relationship_context",
             "review_connected_context"
           ]

    prompt = AssistantHarness.build_prompt(payload)
    assert prompt =~ "call `calendar_events_for_person` first"
  end

  test "linked todo prompt contract uses exact id deletion for dismissal replies" do
    payload =
      AssistantHarness.build_loop_request_payload(
        %{
          context: %{
            linked_item: %{
              todo: %{id: "todo_123", title: "Check Matthew setup pricing"}
            },
            recent_turns: [
              %{role: "user", text: "Dismiss this todo as no longer relevant"}
            ]
          },
          tools: [
            %{"name" => "list_todos"},
            %{"name" => "resolve_todo"},
            %{"name" => "delete_todo"}
          ]
        },
        AssistantHarness.initial_loop_state(),
        request_focus: :linked_item_context,
        context_scope: :linked_item_context,
        tool_scope: :linked_item_context
      )

    assert Enum.map(payload.tools, & &1["name"]) == [
             "list_todos",
             "resolve_todo",
             "delete_todo"
           ]

    prompt = AssistantHarness.build_prompt(payload)
    assert prompt =~ "dismiss/delete/remove/no-longer-relevant -> `delete_todo`"
    assert prompt =~ "with `todo_id:\"todo_123\"`, not `list_todos` or `resolve_todo`"
  end

  test "guard_loop owns timeout and loop budget decisions" do
    assert :ok =
             AssistantHarness.guard_loop(
               %{llm_turns: 1, tool_steps: 1},
               1_000,
               now_monotonic_ms: 1_100,
               max_wall_clock_ms: 1_000
             )

    assert {:error, :timeout} =
             AssistantHarness.guard_loop(
               %{llm_turns: 1, tool_steps: 1},
               1_000,
               now_monotonic_ms: 2_000,
               max_wall_clock_ms: 1_000
             )

    assert {:error, :llm_turn_limit} =
             AssistantHarness.guard_loop(
               %{llm_turns: 6, tool_steps: 1},
               1_000,
               now_monotonic_ms: 1_100
             )
  end

  test "guard_tool_history stops repeated identical tool-result loops" do
    entry = %{
      "tool" => "gmail_search_messages",
      "arguments" => %{"query" => "Charlie"},
      "result" => %{"messages" => []}
    }

    assert :ok = AssistantHarness.guard_tool_history([entry, entry], tool_repeat_guard_window: 3)

    assert {:error,
            {:assistant_harness_tool_loop_detected, "gmail_search_messages", 3, "same_tool_args",
             _}} =
             AssistantHarness.guard_tool_history([entry, entry, entry],
               tool_repeat_guard_window: 3
             )
  end

  test "execution evidence keeps audit context compact" do
    evidence =
      AssistantHarness.execution_evidence(
        [
          %{
            "tool" => "gmail_get_message",
            "arguments" => %{"id" => "msg-1"},
            "result" => %{"body" => String.duplicate("body ", 100)}
          }
        ],
        tool_result_string_chars: 32
      )

    assert [%{"result" => %{"body" => body}}] = evidence
    assert body =~ "[truncated]"
    assert String.length(body) < 60
  end

  test "uses the model response to choose tools instead of local keyword routing" do
    llm_complete = fn params ->
      prompt = get_in(params, ["messages", Access.at(1), "content"])

      assert prompt =~ "What are the emails to triage today?"
      assert prompt =~ "Decision contract:"
      assert prompt =~ "Do not rely on keyword heuristics"
      assert prompt =~ "Available actions JSON"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{"tool" => "get_open_work_summary", "arguments" => %{"limit" => 5}}
             ],
             "summary" => "Model decided source health is needed first."
           })
       }}
    end

    assert {:ok, response} =
             AssistantHarness.next_step(payload("What are the emails to triage today?"),
               llm_complete: llm_complete
             )

    assert response["status"] == "tool_calls"

    assert response["tool_calls"] == [
             %{"tool" => "get_open_work_summary", "arguments" => %{"limit" => 5}}
           ]
  end

  test "normalizes provider-style tool names and JSON encoded arguments like OpenClaw" do
    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{
                 "name" => "functions.gmail.search.messages:0",
                 "input" => Jason.encode!(%{"query" => "Charlie", "newer_than" => "30d"})
               }
             ],
             "summary" => "Search connected email before answering."
           })
       }}
    end

    assert {:ok, response} =
             AssistantHarness.next_step(
               %{
                 context: %{},
                 tools: [%{"name" => "gmail_search_messages"}],
                 tool_history: []
               },
               llm_complete: llm_complete
             )

    assert response["tool_calls"] == [
             %{
               "tool" => "gmail_search_messages",
               "arguments" => %{"query" => "Charlie", "newer_than" => "30d"}
             }
           ]
  end

  test "rejects invalid model output instead of using a semantic fallback" do
    llm_complete = fn _params -> {:ok, %{content: "not json"}} end

    assert {:error, :assistant_harness_invalid_json} =
             AssistantHarness.next_step(payload("What should I review?"),
               llm_complete: llm_complete
             )
  end

  test "retries retryable model failures with configured fallback models" do
    parent = self()

    llm_complete = fn params ->
      send(parent, {:attempted_model, params["model"]})

      case params["model"] do
        "fallback-model" ->
          {:ok,
           %{
             content:
               Jason.encode!(%{
                 "status" => "final",
                 "assistant_message" => "I checked it from the fallback model.",
                 "message_class" => "assistant_reply",
                 "tool_calls" => [],
                 "summary" => "Fallback model completed the turn."
               })
           }}

        _primary ->
          {:error, :timeout}
      end
    end

    assert {:ok, response} =
             AssistantHarness.next_step(payload("What should I review?"),
               llm_complete: llm_complete,
               model_fallbacks: ["fallback-model"]
             )

    assert response["assistant_message"] == "I checked it from the fallback model."
    assert_receive {:attempted_model, primary} when primary != "fallback-model"
    assert_receive {:attempted_model, "fallback-model"}
  end

  test "retries invalid JSON with a configured fallback model instead of guessing" do
    parent = self()

    llm_complete = fn params ->
      send(parent, {:attempted_model, params["model"]})

      case params["model"] do
        "fallback-model" ->
          {:ok,
           %{
             content:
               Jason.encode!(%{
                 "status" => "final",
                 "assistant_message" => "The fallback model returned valid JSON.",
                 "message_class" => "assistant_reply",
                 "tool_calls" => [],
                 "summary" => "Format failover completed the turn."
               })
           }}

        _primary ->
          {:ok, %{content: "not json"}}
      end
    end

    assert {:ok, response} =
             AssistantHarness.next_step(payload("What should I review?"),
               llm_complete: llm_complete,
               model_fallbacks: ["fallback-model"]
             )

    assert response["assistant_message"] == "The fallback model returned valid JSON."
    assert_receive {:attempted_model, primary} when primary != "fallback-model"
    assert_receive {:attempted_model, "fallback-model"}
  end

  test "rejects model-selected tools outside the available tool contract" do
    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{"tool" => "unknown_tool", "arguments" => %{}}
             ],
             "summary" => "Bad tool."
           })
       }}
    end

    assert {:error, {:assistant_harness_unknown_tool, "unknown_tool"}} =
             AssistantHarness.next_step(payload("Do something"), llm_complete: llm_complete)
  end

  test "rejects too many model-selected tool calls instead of silently truncating" do
    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" =>
               for index <- 1..4 do
                 %{"tool" => "list_todos", "arguments" => %{"limit" => index}}
               end,
             "summary" => "Too much."
           })
       }}
    end

    assert {:error, {:assistant_harness_too_many_tool_calls, 4, 3}} =
             AssistantHarness.next_step(payload("Do something"), llm_complete: llm_complete)
  end

  test "uses the model response for proactive send versus hold decisions" do
    llm_complete = fn params ->
      prompt = get_in(params, ["messages", Access.at(1), "content"])

      assert prompt =~ "Proactive decision contract:"
      assert prompt =~ "Recent proactive push receipts JSON"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decision" => "send_now",
             "assistant_message" => "Rippling still needs an eligibility reply today.",
             "message_class" => "assistant_push",
             "urgency" => 0.91,
             "interrupt_now" => true,
             "dedupe_key" => "proactive:rippling:2026-05-09",
             "todo_ids" => ["todo-1"],
             "summary" => "A high-priority open loop is timely."
           })
       }}
    end

    assert {:ok, plan} =
             AssistantHarness.proactive_plan(
               %{
                 trigger: %{"type" => "scheduled_check_in"},
                 context: %{open_loops: %{totals: %{open_todos: 1}}},
                 recent_pushes: []
               },
               llm_complete: llm_complete
             )

    assert plan["decision"] == "send_now"
    assert plan["assistant_message"] =~ "Rippling"
    assert plan["urgency"] == 0.91
    assert plan["todo_ids"] == ["todo-1"]
  end

  test "rejects proactive send decisions without a message" do
    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decision" => "send_now",
             "assistant_message" => "",
             "message_class" => "assistant_push",
             "summary" => "Bad proactive payload."
           })
       }}
    end

    assert {:error, :assistant_harness_empty_message} =
             AssistantHarness.proactive_plan(%{context: %{}}, llm_complete: llm_complete)
  end

  test "plan_delivery normalizes model dispositions" do
    llm_complete = fn params ->
      prompt = get_in(params, ["messages", Access.at(1), "content"])

      assert prompt =~ "Delivery planning contract:"
      assert prompt =~ "candidate-1"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "dispositions" => [
               %{
                 "candidate_id" => "candidate-1",
                 "disposition" => "interrupt_now",
                 "reason" => "The escalation is time-sensitive."
               },
               %{
                 "candidate_id" => "candidate-2",
                 "disposition" => "digest",
                 "reason" => "Useful, but it can be batched."
               },
               %{
                 "candidate_id" => "candidate-3",
                 "disposition" => "hold",
                 "reason" => "Not worth interrupting right now."
               }
             ],
             "digest_intro" => "A couple of useful things can wait for one digest.",
             "summary" => "One interrupt, one digest item, one hold."
           })
       }}
    end

    assert {:ok, plan} =
             AssistantHarness.plan_delivery(
               %{
                 candidates: [
                   %{"id" => "candidate-1", "title" => "Customer escalation"},
                   %{"id" => "candidate-2", "title" => "Follow-up digest"},
                   %{"id" => "candidate-3", "title" => "Low-signal FYI"}
                 ],
                 context: %{},
                 recent_pushes: []
               },
               llm_complete: llm_complete
             )

    assert Enum.map(plan["dispositions"], & &1["disposition"]) == [
             "interrupt_now",
             "digest",
             "hold"
           ]

    assert plan["digest_intro"] =~ "digest"
    assert plan["summary"] == "One interrupt, one digest item, one hold."
  end

  test "plan_delivery rejects unknown dispositions" do
    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "dispositions" => [
               %{
                 "candidate_id" => "candidate-1",
                 "disposition" => "send_later",
                 "reason" => "Invalid disposition."
               }
             ],
             "digest_intro" => "",
             "summary" => "Invalid plan."
           })
       }}
    end

    assert {:error, :assistant_harness_invalid_disposition} =
             AssistantHarness.plan_delivery(
               %{candidates: [%{"id" => "candidate-1"}], context: %{}, recent_pushes: []},
               llm_complete: llm_complete
             )
  end

  test "next_step retries same-model on a transient malformed-decision error" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    llm_complete = fn _params ->
      n = Agent.get_and_update(calls, fn count -> {count + 1, count + 1} end)

      # First call simulates the production bug: status:"tool_calls" with an
      # empty array. Used to fail fatally as :assistant_harness_empty_tool_calls.
      # Subsequent calls return a clean final response.
      if n == 1 do
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "status" => "tool_calls",
               "tool_calls" => [],
               "assistant_message" => "",
               "message_class" => "assistant_reply",
               "summary" => ""
             })
         }}
      else
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "status" => "final",
               "assistant_message" => "Recovered on retry.",
               "message_class" => "assistant_reply",
               "tool_calls" => [],
               "summary" => "retry"
             })
         }}
      end
    end

    assert {:ok, response} =
             AssistantHarness.next_step(payload("retry me"), llm_complete: llm_complete)

    assert response["status"] == "final"
    assert response["assistant_message"] == "Recovered on retry."
    # Verifies the retry budget was actually exercised on a normalize-stage error.
    assert Agent.get(calls, & &1) == 2
  end

  defp payload(message) do
    %{
      context: %{
        "recent_turns" => [
          %{"role" => "assistant", "text" => "Earlier reply"},
          %{"role" => "user", "text" => message}
        ]
      },
      tools: [%{"name" => "get_open_work_summary"}, %{"name" => "list_todos"}],
      tool_history: []
    }
  end
end
