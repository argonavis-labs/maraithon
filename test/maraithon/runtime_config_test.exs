defmodule Maraithon.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @env_keys ~w(
    LLM_MODEL
    LLM_PROVIDER
    OPENAI_API_KEY
    OPENAI_MODEL
    OPENAI_CHAT_MODEL
    OPENAI_ROUTING_MODEL
    OPENROUTER_API_KEY
    OPENROUTER_MODEL
    OPENROUTER_CHAT_MODEL
    OPENROUTER_ROUTING_MODEL
    ANTHROPIC_API_KEY
    ANTHROPIC_MODEL
    ANTHROPIC_CHAT_MODEL
    ANTHROPIC_ROUTING_MODEL
  )

  setup do
    original_env = Map.new(@env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Enum.each(@env_keys, &System.delete_env/1)

    :ok
  end

  test "LLM_MODEL=qwen/qwen3.7-max selects OpenRouter even when LLM_PROVIDER is stale" do
    System.put_env("LLM_MODEL", "qwen/qwen3.7-max")
    System.put_env("LLM_PROVIDER", "openai")
    System.put_env("OPENAI_API_KEY", "test-openai-key")
    System.put_env("OPENROUTER_API_KEY", "test-openrouter-key")

    runtime = runtime_config()

    assert Keyword.fetch!(runtime, :llm_provider_name) == "openrouter"
    assert Keyword.fetch!(runtime, :llm_provider) == Maraithon.LLM.OpenRouterProvider
    assert Keyword.fetch!(runtime, :llm_model) == "qwen/qwen3.7-max"
    assert Keyword.fetch!(runtime, :llm_chat_model) == "qwen/qwen3.7-max"
    assert Keyword.fetch!(runtime, :llm_routing_model) == "qwen/qwen3.7-max"
    assert Keyword.fetch!(runtime, :llm_api_key) == "test-openrouter-key"
  end

  test "LLM_MODEL=gpt-5.4 selects OpenAI even when LLM_PROVIDER is stale" do
    System.put_env("LLM_MODEL", "gpt-5.4")
    System.put_env("LLM_PROVIDER", "openrouter")
    System.put_env("OPENAI_API_KEY", "test-openai-key")
    System.put_env("OPENROUTER_API_KEY", "test-openrouter-key")

    runtime = runtime_config()

    assert Keyword.fetch!(runtime, :llm_provider_name) == "openai"
    assert Keyword.fetch!(runtime, :llm_provider) == Maraithon.LLM.OpenAIProvider
    assert Keyword.fetch!(runtime, :llm_model) == "gpt-5.4"
    assert Keyword.fetch!(runtime, :llm_chat_model) == "gpt-5.4"
    assert Keyword.fetch!(runtime, :llm_routing_model) == "gpt-5.4"
    assert Keyword.fetch!(runtime, :llm_api_key) == "test-openai-key"
  end

  test "LLM_MODEL=qwen is a shorthand for the default Qwen OpenRouter model" do
    System.put_env("LLM_MODEL", "qwen")
    System.put_env("OPENROUTER_API_KEY", "test-openrouter-key")

    runtime = runtime_config()

    assert Keyword.fetch!(runtime, :llm_provider_name) == "openrouter"
    assert Keyword.fetch!(runtime, :llm_model) == "qwen/qwen3.7-max"
  end

  defp runtime_config do
    "config/runtime.exs"
    |> Config.Reader.read!(env: :dev)
    |> Keyword.fetch!(:maraithon)
    |> Keyword.fetch!(Maraithon.Runtime)
  end
end
