defmodule Maraithon.Runtime.Effects.LLMCallCommand do
  @moduledoc """
  Command implementation for `llm_call` effects.

  Retries short transient provider errors (network blips, 5xx API errors,
  timeouts, and very short rate limits) up to `@max_retry_attempts` times. Long
  provider rate limits are surfaced to the effect runner so the durable queue can
  retry later without blocking worker tasks or stampeding fallback models in the
  same provider bucket.
  """

  @behaviour Maraithon.Runtime.Effects.Command

  alias Maraithon.LLM
  alias Maraithon.Effects.Effect
  alias Maraithon.Spend
  alias Maraithon.Tracing
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  require Logger

  # Total attempts including the first call. 3 = first try + 2 retries.
  @max_retry_attempts 3
  # Hard ceiling on a single retry-after to keep the effect process from
  # blocking on the provider for an unreasonable stretch.
  @max_retry_after_ms 120_000
  @max_inline_rate_limit_retry_ms 5_000
  # Fallback when the provider gives a non-integer retry-after.
  @default_rate_limited_backoff_ms 30_000
  @fallback_max_tokens 8_000
  @fallback_reasoning_effort "medium"
  @default_primary_max_tokens 32_000

  @impl true
  def execute(%Effect{} = effect) do
    params = effect.params |> cap_primary_tokens()
    _timeout = params["timeout_ms"] || 120_000

    Logger.info("Starting LLM call for effect #{effect.id}",
      agent_id: effect.agent_id,
      effect_id: effect.id
    )

    try do
      case run_with_retry(params, effect, 1) do
        {:ok, data} ->
          data = ensure_usage(data)

          Logger.info("LLM call succeeded",
            effect_id: effect.id,
            model: data.model,
            tokens: data.usage.total_tokens,
            cost: data.usage.total_cost
          )

          {:ok, data}

        {:error, reason} = error ->
          Logger.warning("LLM call failed", effect_id: effect.id, reason: inspect(reason))
          error
      end
    catch
      :exit, {:timeout, _} ->
        Logger.warning("LLM call timed out", effect_id: effect.id)
        {:error, "timeout"}
    end
  end

  defp run_with_retry(params, effect, attempt) do
    case LLM.complete(params) do
      {:ok, _data} = ok ->
        ok

      {:error, reason} ->
        record_provider_limit(reason)

        case retry_backoff_ms(reason, attempt) do
          nil ->
            # Same-model retries are spent. For transient errors that look
            # like model-scoped capacity issues, try configured fallback
            # models with a lighter request before failing the effect.
            maybe_try_model_fallbacks(params, effect, reason)

          sleep_ms ->
            Logger.info(
              "LLM call retry #{attempt}/#{@max_retry_attempts - 1} after #{sleep_ms}ms",
              effect_id: effect.id,
              reason: inspect(reason)
            )

            Process.sleep(sleep_ms)
            run_with_retry(params, effect, attempt + 1)
        end
    end
  end

  defp maybe_try_model_fallbacks(params, effect, original_reason) do
    fallback_models = fallback_models(params)

    cond do
      provider_deferral_error?(original_reason) ->
        {:error, original_reason}

      not transient_capacity_error?(original_reason) ->
        {:error, original_reason}

      fallback_models == [] ->
        {:error, original_reason}

      true ->
        try_fallback_models(params, effect, original_reason, fallback_models, [])
    end
  end

  defp try_fallback_models(_params, _effect, original_reason, [], fallback_errors) do
    Tracing.record_error({:llm_fallbacks_failed, original_reason, Enum.reverse(fallback_errors)})

    {:error, {:llm_fallbacks_failed, original_reason, Enum.reverse(fallback_errors)}}
  end

  defp try_fallback_models(params, effect, original_reason, [fallback_model | rest], errors) do
    Logger.info(
      "LLM primary exhausted; falling back to alternate model",
      effect_id: effect.id,
      original_reason: inspect(original_reason),
      fallback_model: fallback_model
    )

    case LLM.complete(fallback_params(params, fallback_model)) do
      {:ok, _data} = ok ->
        ok

      {:error, fallback_reason} ->
        record_provider_limit(fallback_reason)

        Logger.warning(
          "LLM fallback model failed",
          effect_id: effect.id,
          fallback_model: fallback_model,
          fallback_reason: inspect(fallback_reason)
        )

        try_fallback_models(params, effect, original_reason, rest, [
          %{model: fallback_model, reason: inspect(fallback_reason)} | errors
        ])
    end
  end

  defp fallback_models(params) do
    current_model = normalize_model(Map.get(params, "model") || LLM.model())

    [LLM.chat_model(), LLM.routing_model() | configured_model_fallbacks()]
    |> Enum.map(&normalize_model/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == current_model))
    |> Enum.uniq()
  end

  defp fallback_params(params, fallback_model) do
    params
    |> Map.put("model", fallback_model)
    |> cap_fallback_tokens()
    |> Map.put("reasoning_effort", @fallback_reasoning_effort)
  end

  defp cap_primary_tokens(params) when is_map(params) do
    cap = primary_max_tokens()

    params
    |> cap_token_key("max_tokens", cap)
    |> cap_token_key("max_output_tokens", cap)
  end

  defp cap_primary_tokens(params), do: params

  defp cap_fallback_tokens(params) do
    params
    |> cap_token_key("max_tokens", @fallback_max_tokens)
    |> cap_token_key("max_output_tokens", @fallback_max_tokens)
  end

  defp cap_token_key(params, key, cap) do
    case Map.get(params, key) do
      value when is_integer(value) and value > cap ->
        params
        |> Map.put(key, cap)
        |> note_token_cap(key, value, cap)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > cap ->
            params
            |> Map.put(key, cap)
            |> note_token_cap(key, parsed, cap)

          _other ->
            params
        end

      _other ->
        params
    end
  end

  defp note_token_cap(params, key, original, cap) do
    Logger.info("Capped oversized LLM effect request",
      token_key: key,
      original: original,
      cap: cap
    )

    params
  end

  defp primary_max_tokens do
    :maraithon
    |> Application.get_env(Maraithon.Runtime, [])
    |> Keyword.get(:llm_primary_max_tokens, @default_primary_max_tokens)
    |> positive_integer(@default_primary_max_tokens)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp configured_model_fallbacks do
    :maraithon
    |> Application.get_env(Maraithon.Runtime, [])
    |> Keyword.get(:llm_model_fallbacks, [])
    |> normalize_string_list()
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_model/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_string_list()
  end

  defp normalize_string_list(_value), do: []

  defp normalize_model(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      model -> model
    end
  end

  defp normalize_model(_value), do: nil

  defp transient_capacity_error?({:rate_limited, _}), do: true
  defp transient_capacity_error?(:timeout), do: true
  defp transient_capacity_error?({:network_error, _}), do: true

  defp transient_capacity_error?({:api_error, status, _}) when status in [500, 502, 503, 504],
    do: true

  defp transient_capacity_error?(_), do: false

  defp provider_deferral_error?({:rate_limited, _retry_after}), do: true
  defp provider_deferral_error?({:llm_busy, _retry_after}), do: true
  defp provider_deferral_error?(_reason), do: false

  defp record_provider_limit({:rate_limited, retry_after_ms}) do
    LLMRateLimiter.record_rate_limit(retry_after_ms)
  end

  defp record_provider_limit(_reason), do: :ok

  defp retry_backoff_ms(_reason, attempt) when attempt >= @max_retry_attempts, do: nil

  defp retry_backoff_ms({:rate_limited, retry_after}, _attempt)
       when is_integer(retry_after) and retry_after > 0,
       do: inline_rate_limit_backoff_ms(retry_after)

  defp retry_backoff_ms({:rate_limited, _}, _attempt),
    do: inline_rate_limit_backoff_ms(@default_rate_limited_backoff_ms)

  defp retry_backoff_ms(:timeout, _attempt), do: 5_000

  defp retry_backoff_ms({:network_error, _reason}, attempt), do: 2_000 * attempt

  defp retry_backoff_ms({:api_error, status, _body}, attempt)
       when status in [500, 502, 503, 504],
       do: 2_000 * attempt

  defp retry_backoff_ms(_reason, _attempt), do: nil

  defp inline_rate_limit_backoff_ms(retry_after_ms)
       when retry_after_ms <= @max_inline_rate_limit_retry_ms do
    min(retry_after_ms, @max_retry_after_ms)
  end

  defp inline_rate_limit_backoff_ms(_retry_after_ms), do: nil

  defp ensure_usage(%{usage: %{} = usage} = data) do
    model = Map.get(data, :model, "unknown")
    tokens_in = Map.get(data, :tokens_in, 0)
    tokens_out = Map.get(data, :tokens_out, 0)

    normalized_usage =
      usage
      |> normalize_usage_value(:input_tokens, tokens_in)
      |> normalize_usage_value(:output_tokens, tokens_out)
      |> normalize_usage_value(:total_tokens, tokens_in + tokens_out)
      |> normalize_usage_value(
        :total_cost,
        Spend.calculate_cost(model, tokens_in, tokens_out).total_cost
      )

    %{data | usage: normalized_usage}
  end

  defp ensure_usage(data) do
    model = Map.get(data, :model, "unknown")
    tokens_in = Map.get(data, :tokens_in, 0)
    tokens_out = Map.get(data, :tokens_out, 0)

    Map.put(data, :usage, Spend.calculate_cost(model, tokens_in, tokens_out))
  end

  defp normalize_usage_value(usage, key, fallback) do
    case Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) do
      nil -> Map.put(usage, key, fallback)
      _value -> usage
    end
  end
end
