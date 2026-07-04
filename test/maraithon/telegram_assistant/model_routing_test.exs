defmodule Maraithon.TelegramAssistant.ModelRoutingTest do
  use ExUnit.Case, async: false

  alias Maraithon.TelegramAssistant.ModelRouting

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.merge(original_runtime,
        llm_provider_name: "openai",
        llm_model: "reasoning-tier",
        llm_chat_model: "chat-tier",
        openai_reasoning_effort: "high"
      )
    )

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        chat_reasoning_effort: "low",
        reasoning_max_tokens: 6_000
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
    end)

    :ok
  end

  test "keeps ordinary connected-source chat on the chat tier" do
    profile = ModelRouting.profile_for(%{text: "Who is Charlie from Slack?"})

    assert profile.tier == :chat
    assert profile.model == "chat-tier"
    assert profile.reasoning_effort == "low"
    assert profile.task_class == :source_hint_identity
    assert profile.route_reason == "bounded_source_hint_identity_chat"
    assert profile.max_tokens == nil
    assert Keyword.fetch!(profile.llm_opts, :chat_model) == "chat-tier"
  end

  test "keeps connector status on the chat tier with focused context and tools" do
    :maraithon
    |> Application.get_env(:telegram_assistant, [])
    |> Keyword.delete(:chat_reasoning_effort)
    |> then(&Application.put_env(:maraithon, :telegram_assistant, &1))

    profile = ModelRouting.profile_for(%{text: "Which connections are active?"})

    assert profile.tier == :chat
    assert profile.request_focus == :connector_status
    assert profile.task_class == :connector_status
    assert profile.route_reason == "connector_status_focus"
    assert profile.model == "chat-tier"
    assert profile.reasoning_effort == "none"
    assert Keyword.fetch!(profile.llm_opts, :request_focus) == :connector_status
    assert Keyword.fetch!(profile.llm_opts, :context_scope) == :connector_status
    assert Keyword.fetch!(profile.llm_opts, :tool_scope) == :connector_status
    assert Keyword.fetch!(profile.llm_opts, :max_tokens) == 700
    assert Keyword.fetch!(profile.llm_opts, :max_wall_clock_ms) == 15_000
  end

  test "routes 'what can you see' with a source/connector anchor to connector_status" do
    profile = ModelRouting.profile_for(%{text: "what sources can you see right now?"})

    assert profile.request_focus == :connector_status
    assert profile.task_class == :connector_status
    assert profile.route_reason == "connector_status_focus"
  end

  test "does not misroute an unrelated 'what can you see' ask into connector_status" do
    profile = ModelRouting.profile_for(%{text: "what can you see for tomorrow's meetings?"})

    refute profile.request_focus == :connector_status
    refute profile.task_class == :connector_status
  end

  test "routes broad planning and todo-review asks to the reasoning tier" do
    for text <- [
          "What should I do next?",
          "What todos need my attention?",
          "Give me the full detail of my todos.",
          "Please triage my todos.",
          "Prioritize my open loops."
        ] do
      profile = ModelRouting.profile_for(%{text: text})

      assert profile.tier == :reasoning
      assert profile.model == "reasoning-tier"
      assert profile.reasoning_effort == "high"

      assert profile.route_reason in [
               "today_mode_or_attention_request",
               "planning_source_or_open_loop_analysis"
             ]

      assert profile.max_tokens == 6_000
      assert Keyword.fetch!(profile.llm_opts, :chat_model) == "reasoning-tier"
    end
  end

  test "routes morning briefing requests to the reasoning tier" do
    profile = ModelRouting.profile_for(%{text: "Can you send me a morning briefing?"})

    assert profile.tier == :reasoning
    assert profile.task_class == :planning
    assert profile.model == "reasoning-tier"
    assert profile.reasoning_effort == "high"
  end

  test "routes meeting prep with focused reasoning budgets" do
    profile = ModelRouting.profile_for(%{text: "What should I know before my meeting?"})

    assert profile.tier == :reasoning
    assert profile.request_focus == :meeting_prep
    assert profile.task_class == :meeting_prep
    assert profile.route_reason == "meeting_prep_requires_context"
    assert Keyword.fetch!(profile.llm_opts, :tool_scope) == :meeting_prep
    assert Keyword.fetch!(profile.llm_opts, :max_tool_steps) == 12
  end

  test "routes linked todo action replies through linked item context" do
    profile =
      ModelRouting.profile_for(%{
        text: "Dismiss this todo as no longer relevant.",
        reply_to_message_id: "todo-card-1"
      })

    assert profile.request_focus == :linked_item_context
    assert profile.task_class == :linked_item_context
    assert profile.route_reason == "reply_to_linked_item_context"
    assert Keyword.fetch!(profile.llm_opts, :context_scope) == :linked_item_context
    assert Keyword.fetch!(profile.llm_opts, :tool_scope) == :linked_item_context
  end

  test "routes waiting and owe questions through open-loop analysis" do
    for text <- ["Who am I waiting on?", "What do I owe other people right now?"] do
      profile = ModelRouting.profile_for(%{text: text})

      assert profile.tier == :reasoning
      assert profile.request_focus == :waiting_on
      assert profile.task_class == :waiting_on
      assert profile.route_reason == "waiting_on_or_commitment_analysis"
      assert Keyword.fetch!(profile.llm_opts, :tool_scope) == :waiting_on
      assert Keyword.fetch!(profile.llm_opts, :max_tool_steps) == 12
    end
  end

  test "keeps trivial prompts on chat while exposing route metadata" do
    profile = ModelRouting.profile_for(%{text: "What is 2+2?"})

    assert profile.tier == :chat
    assert profile.task_class == :simple_answer
    assert profile.route_reason == "default_fast_chat_tier"
    assert profile.reasoning_effort == "low"
  end

  test "routes light conversational turns to the fast tier" do
    :maraithon
    |> Application.get_env(Maraithon.Runtime, [])
    |> Keyword.put(:llm_fast_model, "fast-tier")
    |> then(&Application.put_env(:maraithon, Maraithon.Runtime, &1))

    for text <- ["Perfect, thanks so much!", "sounds good, will do", "love it"] do
      profile = ModelRouting.profile_for(%{text: text})

      assert profile.tier == :fast
      assert profile.model == "fast-tier"
      assert profile.task_class == :light_chat
      assert profile.route_reason == "light_conversational_turn_fast_tier"
      assert Keyword.fetch!(profile.llm_opts, :max_tool_steps) == 2
    end
  end

  test "fast tier falls back to the chat model when no fast model is configured" do
    profile = ModelRouting.profile_for(%{text: "thanks!"})

    assert profile.tier == :fast
    assert profile.model == "chat-tier"
  end

  test "keeps action-bearing short messages off the fast tier" do
    for text <- ["ok cancel my 3pm", "thanks, now archive that email", "yes delete it"] do
      profile = ModelRouting.profile_for(%{text: text})

      refute profile.tier == :fast
    end
  end

  test "routes quick wording asks to the fast tier with quick chat focus" do
    profile = ModelRouting.profile_for(%{text: "Rewrite this to sound friendlier"})

    assert profile.tier == :fast
    assert profile.request_focus == :quick_chat
    assert Keyword.fetch!(profile.llm_opts, :tool_scope) == :quick_chat
  end

  test "escalates a fast profile to the reasoning tier" do
    profile = ModelRouting.profile_for(%{text: "thanks!"})
    escalated = ModelRouting.escalated_profile_for(profile)

    assert escalated.tier == :reasoning
    assert escalated.model == "reasoning-tier"
    assert escalated.route_reason == "escalated_to_reasoning:light_conversational_turn_fast_tier"
  end

  test "preserves route metadata when escalating a chat profile" do
    profile = ModelRouting.profile_for(%{text: "What is 2+2?"})
    escalated = ModelRouting.escalated_profile_for(profile)

    assert escalated.tier == :reasoning
    assert escalated.task_class == :simple_answer
    assert escalated.route_reason == "escalated_to_reasoning:default_fast_chat_tier"
    assert escalated.model == "reasoning-tier"
    assert Keyword.fetch!(escalated.llm_opts, :max_tool_steps) == 18
  end

  describe "model-based routing fallback (SPEC 09)" do
    defp put_classifier(fun) do
      :maraithon
      |> Application.get_env(:telegram_assistant, [])
      |> Keyword.put(:routing_classifier_complete, fun)
      |> then(&Application.put_env(:maraithon, :telegram_assistant, &1))
    end

    test "routes 'What did I promise yesterday?' to commitment_audit when the model says so" do
      put_classifier(fn prompt ->
        assert prompt =~ "What did I promise yesterday?"
        {:ok, ~s({"focus": "commitment_audit", "reason": "promise scan over a window"})}
      end)

      profile = ModelRouting.profile_for(%{text: "What did I promise yesterday?"})

      assert profile.tier == :reasoning
      assert profile.request_focus == :commitment_audit
      assert profile.task_class == :commitment_audit
      assert profile.route_reason == "commitment_scan_analysis"
      assert profile.model == "reasoning-tier"
      assert Keyword.fetch!(profile.llm_opts, :context_scope) == :commitment_audit
      assert Keyword.fetch!(profile.llm_opts, :tool_scope) == :commitment_audit
      # Budgets copied verbatim from the :waiting_on clause (R7).
      assert Keyword.fetch!(profile.llm_opts, :max_wall_clock_ms) == 90_000
      assert Keyword.fetch!(profile.llm_opts, :max_llm_turns) == 6
      assert Keyword.fetch!(profile.llm_opts, :max_tool_steps) == 12
      assert Keyword.fetch!(profile.llm_opts, :model_busy_max_retries) == 24
      assert Keyword.fetch!(profile.llm_opts, :model_retry_max_delay_ms) == 1_500
    end

    test "routes 'Handled the billing thing, what else?' to continuity when the model says so" do
      put_classifier(fn _prompt ->
        {:ok, ~s({"focus": "continuity", "reason": "bare follow-up to a surfaced item"})}
      end)

      profile = ModelRouting.profile_for(%{text: "Handled the billing thing, what else?"})

      assert profile.tier == :reasoning
      assert profile.request_focus == :continuity
      assert profile.task_class == :continuity
      assert profile.route_reason == "continuity_followup"
      assert Keyword.fetch!(profile.llm_opts, :context_scope) == :continuity
      assert Keyword.fetch!(profile.llm_opts, :tool_scope) == :continuity
      assert Keyword.fetch!(profile.llm_opts, :max_wall_clock_ms) == 90_000
      assert Keyword.fetch!(profile.llm_opts, :max_tool_steps) == 12
    end

    test "a 'none' classification keeps the ambiguous default" do
      put_classifier(fn _prompt ->
        {:ok, ~s({"focus": "none", "reason": "open-ended chat"})}
      end)

      profile = ModelRouting.profile_for(%{text: "tell me something interesting"})

      assert profile.tier == :chat
      assert profile.request_focus == nil
    end

    test "a malformed classifier response falls back to chat/nil and never escalates" do
      for content <- [
            "not json at all",
            ~s({"focus": "reasoning_forever"}),
            ~s({"unexpected": true}),
            ~s(["commitment_audit"])
          ] do
        put_classifier(fn _prompt -> {:ok, content} end)

        profile = ModelRouting.profile_for(%{text: "tell me something interesting"})

        assert profile.tier == :chat
        assert profile.request_focus == nil
      end
    end

    test "a classifier error falls back to chat/nil" do
      put_classifier(fn _prompt -> {:error, :boom} end)

      profile = ModelRouting.profile_for(%{text: "tell me something interesting"})

      assert profile.tier == :chat
      assert profile.request_focus == nil
    end

    test "a classifier timeout falls back to chat/nil without hanging the turn" do
      :maraithon
      |> Application.get_env(:telegram_assistant, [])
      |> Keyword.put(:routing_classifier_timeout_ms, 30)
      |> then(&Application.put_env(:maraithon, :telegram_assistant, &1))

      put_classifier(fn _prompt ->
        Process.sleep(500)
        {:ok, ~s({"focus": "commitment_audit", "reason": "too late"})}
      end)

      started = System.monotonic_time(:millisecond)
      profile = ModelRouting.profile_for(%{text: "tell me something interesting"})
      elapsed = System.monotonic_time(:millisecond) - started

      assert profile.tier == :chat
      assert profile.request_focus == nil
      assert elapsed < 400
    end

    test "a crashing classifier falls back to chat/nil" do
      put_classifier(fn _prompt -> raise "classifier exploded" end)

      profile = ModelRouting.profile_for(%{text: "tell me something interesting"})

      assert profile.tier == :chat
      assert profile.request_focus == nil
    end

    test "every regex-matched input keeps its fast path and never invokes the classifier" do
      test_pid = self()

      put_classifier(fn _prompt ->
        send(test_pid, :classifier_invoked)
        {:ok, ~s({"focus": "commitment_audit", "reason": "should never run"})}
      end)

      regex_matched_inputs = [
        # light_chat?/1 + @quick_chat_patterns (fast tier)
        "Perfect, thanks so much!",
        "Rewrite this to sound friendlier",
        # @planning_patterns
        "Can you send me a morning briefing?",
        "What should I do next?",
        # @today_mode_patterns
        "What matters today?",
        # @waiting_on_patterns
        "Who am I waiting on?",
        # @meeting_prep_patterns
        "What should I know before my meeting?",
        # @person_context_patterns
        "Who is Elena Fisher?",
        # @connector_status_patterns
        "Which connections are active?",
        # source-hint identity chat
        "Who is Charlie from Slack?"
      ]

      for text <- regex_matched_inputs do
        _profile = ModelRouting.profile_for(%{text: text})
      end

      # @linked_item_context_patterns (reply-aware branch)
      _profile =
        ModelRouting.profile_for(%{
          text: "Dismiss this todo as no longer relevant.",
          reply_to_message_id: "todo-card-1"
        })

      # Explicit request_focus also bypasses the classifier.
      _profile = ModelRouting.profile_for(%{text: "anything else?", request_focus: "waiting_on"})

      refute_received :classifier_invoked
    end

    test "explicit commitment_audit/continuity request_focus values normalize end-to-end" do
      profile = ModelRouting.profile_for(%{text: "anything", request_focus: "commitment_audit"})
      assert profile.request_focus == :commitment_audit
      assert profile.task_class == :commitment_audit

      profile = ModelRouting.profile_for(%{text: "anything", request_focus: "continuity"})
      assert profile.request_focus == :continuity
      assert profile.task_class == :continuity
    end

    test "empty or whitespace text never invokes the classifier" do
      test_pid = self()

      put_classifier(fn _prompt ->
        send(test_pid, :classifier_invoked)
        {:ok, ~s({"focus": "continuity", "reason": "no"})}
      end)

      for text <- ["", "   "] do
        profile = ModelRouting.profile_for(%{text: text})
        assert profile.request_focus == nil
      end

      refute_received :classifier_invoked
    end
  end

  test "routes contact and stale follow-up review asks to reasoning with relationship context" do
    for text <- [
          "Which contacts are stale?",
          "Who should I follow up with?",
          "Look up the contact named Jane Example and tell me what notes are stored.",
          "Review my CRM contacts that need a nudge."
        ] do
      profile = ModelRouting.profile_for(%{text: text})

      assert profile.tier == :reasoning
      assert profile.model == "reasoning-tier"
      assert profile.reasoning_effort == "high"
      assert profile.request_focus in [:person_context, :waiting_on, nil]
      assert Keyword.fetch!(profile.llm_opts, :chat_model) == "reasoning-tier"
    end
  end
end
