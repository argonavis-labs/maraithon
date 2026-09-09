defmodule Maraithon.LLM.OpenRouterUsage do
  @moduledoc "Bounded per-attempt usage observations, including rejected responses."
  require Logger

  @key {__MODULE__, :observation}

  def measure(model, fun) do
    previous = Process.get(@key)
    Process.put(@key, summary(%{}, model))
    started = System.monotonic_time(:millisecond)
    reference = Ecto.UUID.generate()

    try do
      result = fun.()
      emit(started, reference, if(match?({:ok, _}, result), do: "completed", else: "failed"))
      result
    rescue
      error ->
        emit(started, reference, "failed")
        reraise error, __STACKTRACE__
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  def capture(response, model) do
    observation = summary(response, model)
    if Process.get(@key), do: Process.put(@key, observation)
    observation
  end

  def summary(response, model) do
    raw = object(response, "usage")
    input = tokens(raw["prompt_tokens"] || raw["input_tokens"])
    output = tokens(raw["completion_tokens"] || raw["output_tokens"])
    reported = cost(raw["cost"])

    estimate =
      if is_integer(input) and is_integer(output),
        do: Maraithon.Spend.calculate_cost(model, input, output).total_cost

    %{
      model: model,
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: tokens(object(raw, "prompt_tokens_details")["cached_tokens"]),
      cache_write_tokens: tokens(object(raw, "prompt_tokens_details")["cache_write_tokens"]),
      reasoning_tokens: tokens(object(raw, "completion_tokens_details")["reasoning_tokens"]),
      cost_usd: reported,
      estimated_cost_usd: estimate,
      cost_source:
        cond do
          is_number(reported) -> "provider_reported"
          is_number(estimate) -> "estimated"
          true -> "unavailable"
        end
    }
  end

  def apply_reported_cost(usage, observation) do
    usage
    |> Map.put(:estimated_total_cost, usage.total_cost)
    |> Map.put(:cost_source, observation.cost_source)
    |> Map.put(:reported_cost, observation.cost_usd)
    |> Map.put(:total_cost, observation.cost_usd || usage.total_cost)
  end

  defp emit(started, reference, status) do
    observation = Process.get(@key)
    duration = max(System.monotonic_time(:millisecond) - started, 0)

    fields =
      Map.merge(observation, %{
        duration_ms: duration,
        provider_reference: reference,
        provider: "openrouter",
        status: status
      })

    # A single structured record survives parser/harness rejection. No prompt,
    # provider response body, account identifier or reasoning text is retained.
    Logger.info("LLM attempt measured", Map.to_list(fields))

    :telemetry.execute([:maraithon, :llm, :attempt], fields, %{
      target_reference: Logger.metadata()[:target_reference]
    })
  end

  defp object(map, key) when is_map(map) do
    case map[key] do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp object(_, _), do: %{}
  defp tokens(value) when is_integer(value) and value in 0..1_000_000_000, do: value
  defp tokens(_), do: nil
  defp cost(value) when is_number(value) and value >= 0 and value <= 1_000_000, do: value
  defp cost(_), do: nil
end
