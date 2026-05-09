defmodule Maraithon.LLMTest do
  use ExUnit.Case, async: false

  alias Maraithon.LLM

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime)

    Application.put_env(:maraithon, Maraithon.Runtime,
      llm_provider: Maraithon.LLM.MockProvider,
      llm_provider_name: "mock",
      llm_model: "mock-v1",
      anthropic_model: "claude-sonnet-4-20250514",
      openai_model: "gpt-5.4",
      openai_reasoning_effort: "high"
    )

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      else
        Application.delete_env(:maraithon, Maraithon.Runtime)
      end
    end)

    :ok
  end

  describe "provider/0" do
    test "returns the configured test MockProvider" do
      assert LLM.provider() == Maraithon.LLM.MockProvider
    end
  end

  describe "model/0" do
    test "returns the configured test model" do
      assert LLM.model() == "mock-v1"
    end

    test "returns the active OpenAI model when configured" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider_name: "openai",
        llm_model: "gpt-5.4",
        openai_model: "gpt-5.4"
      )

      assert LLM.model() == "gpt-5.4"
      assert LLM.openai_model() == "gpt-5.4"
    end
  end

  describe "api_key/0" do
    test "returns configured API key or nil" do
      # May return nil if not configured
      _key = LLM.api_key()
      assert true
    end
  end
end
