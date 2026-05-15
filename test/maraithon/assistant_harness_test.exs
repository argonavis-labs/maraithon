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
      assert prompt =~ "Available tools JSON"

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
