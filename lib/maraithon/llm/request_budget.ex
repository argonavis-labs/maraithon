defmodule Maraithon.LLM.RequestBudget do
  @moduledoc false

  alias Maraithon.TelegramAssistant.ProactiveCandidate

  @max_request_bytes 128_000
  @max_messages 64
  @max_tools 64
  @allowed_keys ~w(
    messages model max_tokens max_output_tokens temperature reasoning_effort timeout_ms
    tools tool_choice response_format reasoning stream top_p seed presence_penalty frequency_penalty
    parallel_tool_calls structured_outputs logprobs top_logprobs
  )

  def validate_body(body) when is_map(body) do
    with true <- ProactiveCandidate.safe_json_shape?(body, @max_request_bytes),
         {:ok, encoded} <- Jason.encode(body),
         true <- byte_size(encoded) <= @max_request_bytes do
      :ok
    else
      _invalid -> {:error, {:invalid_request, %{reason: "provider_body_exceeds_budget"}}}
    end
  end

  def validate_body(_body), do: {:error, {:invalid_request, %{reason: "invalid_provider_body"}}}

  def validate(params) when is_map(params) do
    bounded =
      @allowed_keys
      |> Enum.reduce(%{}, fn key, acc ->
        case fetch(params, key) do
          :missing -> acc
          value -> Map.put(acc, key, value)
        end
      end)
      |> cap_positive_integer("max_tokens", 32_000)
      |> cap_positive_integer("max_output_tokens", 32_000)
      |> cap_positive_integer("timeout_ms", 300_000)
      |> normalize_model()
      |> normalize_temperature()
      |> normalize_reasoning_effort()
      |> normalize_reasoning()
      |> normalize_stream()

    with :ok <- validate_messages(bounded["messages"]),
         :ok <- validate_tools(bounded["tools"]),
         :ok <- validate_model(bounded["model"]),
         :ok <- validate_token_count(bounded["max_tokens"]),
         :ok <- validate_token_count(bounded["max_output_tokens"]),
         :ok <- validate_temperature(bounded["temperature"]),
         :ok <- validate_timeout(bounded["timeout_ms"]),
         :ok <- validate_reasoning_effort(bounded["reasoning_effort"]),
         :ok <- validate_reasoning(bounded["reasoning"]),
         :ok <- validate_stream(bounded["stream"]),
         true <- ProactiveCandidate.safe_json_shape?(bounded, @max_request_bytes),
         {:ok, encoded} <- Jason.encode(bounded),
         true <- byte_size(encoded) <= @max_request_bytes do
      {:ok, maybe_put_reasoning_callback(bounded, params)}
    else
      _invalid -> {:error, {:invalid_request, %{reason: "request_exceeds_budget"}}}
    end
  end

  def validate(_params), do: {:error, {:invalid_request, %{reason: "invalid_request_shape"}}}

  defp cap_positive_integer(params, key, cap) do
    case Map.get(params, key) do
      nil -> params
      value when is_integer(value) and value > 0 -> Map.put(params, key, min(value, cap))
      _invalid -> Map.delete(params, key)
    end
  end

  defp normalize_model(params) do
    case Map.get(params, "model") do
      nil ->
        params

      value when is_binary(value) and byte_size(value) <= 255 ->
        if String.valid?(value),
          do: Map.put(params, "model", String.trim(value)),
          else: Map.delete(params, "model")

      _invalid ->
        Map.delete(params, "model")
    end
  end

  defp normalize_temperature(params) do
    case Map.get(params, "temperature") do
      nil -> params
      value when is_integer(value) and value >= 0 and value <= 2 -> params
      value when is_float(value) and value >= 0.0 and value <= 2.0 -> params
      _invalid -> Map.delete(params, "temperature")
    end
  end

  defp normalize_reasoning_effort(params) do
    case Map.get(params, "reasoning_effort") do
      nil ->
        params

      value when value in ["none", "off", "minimal", "low", "medium", "high", "xhigh", false] ->
        params

      _invalid ->
        Map.delete(params, "reasoning_effort")
    end
  end

  defp normalize_reasoning(params) do
    case Map.get(params, "reasoning") do
      nil ->
        params

      reasoning when is_map(reasoning) ->
        normalized =
          %{}
          |> maybe_put_reasoning_effort(fetch(reasoning, "effort"))
          |> maybe_put_reasoning_tokens(fetch(reasoning, "max_tokens"))
          |> maybe_put_reasoning_boolean("exclude", fetch(reasoning, "exclude"))
          |> maybe_put_reasoning_boolean("enabled", fetch(reasoning, "enabled"))

        if map_size(normalized) == 0,
          do: Map.delete(params, "reasoning"),
          else: Map.put(params, "reasoning", normalized)

      _invalid ->
        Map.delete(params, "reasoning")
    end
  end

  defp maybe_put_reasoning_effort(acc, value)
       when value in ["none", "off", "minimal", "low", "medium", "high", "xhigh"] do
    Map.put(acc, "effort", value)
  end

  defp maybe_put_reasoning_effort(acc, _value), do: acc

  defp maybe_put_reasoning_tokens(acc, value) when is_integer(value) and value > 0,
    do: Map.put(acc, "max_tokens", min(value, 32_000))

  defp maybe_put_reasoning_tokens(acc, _value), do: acc

  defp maybe_put_reasoning_boolean(acc, key, value) when is_boolean(value),
    do: Map.put(acc, key, value)

  defp maybe_put_reasoning_boolean(acc, _key, _value), do: acc

  defp normalize_stream(params) do
    case Map.get(params, "stream") do
      nil -> params
      value when is_boolean(value) -> params
      _invalid -> Map.delete(params, "stream")
    end
  end

  defp validate_messages(nil), do: :ok

  defp validate_messages(messages) when is_list(messages) do
    if bounded_list?(messages, @max_messages), do: :ok, else: :error
  end

  defp validate_messages(_messages), do: :error

  defp validate_tools(nil), do: :ok

  defp validate_tools(tools) when is_list(tools),
    do: if(bounded_list?(tools, @max_tools), do: :ok, else: :error)

  defp validate_tools(_tools), do: :error

  defp bounded_list?(list, limit) do
    length(Enum.take(list, limit + 1)) <= limit
  rescue
    _error -> false
  end

  defp validate_model(nil), do: :ok
  defp validate_model(model) when is_binary(model) and byte_size(model) <= 255, do: :ok
  defp validate_model(_model), do: :error

  defp validate_token_count(nil), do: :ok

  defp validate_token_count(value) when is_integer(value) and value > 0 and value <= 32_000,
    do: :ok

  defp validate_token_count(_value), do: :error

  defp validate_temperature(nil), do: :ok
  defp validate_temperature(value) when is_integer(value) and value >= 0 and value <= 2, do: :ok
  defp validate_temperature(value) when is_float(value) and value >= 0.0 and value <= 2.0, do: :ok
  defp validate_temperature(_value), do: :error

  defp validate_reasoning_effort(nil), do: :ok

  defp validate_reasoning_effort(value)
       when value in ["none", "off", "minimal", "low", "medium", "high", "xhigh", false],
       do: :ok

  defp validate_reasoning_effort(_value), do: :error

  defp validate_reasoning(nil), do: :ok

  defp validate_reasoning(reasoning) when is_map(reasoning) do
    if Map.keys(reasoning) -- ~w(effort max_tokens exclude enabled) == [], do: :ok, else: :error
  end

  defp validate_reasoning(_reasoning), do: :error

  defp validate_stream(nil), do: :ok
  defp validate_stream(value) when is_boolean(value), do: :ok
  defp validate_stream(_value), do: :error

  defp validate_timeout(nil), do: :ok
  defp validate_timeout(value) when is_integer(value) and value > 0 and value <= 300_000, do: :ok
  defp validate_timeout(_value), do: :error

  defp maybe_put_reasoning_callback(bounded, params) do
    callback = Map.get(params, "_on_reasoning", Map.get(params, :_on_reasoning))
    if is_function(callback, 1), do: Map.put(bounded, "_on_reasoning", callback), else: bounded
  end

  defp fetch(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> fetch_atom(params, key)
    end
  end

  defp fetch_atom(params, "messages"), do: Map.get(params, :messages, :missing)
  defp fetch_atom(params, "model"), do: Map.get(params, :model, :missing)
  defp fetch_atom(params, "max_tokens"), do: Map.get(params, :max_tokens, :missing)
  defp fetch_atom(params, "max_output_tokens"), do: Map.get(params, :max_output_tokens, :missing)
  defp fetch_atom(params, "temperature"), do: Map.get(params, :temperature, :missing)
  defp fetch_atom(params, "reasoning_effort"), do: Map.get(params, :reasoning_effort, :missing)
  defp fetch_atom(params, "timeout_ms"), do: Map.get(params, :timeout_ms, :missing)
  defp fetch_atom(params, "tools"), do: Map.get(params, :tools, :missing)
  defp fetch_atom(params, "tool_choice"), do: Map.get(params, :tool_choice, :missing)
  defp fetch_atom(params, "response_format"), do: Map.get(params, :response_format, :missing)
  defp fetch_atom(params, "reasoning"), do: Map.get(params, :reasoning, :missing)
  defp fetch_atom(params, "stream"), do: Map.get(params, :stream, :missing)
  defp fetch_atom(_params, _key), do: :missing
end
