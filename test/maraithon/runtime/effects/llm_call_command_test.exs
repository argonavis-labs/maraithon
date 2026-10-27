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

  defmodule ExitTimeoutStub do
    @moduledoc false

    def complete(_params), do: exit({:timeout, :simulated_provider_deadline})
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

  defp swap_provider(provider, overrides \\ []) do
    original = Application.get_env(:maraithon, Maraithon.Runtime, [])

    runtime =
      original
      |> Keyword.put(:llm_provider, provider)
      |> Keyword.merge(overrides)

    Application.put_env(:maraithon, Maraithon.Runtime, runtime)

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

  test "rejects malformed or pathological success payloads without provider retries" do
    swap_provider(RetryStub)

    start_retry_stub_with_calls([
      {:ok, []},
      {:ok,
       %{
         content: "invalid usage",
         model: "stub",
         tokens_in: :erlang.bsl(1, 100_000),
         tokens_out: 1
       }}
    ])

    assert {:error, :invalid_effect_result} = LLMCallCommand.execute(effect_for())
    assert {:error, :invalid_effect_result} = LLMCallCommand.execute(effect_for())
    assert length(retry_stub_calls()) == 2
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

  test "request budget rejections log only a safe failure class" do
    secret = "oversized-effect-prompt-secret"

    effect = %Effect{
      id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      params: %{
        "messages" => [
          %{"role" => "user", "content" => secret <> String.duplicate("x", 129_000)}
        ]
      }
    }

    LogBuffer.clear()

    assert {:error, {:invalid_request, %{reason: "request_exceeds_budget"}}} =
             LLMCallCommand.execute(effect)

    Logger.flush()
    _ = :sys.get_state(LogBuffer)

    captured = LogBuffer.recent(20) |> inspect(printable_limit: :infinity)
    assert captured =~ "LLM effect request rejected"
    assert captured =~ "invalid_request"
    refute captured =~ secret
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

  test "normalizes caught provider deadline exits to the timeout atom" do
    swap_provider(ExitTimeoutStub)

    assert {:error, :timeout} = LLMCallCommand.execute(effect_for())
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

    test "caps durable claims at 120 seconds while retaining direct-call compatibility" do
      swap_provider(RetryStub)

      success =
        {:ok,
         %{
           content: "ok",
           model: "stub",
           tokens_in: 1,
           tokens_out: 1,
           finish_reason: "stop"
         }}

      start_retry_stub_with_calls([success, success])

      direct = effect_for()
      direct = %{direct | params: Map.put(direct.params, "timeout_ms", 300_000)}

      claimed = %{
        direct
        | id: Ecto.UUID.generate(),
          claimed_by: "test@node",
          claimed_at: DateTime.utc_now()
      }

      assert {:ok, _result} = LLMCallCommand.execute(direct)
      assert {:ok, _result} = LLMCallCommand.execute(claimed)

      assert [direct_call, claimed_call] = retry_stub_calls()
      assert direct_call["timeout_ms"] > 120_000
      assert direct_call["timeout_ms"] <= 300_000
      assert claimed_call["timeout_ms"] > 0
      assert claimed_call["timeout_ms"] <= 120_000
    end

    test "direct callers return one cleaned-up timeout without durable diversification" do
      swap_provider(RetryStub,
        llm_model: "primary",
        llm_chat_model: "fallback"
      )

      start_retry_stub_with_calls([
        {:error, :timeout},
        {:ok,
         %{
           content: "must not run",
           model: "fallback",
           tokens_in: 1,
           tokens_out: 1,
           finish_reason: "stop"
         }}
      ])

      effect = %Effect{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        params: %{
          "model" => "primary",
          "messages" => [%{"role" => "user", "content" => "go"}],
          "timeout_ms" => 300_000
        }
      }

      assert {:error, :timeout} = LLMCallCommand.execute(effect)
      assert [%{"model" => "primary", "timeout_ms" => timeout_ms}] = retry_stub_calls()
      assert timeout_ms > 120_000
      assert timeout_ms <= 300_000
    end

    test "preserves local-busy deferrals when their retry cannot fit the deadline" do
      swap_provider(RetryStub)
      start_retry_stub_with_calls([{:error, {:llm_busy, 5_000}}])

      effect = effect_for()
      effect = %{effect | params: Map.put(effect.params, "timeout_ms", 100)}

      assert {:error, {:llm_busy, 5_000}} = LLMCallCommand.execute(effect)
      [call] = retry_stub_calls()
      assert call["timeout_ms"] <= 100
      assert call["timeout_ms"] > 0
    end

    test "preserves transient reasons when their backoff cannot fit the deadline" do
      swap_provider(RetryStub)

      reasons = [
        {:rate_limited, 5_000},
        {:network_error, :closed},
        {:api_error, 503, :redacted}
      ]

      start_retry_stub_with_calls(Enum.map(reasons, &{:error, &1}))

      effect = effect_for()
      effect = %{effect | params: Map.put(effect.params, "timeout_ms", 100)}

      assert Enum.map(reasons, fn _reason -> LLMCallCommand.execute(effect) end) ==
               Enum.map(reasons, &{:error, &1})

      assert length(retry_stub_calls()) == length(reasons)
    end

    test "uses one full provider call per durable timeout and the first distinct fallback last" do
      swap_provider(RetryStub,
        llm_model: "primary-reasoning",
        llm_chat_model: "fallback-chat",
        llm_routing_model: "fallback-routing",
        llm_model_fallbacks: ["configured-backup"]
      )

      start_retry_stub_with_calls([
        {:error, :timeout},
        {:error, :timeout},
        {:ok,
         %{
           content: "recovered",
           model: "fallback-chat",
           tokens_in: 1,
           tokens_out: 1,
           finish_reason: "stop"
         }}
      ])

      base = %Effect{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        attempts: 0,
        max_attempts: 3,
        claimed_by: "test@node",
        claimed_at: DateTime.utc_now(),
        params: %{
          "messages" => [%{"role" => "user", "content" => "go"}],
          "reasoning_effort" => "xhigh",
          :model => "primary-reasoning",
          :max_tokens => 16_000,
          :reasoning => %{"effort" => "xhigh", "max_tokens" => 32_000}
        }
      }

      assert {:error, :timeout} = LLMCallCommand.execute(base)

      assert {:error, :timeout} =
               LLMCallCommand.execute(%{
                 base
                 | attempts: 1,
                   error: "timeout",
                   last_failure_code: "timeout",
                   last_failure_attempt: 1
               })

      assert {:ok, %{content: "recovered"}} =
               LLMCallCommand.execute(%{
                 base
                 | attempts: 2,
                   error: "timeout",
                   last_failure_code: "timeout",
                   last_failure_attempt: 2
               })

      assert [first, second, final] = retry_stub_calls()

      assert Enum.map([first, second, final], & &1["model"]) ==
               ["primary-reasoning", "primary-reasoning", "fallback-chat"]

      assert Enum.all?([first, second, final], fn call ->
               call["timeout_ms"] > 0 and call["timeout_ms"] <= 120_000
             end)

      assert first["max_tokens"] == 16_000
      assert second["max_tokens"] == 16_000
      assert first["reasoning"] == %{"effort" => "xhigh", "max_tokens" => 32_000}
      assert final["max_tokens"] == 8_000
      assert final["reasoning_effort"] == "medium"
      refute Map.has_key?(final, "reasoning")
    end

    test "final durable timeout recovery makes one provider-bound call" do
      swap_provider(RetryStub,
        llm_model: "primary",
        llm_chat_model: "fallback",
        llm_routing_model: "second-fallback"
      )

      start_retry_stub_with_calls([
        {:error, {:network_error, :closed}},
        {:ok,
         %{
           content: "must remain queued",
           model: "unexpected",
           tokens_in: 1,
           tokens_out: 1,
           finish_reason: "stop"
         }}
      ])

      effect = %Effect{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        attempts: 2,
        max_attempts: 3,
        last_failure_code: "timeout",
        last_failure_attempt: 2,
        claimed_by: "test@node",
        claimed_at: DateTime.utc_now(),
        params: %{
          "model" => "primary",
          "messages" => [%{"role" => "user", "content" => "go"}],
          "max_tokens" => 16_000
        }
      }

      assert {:error, {:network_error, :closed}} = LLMCallCommand.execute(effect)
      assert [%{"model" => "fallback", "max_tokens" => 8_000}] = retry_stub_calls()
    end

    test "final one-shot rate limits still update the shared cooldown" do
      swap_provider(RetryStub,
        llm_model: "primary",
        llm_chat_model: "fallback"
      )

      start_retry_stub_with_calls([
        {:error, {:rate_limited, 60_000}},
        {:ok,
         %{
           content: "must remain queued",
           model: "unexpected",
           tokens_in: 1,
           tokens_out: 1,
           finish_reason: "stop"
         }}
      ])

      effect = %Effect{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        attempts: 2,
        max_attempts: 3,
        last_failure_code: "timeout",
        last_failure_attempt: 2,
        claimed_by: "test@node",
        claimed_at: DateTime.utc_now(),
        params: %{
          "model" => "primary",
          "messages" => [%{"role" => "user", "content" => "go"}]
        }
      }

      assert {:error, {:rate_limited, 60_000}} = LLMCallCommand.execute(effect)
      assert [%{"model" => "fallback"}] = retry_stub_calls()
      assert LLMRateLimiter.status().blocked_for_ms > 0
    end

    test "keeps malformed final-timeout requests on the validation path" do
      swap_provider(RetryStub,
        llm_model: "primary",
        llm_chat_model: "fallback"
      )

      start_retry_stub_with_calls([
        {:ok,
         %{
           content: "must not run",
           model: "unexpected",
           tokens_in: 1,
           tokens_out: 1,
           finish_reason: "stop"
         }}
      ])

      effect = %Effect{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        attempts: 2,
        max_attempts: 3,
        error: "timeout",
        last_failure_code: "timeout",
        last_failure_attempt: 2,
        claimed_by: "test@node",
        claimed_at: DateTime.utc_now(),
        params: nil
      }

      assert {:error, {:invalid_request, %{reason: "invalid_request_shape"}}} =
               LLMCallCommand.execute(effect)

      assert retry_stub_calls() == []
    end

    test "revalidates a durable fallback before provider work" do
      swap_provider(RetryStub,
        llm_model: "p",
        llm_chat_model: String.duplicate("f", 255),
        llm_routing_model: "routing"
      )

      start_retry_stub_with_calls([
        {:ok,
         %{
           content: "must not run",
           model: "unexpected",
           tokens_in: 1,
           tokens_out: 1,
           finish_reason: "stop"
         }}
      ])

      effect = %Effect{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        attempts: 2,
        max_attempts: 3,
        error: "timeout",
        last_failure_code: "timeout",
        last_failure_attempt: 2,
        claimed_by: "test@node",
        claimed_at: DateTime.utc_now(),
        params: %{
          "model" => "p",
          "messages" => [
            %{"role" => "user", "content" => String.duplicate("x", 127_650)}
          ],
          "max_tokens" => 16_000,
          "reasoning_effort" => "xhigh"
        }
      }

      assert {:error, {:invalid_request, %{reason: "request_exceeds_budget"}}} =
               LLMCallCommand.execute(effect)

      assert retry_stub_calls() == []
    end

    test "does not select a durable fallback without exact timeout provenance" do
      swap_provider(RetryStub,
        llm_model: "primary-reasoning",
        llm_chat_model: "fallback-chat",
        llm_routing_model: "fallback-routing"
      )

      start_retry_stub_with_calls([
        {:ok,
         %{
           content: "primary recovered",
           model: "primary-reasoning",
           tokens_in: 1,
           tokens_out: 1,
           finish_reason: "stop"
         }}
      ])

      effect = %Effect{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        attempts: 2,
        max_attempts: 3,
        # Display text and stale mixed-version provenance are insufficient.
        error: "timeout",
        last_failure_code: "timeout",
        last_failure_attempt: 1,
        params: %{
          "model" => "primary-reasoning",
          "messages" => [%{"role" => "user", "content" => "go"}]
        }
      }

      assert {:ok, %{content: "primary recovered"}} = LLMCallCommand.execute(effect)
      assert [%{"model" => "primary-reasoning"}] = retry_stub_calls()
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
