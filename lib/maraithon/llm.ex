defmodule Maraithon.LLM do
  @moduledoc """
  LLM provider interface and configuration.
  """

  defp runtime_config do
    Application.get_env(:maraithon, Maraithon.Runtime, [])
  end

  @doc """
  Get the configured LLM provider module.
  """
  def provider do
    runtime_config()
    |> Keyword.get(:llm_provider)
  end

  @doc """
  Get the configured provider name.
  """
  def provider_name do
    runtime_config()
    |> Keyword.get(:llm_provider_name, "unconfigured")
  end

  @doc """
  Get the active model.
  """
  def model do
    runtime_config()
    |> Keyword.get(:llm_model)
  end

  @doc """
  Get the active reasoning/intelligence setting for model calls.
  """
  def intelligence do
    case provider_name() do
      "openai" -> openai_reasoning_effort()
      _ -> runtime_config() |> Keyword.get(:llm_intelligence, openai_reasoning_effort())
    end
  end

  @doc """
  Get the active API key.
  """
  def api_key do
    runtime_config()
    |> Keyword.get(:llm_api_key)
  end

  def anthropic_model do
    runtime_config()
    |> Keyword.get(:anthropic_model, "claude-sonnet-4-20250514")
  end

  def anthropic_api_key do
    runtime_config()
    |> Keyword.get(:anthropic_api_key)
  end

  def openai_model do
    runtime_config()
    |> Keyword.get(:openai_model, "gpt-5.4")
  end

  def openai_api_key do
    runtime_config()
    |> Keyword.get(:openai_api_key)
  end

  def openai_reasoning_effort do
    runtime_config()
    |> Keyword.get(:openai_reasoning_effort, "high")
  end

  @doc """
  Complete a model request with the configured provider.
  """
  def complete(params) when is_map(params) do
    case provider() do
      nil ->
        {:error,
         {:llm_provider_not_configured,
          "No LLM provider is configured. Set LLM_PROVIDER=openai with OPENAI_API_KEY, or LLM_PROVIDER=anthropic with ANTHROPIC_API_KEY."}}

      module ->
        module.complete(params)
    end
  end
end
