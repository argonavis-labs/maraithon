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
