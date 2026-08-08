defmodule Maraithon.Runtime.Effects.LLMCallCommandTest do
  use ExUnit.Case, async: false

  alias Maraithon.Effects.Effect
  alias Maraithon.LLM.MockProvider
  alias Maraithon.LLM.OpenRouterProvider
  alias Maraithon.LogBuffer
  alias Maraithon.Runtime.Effects.LLMCallCommand
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  setup do
    LLMRateLimiter.reset()

    on_exit(fn -> LLMRateLimiter.reset() end)

    :ok
  end

  test "normalizes usage metadata for mock provider responses" do
    original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(original_runtime_config, :llm_provider, MockProvider)
    )

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
    end)

    effect = %Effect{
      id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      params: %{
        "messages" => [
          %{"role" => "user", "content" => "scan inbox and calendar"}
        ]
      }
    }

    assert {:ok, result} = LLMCallCommand.execute(effect)
    assert result.model == "mock-v1"
    assert result.usage.input_tokens == result.tokens_in
    assert result.usage.output_tokens == result.tokens_out
    assert result.usage.total_tokens == result.tokens_in + result.tokens_out
  end

  test "returns an explicit error when no LLM provider is configured" do
    original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.merge(original_runtime_config,
        llm_provider: nil,
        llm_provider_name: "unconfigured",
        llm_model: nil
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
    end)

    effect = %Effect{
      id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      params: %{
        "messages" => [
          %{"role" => "user", "content" => "scan inbox and calendar"}
        ]
      }
    }

    assert {:error, {:llm_provider_not_configured, message}} = LLMCallCommand.execute(effect)
    assert message =~ "No LLM provider is configured"
    assert message =~ "OPENAI_API_KEY"
  end

  defmodule RetryStub do
    @moduledoc false
    # Provider that emits the responses set up via `setup/1` in order, one
    # per `complete/1` call. Used to verify the retry policy.

    def complete(params) do
      Agent.get_and_update(__MODULE__, fn
        [] ->
          {{:error, :exhausted_stub}, []}

        [resp | rest] ->
          {resp, rest}

        %{responses: [], calls: calls} = state ->
          {{:error, :exhausted_stub}, %{state | calls: [params | calls]}}

        %{responses: [resp | rest], calls: calls} = state ->
          {resp, %{state | responses: rest, calls: [params | calls]}}
      end)
    end
  end

  defp swap_provider(provider) do
    original = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(original, :llm_provider, provider)
    )

    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Runtime, original) end)
  end

  defp start_retry_stub(responses) do
    start_supervised!(%{
      id: RetryStub,
      start: {Agent, :start_link, [fn -> responses end, [name: RetryStub]]}
    })
  end

  defp start_retry_stub_with_calls(responses) do
    start_supervised!(%{
      id: RetryStub,
      start:
        {Agent, :start_link, [fn -> %{responses: responses, calls: []} end, [name: RetryStub]]}
    })
  end

  defp retry_stub_calls do
    RetryStub
    |> Agent.get(& &1.calls)
    |> Enum.reverse()
  end

  defp effect_for do
    %Effect{
      id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      params: %{"messages" => [%{"role" => "user", "content" => "go"}]}
    }
  end

  test "caps pathological token strings and configured primary ceilings before provider work" do
    original = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.merge(original,
        llm_provider: RetryStub,
        llm_primary_max_tokens: :erlang.bsl(1, 100_000)
      )
    )

    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Runtime, original) end)

    start_retry_stub_with_calls([
      {:ok,
       %{
         content: "bounded",
         model: "stub",
         tokens_in: 1,
         tokens_out: 1,
         finish_reason: "stop"
       }}
    ])

    fallbacks =
      LLMCallCommand.normalize_model_fallbacks(
        String.duplicate("valid-model,", 10_000) <> String.duplicate("x", 10_000)
      )

    assert length(fallbacks) <= 8
    assert Enum.all?(fallbacks, &(byte_size(&1) <= 255))

    effect = %Effect{
      id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      params: %{
        "messages" => [%{"role" => "user", "content" => "go"}],
        "max_tokens" => String.duplicate("9", 1_000_000)
      }
    }

    assert {:ok, _result} = LLMCallCommand.execute(effect)
    assert [%{"max_tokens" => 32_000}] = retry_stub_calls()
  end

  test "OpenRouter error bodies never reach effect-command logs" do
    bypass = Bypass.open()
    swap_provider(OpenRouterProvider)

    original_openrouter = Application.get_env(:maraithon, :openrouter)

    runtime =
      Application.get_env(:maraithon, Maraithon.Runtime, [])
      |> Keyword.merge(
        llm_provider: OpenRouterProvider,
        llm_provider_name: "openrouter",
        llm_model: "qwen/qwen3.7-max",
        openrouter_model: "qwen/qwen3.7-max",
        openrouter_api_key: "test_api_key",
        llm_model_fallbacks: []
      )

    Application.put_env(:maraithon, Maraithon.Runtime, runtime)

    Application.put_env(:maraithon, :openrouter,
      base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
    )

    on_exit(fn ->
      if original_openrouter do
        Application.put_env(:maraithon, :openrouter, original_openrouter)
      else
        Application.delete_env(:maraithon, :openrouter)
      end
    end)

    Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        400,
        Jason.encode!(%{"error" => %{"message" => "effect-prompt-echo-secret"}})
      )
    end)

    LogBuffer.clear()

    assert {:error, {:api_error, 400, body}} = LLMCallCommand.execute(effect_for())
    assert body == :redacted

    Logger.flush()
    _ = :sys.get_state(LogBuffer)

    captured = LogBuffer.recent(100) |> inspect(printable_limit: :infinity)
    refute captured =~ "effect-prompt-echo-secret"
    assert captured =~ "api_error"
  end

  describe "retry policy" do
    test "retries on :rate_limited with the provider-supplied backoff and recovers" do
      swap_provider(RetryStub)

      start_retry_stub([
        {:error, {:rate_limited, 10}},
        {:ok,
         %{
           content: "ok",
           model: "stub",
           tokens_in: 1,
           tokens_out: 1,
           finish_reason: "stop"
         }}
      ])

      assert {:ok, %{content: "ok"}} = LLMCallCommand.execute(effect_for())
    end

    test "uses one total deadline across local-busy retries" do
      swap_provider(RetryStub)
      start_retry_stub_with_calls([{:error, {:llm_busy, 5_000}}])

      effect = effect_for()
      effect = %{effect | params: Map.put(effect.params, "timeout_ms", 100)}

      assert {:error, :timeout} = LLMCallCommand.execute(effect)
      [call] = retry_stub_calls()
      assert call["timeout_ms"] <= 100
      assert call["timeout_ms"] > 0
    end

    test "non-retryable errors are returned without retrying" do
      swap_provider(RetryStub)
      start_retry_stub([{:error, :model_not_found}])

      assert {:error, :model_not_found} = LLMCallCommand.execute(effect_for())
      # Stub queue empty -> exactly one provider call -> no retry happened.
      assert Agent.get(RetryStub, & &1) == []
    end

    test "after the max retry attempts the final error is surfaced" do
      swap_provider(RetryStub)

      start_retry_stub([
        {:error, {:rate_limited, 5}},
        {:error, {:rate_limited, 5}},
        {:error, {:rate_limited, 5}}
      ])

      assert {:error, {:rate_limited, 5}} = LLMCallCommand.execute(effect_for())
    end

    test "long provider rate limits return to the queue without inline fallback" do
      swap_provider(RetryStub)

      start_retry_stub_with_calls([
        {:error, {:rate_limited, 60_000}},
        {:ok,
         %{
           content: "would be wrong",
           model: "fallback",
           tokens_in: 1,
           tokens_out: 1,
           finish_reason: "stop"
         }}
      ])

      assert {:error, {:rate_limited, 60_000}} = LLMCallCommand.execute(effect_for())
      assert [_single_call] = retry_stub_calls()
      assert LLMRateLimiter.status().blocked_for_ms > 0
    end

    test "does not fallback through same-provider models after rate limit exhaustion" do
      original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.merge(original_runtime_config,
          llm_provider: RetryStub,
          llm_model: "primary-reasoning",
          llm_chat_model: "primary-reasoning",
          llm_routing_model: "fast-routing",
          llm_model_fallbacks: ["backup-model"]
        )
      )

      on_exit(fn ->
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
      end)

      start_retry_stub_with_calls([
        {:error, {:rate_limited, 5}},
        {:error, {:rate_limited, 5}},
        {:error, {:rate_limited, 5}},
        {:ok,
         %{
           content: "fallback ok",
           model: "fast-routing",
           tokens_in: 1,
           tokens_out: 1,
           finish_reason: "stop"
         }}
      ])

      effect = %Effect{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        params: %{
          "model" => "primary-reasoning",
          "messages" => [%{"role" => "user", "content" => "go"}],
          "max_tokens" => 16_000,
          "reasoning_effort" => "xhigh"
        }
      }

      assert {:error, {:rate_limited, 5}} = LLMCallCommand.execute(effect)
      assert length(retry_stub_calls()) == 3
    end
  end
end
