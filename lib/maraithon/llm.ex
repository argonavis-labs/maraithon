defmodule Maraithon.LLM do
  @moduledoc """
  LLM provider interface and configuration.
  """

  alias Maraithon.Runtime.Effects.LLMRateLimiter

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
  Get the active fast/routing model.

  Returns nil when no routing model is configured. Callers should fall back
  to `complete/1` (which uses the main model) when this is nil.
  """
  def routing_model do
    runtime_config()
    |> Keyword.get(:llm_routing_model)
  end

  @doc """
  Get the active chat-tier model. This is the model used by the user-facing
  Telegram assistant runner — favors low latency over deep reasoning. The
  reasoning-tier `model/0` stays for chief of staff and complex agent work.

  Falls back to `model/0` when not configured.
  """
  def chat_model do
    runtime_config()
    |> Keyword.get(:llm_chat_model)
    |> case do
      nil -> model()
      "" -> model()
      other -> other
    end
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
        run_provider_request(module, fn -> module.complete(params) end)
    end
  end

  @doc """
  Complete a request using the routing/fast model when configured.

  This is for cheap, latency-sensitive calls such as intent classification.
  Falls back to the primary model when no routing model is configured or
  when the caller already pinned a model in the params.
  """
  def complete_routing(params) when is_map(params) do
    case routing_model() do
      nil ->
        complete(params)

      _ when is_map_key(params, "model") ->
        complete(params)

      routing ->
        complete(Map.put(params, "model", routing))
    end
  end

  @doc """
  Complete a request using the chat-tier model. Used by the Telegram
  assistant chat runner so user-facing answers stay fast. Reasoning-heavy
  callers should keep using `complete/1`.
  """
  def complete_chat(params) when is_map(params) do
    cond do
      is_map_key(params, "model") -> complete(params)
      true -> complete(Map.put(params, "model", chat_model()))
    end
  end

  @doc """
  Stream-complete a request, calling on_chunk for each output_text delta.

  Falls back to `complete/1` when the configured provider does not
  implement `stream_complete/2` or when the streaming feature is disabled.
  """
  def stream_complete(params, on_chunk) when is_map(params) and is_function(on_chunk, 1) do
    cond do
      not stream_replies_enabled?() ->
        complete(params)

      is_nil(provider()) ->
        complete(params)

      function_exported?(provider(), :stream_complete, 2) ->
        run_provider_request(provider(), fn -> provider().stream_complete(params, on_chunk) end)

      true ->
        complete(params)
    end
  end

  @doc """
  Stream-complete via the chat-tier model.
  """
  def stream_complete_chat(params, on_chunk)
      when is_map(params) and is_function(on_chunk, 1) do
    if is_map_key(params, "model") do
      stream_complete(params, on_chunk)
    else
      stream_complete(Map.put(params, "model", chat_model()), on_chunk)
    end
  end

  defp stream_replies_enabled? do
    runtime_config()
    |> Keyword.get(:openai_stream_replies, true)
  end

  defp run_provider_request(module, fun) when is_function(fun, 0) do
    if provider_backpressure_enabled?(module) do
      with_provider_slot(fun)
    else
      fun.()
    end
  end

  defp provider_backpressure_enabled?(Maraithon.LLM.OpenAIProvider), do: true
  defp provider_backpressure_enabled?(Maraithon.LLM.AnthropicProvider), do: true

  defp provider_backpressure_enabled?(_module) do
    provider_name() in ["openai", "anthropic"]
  end

  defp with_provider_slot(fun) when is_function(fun, 0) do
    case LLMRateLimiter.checkout() do
      :ok ->
        try do
          fun.()
          |> tap(&record_provider_rate_limit/1)
        after
          LLMRateLimiter.checkin()
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp record_provider_rate_limit({:error, {:rate_limited, retry_after_ms}}) do
    LLMRateLimiter.record_rate_limit(retry_after_ms)
  end

  defp record_provider_rate_limit(_result), do: :ok
end
