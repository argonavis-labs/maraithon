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
end
