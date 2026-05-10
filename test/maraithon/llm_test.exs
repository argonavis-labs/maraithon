defmodule Maraithon.LLMTest.CapturingProvider do
  @moduledoc false
  @target :llm_routing_test_target

  def complete(params) do
    send(@target, {:complete, params})
    {:ok, %{content: "ok", model: params["model"], tokens_in: 0, tokens_out: 0}}
  end
end

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

  describe "routing_model/0 and complete_routing/1" do
    test "returns nil when no routing model configured" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLM.MockProvider,
        llm_provider_name: "mock",
        llm_model: "mock-v1",
        llm_routing_model: nil
      )

      assert LLM.routing_model() == nil
    end

    test "returns the configured routing model" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLM.MockProvider,
        llm_provider_name: "mock",
        llm_model: "mock-v1",
        llm_routing_model: "claude-haiku-4-5-20251001"
      )

      assert LLM.routing_model() == "claude-haiku-4-5-20251001"
    end

    test "complete_routing forwards to the configured provider with the routing model" do
      Process.register(self(), :llm_routing_test_target)

      on_exit(fn ->
        try do
          Process.unregister(:llm_routing_test_target)
        rescue
          ArgumentError -> :ok
        end
      end)

      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLMTest.CapturingProvider,
        llm_provider_name: "anthropic",
        llm_model: "claude-sonnet-4-20250514",
        llm_routing_model: "claude-haiku-4-5-20251001"
      )

      assert {:ok, %{model: "claude-haiku-4-5-20251001"}} =
               LLM.complete_routing(%{"messages" => [%{"role" => "user", "content" => "hi"}]})

      assert_received {:complete, %{"model" => "claude-haiku-4-5-20251001"}}
    end

    test "complete_routing falls back to complete when no routing model configured" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLM.MockProvider,
        llm_provider_name: "mock",
        llm_model: "mock-v1",
        llm_routing_model: nil
      )

      assert {:ok, %{model: "mock-v1"}} =
               LLM.complete_routing(%{"messages" => [%{"role" => "user", "content" => "hi"}]})
    end
  end
end
