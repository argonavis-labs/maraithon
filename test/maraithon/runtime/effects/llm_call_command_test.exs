defmodule Maraithon.Runtime.Effects.LLMCallCommandTest do
  use ExUnit.Case, async: false

  alias Maraithon.Effects.Effect
  alias Maraithon.LLM.MockProvider
  alias Maraithon.Runtime.Effects.LLMCallCommand

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

    def complete(_params) do
      Agent.get_and_update(__MODULE__, fn
        [] -> {{:error, :exhausted_stub}, []}
        [resp | rest] -> {resp, rest}
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

  defp effect_for do
    %Effect{
      id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      params: %{"messages" => [%{"role" => "user", "content" => "go"}]}
    }
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
  end
end
