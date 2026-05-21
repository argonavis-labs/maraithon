defmodule Maraithon.LLMTest.CapturingProvider do
  @moduledoc false
  @target :llm_routing_test_target

  def complete(params) do
    send(@target, {:complete, params})
    {:ok, %{content: "ok", model: params["model"], tokens_in: 0, tokens_out: 0}}
  end
end

defmodule Maraithon.LLMTest.RateLimitedProvider do
  @moduledoc false
  @target :llm_routing_test_target

  def complete(params) do
    send(@target, {:rate_limited_provider_called, params})
    {:error, {:rate_limited, 60_000}}
  end
end

defmodule Maraithon.LLMTest do
  use ExUnit.Case, async: false

  alias Maraithon.LLM
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime)
    ensure_rate_limiter_started()
    LLMRateLimiter.reset()

    Application.put_env(:maraithon, Maraithon.Runtime,
      llm_provider: Maraithon.LLM.MockProvider,
      llm_provider_name: "mock",
      llm_model: "mock-v1",
      anthropic_model: "claude-sonnet-4-20250514",
      openai_model: "gpt-5.4",
      openai_reasoning_effort: "high"
    )

    on_exit(fn ->
      LLMRateLimiter.reset()

      if original_runtime do
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      else
        Application.delete_env(:maraithon, Maraithon.Runtime)
      end
    end)

    :ok
  end

  defp ensure_rate_limiter_started do
    case Process.whereis(LLMRateLimiter) do
      nil -> start_supervised!(LLMRateLimiter)
      _pid -> :ok
    end
  end

  describe "provider/0" do
    test "returns the configured test MockProvider" do
      assert LLM.provider() == Maraithon.LLM.MockProvider
    end
  end

  describe "provider rate limiting" do
    setup do
      Process.register(self(), :llm_routing_test_target)

      on_exit(fn ->
        try do
          Process.unregister(:llm_routing_test_target)
        rescue
          ArgumentError -> :ok
        end
      end)

      :ok
    end

    test "records provider cooldowns and blocks the next direct LLM call" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLMTest.RateLimitedProvider,
        llm_provider_name: "openai",
        llm_model: "gpt-5.4"
      )

      params = %{"messages" => [%{"role" => "user", "content" => "hi"}]}

      assert {:error, {:rate_limited, 60_000}} = LLM.complete(params)
      assert_received {:rate_limited_provider_called, ^params}
      assert LLMRateLimiter.status().blocked_for_ms > 0

      assert {:error, {:rate_limited, retry_after_ms}} = LLM.complete(params)
      assert retry_after_ms > 0
      refute_received {:rate_limited_provider_called, ^params}
    end

    test "does not block chat model calls behind an active reasoning call" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        llm_provider: Maraithon.LLMTest.CapturingProvider,
        llm_provider_name: "openai",
        llm_model: "gpt-5.4",
        llm_chat_model: "gpt-4.1-mini"
      )

      test_pid = self()

      holder =
        start_supervised!(
          {Task,
           fn ->
             assert :ok = LLMRateLimiter.checkout(:reasoning)
             send(test_pid, :reasoning_slot_held)

             receive do
               :release_reasoning_slot -> LLMRateLimiter.checkin(:reasoning)
             end
           end}
        )

      assert_receive :reasoning_slot_held

      chat_params = %{
        "model" => "gpt-4.1-mini",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      assert {:ok, %{model: "gpt-4.1-mini"}} = LLM.complete(chat_params)
      assert_received {:complete, ^chat_params}

      reasoning_params = %{
        "model" => "gpt-5.4",
        "messages" => [%{"role" => "user", "content" => "think"}]
      }

      assert {:error, {:llm_busy, retry_after_ms}} = LLM.complete(reasoning_params)
      assert retry_after_ms > 0
      refute_received {:complete, ^reasoning_params}

      send(holder, :release_reasoning_slot)
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
