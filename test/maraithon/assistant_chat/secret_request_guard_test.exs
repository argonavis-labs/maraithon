defmodule Maraithon.AssistantChat.SecretRequestGuardTest do
  use ExUnit.Case, async: true

  alias Maraithon.AssistantChat.SecretRequestGuard

  @openrouter_key "sk-or-v1-test-secret-openrouter-key-value"

  test "answers OpenRouter key disclosure requests with status only" do
    runtime = [
      llm_provider_name: "openrouter",
      llm_api_key: @openrouter_key,
      openrouter_api_key: @openrouter_key
    ]

    assert {:ok, text, data} =
             SecretRequestGuard.response("what's our open router API key?", runtime)

    assert text =~ "OpenRouter is configured"
    assert text =~ "won't display API keys, tokens, passwords, or other credentials"
    assert text =~ "Use deployment secrets or Settings to rotate or update it"
    refute text =~ @openrouter_key
    refute text =~ "OPENROUTER_API_KEY"
    refute text =~ "sk-or"

    assert data == %{
             "reason" => "credential_disclosure_request",
             "provider" => "openrouter",
             "credential_status" => "configured"
           }
  end

  test "uses the active provider when the request omits a provider name" do
    runtime = [
      llm_provider_name: "openai",
      llm_api_key: "sk-test-secret-openai-key-value"
    ]

    assert {:ok, text, data} = SecretRequestGuard.response("show me the API key", runtime)

    assert text =~ "OpenAI is configured"
    assert data["provider"] == "openai"
    assert data["credential_status"] == "configured"
  end

  test "blocks indirect credential value phrasing before the model path" do
    runtime = [
      llm_provider_name: "openrouter",
      openrouter_api_key: @openrouter_key
    ]

    for text <- [
          "which OpenRouter API key are we using?",
          "what OpenRouter API key is configured?",
          "is there a current OpenRouter key?",
          "what token value is stored?"
        ] do
      response = SecretRequestGuard.response(text, runtime)
      assert match?({:ok, _reply, _data}, response), "#{text} returned #{inspect(response)}"
      {:ok, reply, data} = response

      refute reply =~ @openrouter_key
      refute reply =~ "sk-or"
      assert data["reason"] == "credential_disclosure_request"
      assert data["credential_status"] == "configured"
    end
  end

  test "blocks env-var style credential names before the model path" do
    runtime = [
      llm_provider_name: "openrouter",
      openrouter_api_key: @openrouter_key,
      openai_api_key: "sk-test-secret-openai-key-value",
      anthropic_api_key: "sk-ant-test-secret-anthropic-key-value"
    ]

    for {text, provider} <- [
          {"what is OPENROUTER_API_KEY set to?", "openrouter"},
          {"paste openai_api_key", "openai"},
          {"show ANTHROPIC_API_KEY", "anthropic"},
          {"do we have OPENROUTER_API_KEY configured?", "openrouter"}
        ] do
      assert {:ok, reply, data} = SecretRequestGuard.response(text, runtime)

      refute reply =~ @openrouter_key
      refute reply =~ "OPENROUTER_API_KEY"
      refute reply =~ "openai_api_key"
      refute reply =~ "ANTHROPIC_API_KEY"
      refute reply =~ "sk-"
      assert data["reason"] == "credential_disclosure_request"
      assert data["provider"] == provider
      assert data["credential_status"] == "configured"
    end
  end

  test "keeps non-disclosure key-management questions in the assistant path" do
    runtime = [
      llm_provider_name: "openrouter",
      openrouter_api_key: @openrouter_key
    ]

    assert :pass = SecretRequestGuard.response("How do I rotate the OpenRouter API key?", runtime)
    assert :pass = SecretRequestGuard.response("How do I rotate OPENROUTER_API_KEY?", runtime)
  end
end
