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
    assert profile.model == "chat-tier"
    assert profile.reasoning_effort == "medium"
    assert Keyword.fetch!(profile.llm_opts, :request_focus) == :connector_status
    assert Keyword.fetch!(profile.llm_opts, :context_scope) == :connector_status
    assert Keyword.fetch!(profile.llm_opts, :tool_scope) == :connector_status
  end

  test "routes broad planning and todo-review asks to the reasoning tier" do
    for text <- [
          "What should I do next?",
          "Give me the full detail of my todos.",
          "Please triage my todos.",
          "Prioritize my open loops."
        ] do
      profile = ModelRouting.profile_for(%{text: text})

      assert profile.tier == :reasoning
      assert profile.model == "reasoning-tier"
      assert profile.reasoning_effort == "high"
      assert profile.max_tokens == 6_000
      assert Keyword.fetch!(profile.llm_opts, :chat_model) == "reasoning-tier"
    end
  end

  test "routes morning briefing requests to the reasoning tier" do
    profile = ModelRouting.profile_for(%{text: "Can you send me a morning briefing?"})

    assert profile.tier == :reasoning
    assert profile.model == "reasoning-tier"
    assert profile.reasoning_effort == "high"
  end
end
