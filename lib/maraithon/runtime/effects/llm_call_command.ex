defmodule Maraithon.Runtime.Effects.LLMCallCommand do
  @moduledoc """
  Command implementation for `llm_call` effects.

  Retries transient provider errors (`{:rate_limited, retry_after}`, network
  blips, 5xx API errors, timeouts) up to `@max_retry_attempts` times. Without
  this, a single 60-second rate-limit would turn an entire scheduled morning
  briefing into a user-facing failure message — the LLM provider already told
  us when to come back.
  """

  @behaviour Maraithon.Runtime.Effects.Command

  alias Maraithon.LLM
  alias Maraithon.Effects.Effect
  alias Maraithon.Spend

  require Logger

  # Total attempts including the first call. 3 = first try + 2 retries.
  @max_retry_attempts 3
  # Hard ceiling on a single retry-after to keep the effect process from
  # blocking on the provider for an unreasonable stretch.
  @max_retry_after_ms 120_000
  # Fallback when the provider gives a non-integer retry-after.
  @default_rate_limited_backoff_ms 30_000

  @impl true
  def execute(%Effect{} = effect) do
    params = effect.params
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
        case retry_backoff_ms(reason, attempt) do
          nil ->
            # Same-model retries are spent. For transient errors that look
            # like a model-scoped capacity issue (rate_limit, 5xx, network),
            # try once more with the cheaper chat-tier model so the brief
            # still delivers something useful instead of failing entirely.
            maybe_try_chat_fallback(params, effect, reason)

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

  defp maybe_try_chat_fallback(params, effect, original_reason) do
    chat_model = LLM.chat_model()
    current_model = Map.get(params, "model")

    cond do
      not transient_capacity_error?(original_reason) ->
        {:error, original_reason}

      is_nil(chat_model) ->
        {:error, original_reason}

      current_model == chat_model ->
        # Already running on the fallback tier — nowhere else to go.
        {:error, original_reason}

      true ->
        Logger.info(
          "LLM primary exhausted; falling back to chat-tier model",
          effect_id: effect.id,
          original_reason: inspect(original_reason),
          fallback_model: chat_model
        )

        case LLM.complete(Map.put(params, "model", chat_model)) do
          {:ok, _data} = ok -> ok
          {:error, _fallback_reason} -> {:error, original_reason}
        end
    end
  end

  defp transient_capacity_error?({:rate_limited, _}), do: true
  defp transient_capacity_error?(:timeout), do: true
  defp transient_capacity_error?({:network_error, _}), do: true

  defp transient_capacity_error?({:api_error, status, _}) when status in [500, 502, 503, 504],
    do: true

  defp transient_capacity_error?(_), do: false

  defp retry_backoff_ms(_reason, attempt) when attempt >= @max_retry_attempts, do: nil

  defp retry_backoff_ms({:rate_limited, retry_after}, _attempt)
       when is_integer(retry_after) and retry_after > 0,
       do: min(retry_after, @max_retry_after_ms)

  defp retry_backoff_ms({:rate_limited, _}, _attempt), do: @default_rate_limited_backoff_ms

  defp retry_backoff_ms(:timeout, _attempt), do: 5_000

  defp retry_backoff_ms({:network_error, _reason}, attempt), do: 2_000 * attempt

  defp retry_backoff_ms({:api_error, status, _body}, attempt)
       when status in [500, 502, 503, 504],
       do: 2_000 * attempt

  defp retry_backoff_ms(_reason, _attempt), do: nil

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
