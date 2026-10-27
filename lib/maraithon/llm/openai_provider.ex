defmodule Maraithon.LLM.OpenAIProvider do
  @moduledoc """
  OpenAI Responses API provider.
  """

  @behaviour Maraithon.LLM.Adapter

  alias Maraithon.LLM.BoundedResponse
  alias Maraithon.LLM.RequestBudget
  alias Maraithon.Spend
  alias Maraithon.Tracing

  require Logger

  @default_base_url "https://api.openai.com/v1/responses"
  @default_retry_after_ms 60_000
  @max_retry_after_ms 86_400_000
  @max_response_body_bytes 512_000
  @reasoning_efforts ~w(minimal low medium high xhigh)

  @impl true
  def complete(params) do
    with {:ok, bounded_params} <- RequestBudget.validate(params) do
      api_key = Maraithon.LLM.openai_api_key()

      unless valid_api_key?(api_key) do
        {:error, "OPENAI_API_KEY not configured"}
      else
        do_complete(bounded_params, api_key)
      end
    end
  end

  @impl true
  def stream_complete(params, on_chunk) when is_function(on_chunk, 1) do
    _ = on_chunk

    # The legacy direct OpenAI SSE parser did not provide the bounded, strict
    # termination guarantees required by the streaming contract. Use the
    # bounded non-stream request until that adapter has an equivalent parser.
    complete(params)
  end

  defp do_complete(params, api_key) do
    model = configured_model(params["model"] || Maraithon.LLM.openai_model(), "gpt-5.4")

    Tracing.with_span("llm.request", request_span_attributes(params, model), fn ->
      do_complete_request(params, api_key, model)
    end)
  end

  defp do_complete_request(params, api_key, model) do
    timeout = request_timeout(params["timeout_ms"])

    base_body = %{
      model: model,
      input: build_input(params["messages"] || []),
      max_output_tokens: params["max_tokens"] || params["max_output_tokens"] || 2048
    }

    body =
      case effective_reasoning_effort(params, model) do
        nil -> base_body
        effort -> Map.put(base_body, :reasoning, %{effort: effort})
      end

    with :ok <- RequestBudget.validate_body(body) do
      Logger.info("Calling OpenAI Responses API",
        model: model,
        message_count: length(params["messages"] || []),
        reasoning_effort: Map.get(body, :reasoning, %{}) |> Map.get(:effort, "none")
      )

      request = fn ->
        Req.post(base_url(),
          json: body,
          headers: [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"}
          ],
          receive_timeout: timeout,
          decode_body: false,
          compressed: false,
          into: BoundedResponse.collector(@max_response_body_bytes)
        )
      end

      case BoundedResponse.run(request, timeout) do
        {:ok, %{status: 200} = response} ->
          parse_bounded_response(response)

        {:ok, %{status: 429, headers: headers} = response} ->
          handle_429(headers, decode_bounded_error_body(response), "OpenAI API")

        {:ok, %{status: status}} ->
          Logger.error("OpenAI API error", status: status, failure_code: "api_error")
          {:error, {:api_error, status, :redacted}}

        {:error, %{reason: :timeout}} ->
          Logger.warning("OpenAI API timeout")
          {:error, :timeout}

        {:error, reason} ->
          failure_code = Maraithon.Redaction.error_class(reason)
          Logger.error("OpenAI API network error", failure_code: failure_code)
          {:error, {:network_error, failure_code}}
      end
    end
  end

  defp request_span_attributes(params, model, streaming \\ false) do
    %{
      provider: "openai",
      model: model,
      streaming: streaming,
      message_count: length(params["messages"] || []),
      max_output_tokens: params["max_tokens"] || params["max_output_tokens"] || 2048,
      reasoning_effort: effective_reasoning_effort(params, model) || "none"
    }
  end

  defp parse_bounded_response(response) do
    case BoundedResponse.decode_json(response) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, reason} -> {:error, {:invalid_response, %{reason: to_string(reason)}}}
    end
  end

  defp decode_bounded_error_body(response) do
    case BoundedResponse.decode_json(response) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp parse_response(response) when is_map(response) do
    model = safe_model(response["model"])
    output = response["output"] || []
    output_shape_valid? = bounded_output_shape?(output)
    content = if output_shape_valid?, do: extract_output_text(output), else: ""
    refusal? = output_shape_valid? and provider_refusal?(output)
    finish_reason = safe_finish_reason(response["status"])
    input_tokens = safe_token_count(get_in(response, ["usage", "input_tokens"]))
    output_tokens = safe_token_count(get_in(response, ["usage", "output_tokens"]))

    cond do
      not output_shape_valid? ->
        {:error, {:invalid_response, %{reason: "invalid_output_shape"}}}

      refusal? ->
        {:error, {:provider_refusal, :redacted}}

      finish_reason == "incomplete" ->
        {:error, {:incomplete_response, %{reason: "provider_incomplete"}}}

      finish_reason != "completed" ->
        {:error, {:invalid_response, %{reason: "invalid_response_status"}}}

      content == "" ->
        {:error, {:invalid_response, %{reason: "missing_output_text"}}}

      byte_size(content) > 128_000 ->
        {:error, {:invalid_response, %{reason: "response_content_too_large"}}}

      true ->
        usage = Spend.calculate_cost(model, input_tokens, output_tokens)

        Logger.info("LLM call completed",
          model: model,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost_usd: usage.total_cost
        )

        {:ok,
         %{
           content: content,
           model: model,
           tokens_in: input_tokens,
           tokens_out: output_tokens,
           finish_reason: finish_reason,
           usage: usage
         }}
    end
  end

  defp parse_response(_response),
    do: {:error, {:invalid_response, %{reason: "invalid_response_shape"}}}

  defp extract_output_text(output) when is_list(output) do
    output
    |> Enum.flat_map(fn
      %{"type" => "message", "content" => content} when is_list(content) -> content
      _ -> []
    end)
    |> Enum.map(fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp bounded_output_shape?(output) when is_list(output) do
    prefix = Enum.take(output, 101)

    length(prefix) <= 100 and
      Enum.all?(prefix, fn
        %{"type" => "message", "content" => content} when is_list(content) ->
          length(Enum.take(content, 101)) <= 100

        %{} ->
          true

        _item ->
          false
      end)
  rescue
    _error -> false
  end

  defp bounded_output_shape?(_output), do: false

  defp provider_refusal?(output) when is_list(output) do
    Enum.any?(Enum.take(output, 100), fn
      %{"type" => "message", "content" => content} when is_list(content) ->
        Enum.any?(Enum.take(content, 100), fn
          %{"type" => "refusal"} -> true
          _block -> false
        end)

      %{"type" => "refusal"} ->
        true

      _item ->
        false
    end)
  end

  defp provider_refusal?(_output), do: false

  defp safe_model(value) when is_binary(value) and byte_size(value) <= 160 do
    value = String.trim(value)
    if Regex.match?(~r/\A[A-Za-z0-9._:\/-]{1,160}\z/, value), do: value, else: "unknown"
  end

  defp safe_model(_value), do: "unknown"

  defp safe_finish_reason(value) when value in ["completed", "incomplete", "failed"], do: value
  defp safe_finish_reason(_value), do: "unknown"

  defp safe_token_count(value) when is_integer(value) and value >= 0,
    do: min(value, 100_000_000)

  defp safe_token_count(value) when is_float(value) and value >= 0,
    do: value |> trunc() |> safe_token_count()

  defp safe_token_count(_value), do: 0

  defp build_input(messages) when is_list(messages) do
    Enum.map(messages, &normalize_message/1)
  end

  defp normalize_message(%{"role" => role, "content" => content}) do
    %{
      role: normalize_role(role),
      content: [%{type: "input_text", text: normalize_content(content)}]
    }
  end

  defp normalize_message(%{role: role, content: content}) do
    %{
      role: normalize_role(role),
      content: [%{type: "input_text", text: normalize_content(content)}]
    }
  end

  defp normalize_message(message) when is_binary(message) do
    %{
      role: "user",
      content: [%{type: "input_text", text: message}]
    }
  end

  defp normalize_message(_message) do
    %{
      role: "user",
      content: [%{type: "input_text", text: ""}]
    }
  end

  defp normalize_role(role) when role in ["system", "user", "assistant"], do: role
  defp normalize_role(role) when role in [:system, :user, :assistant], do: Atom.to_string(role)
  defp normalize_role(_role), do: "user"

  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _other -> ""
    end)
  end

  defp normalize_content(_content), do: ""

  defp effective_reasoning_effort(params, model) do
    cond do
      not reasoning_capable_model?(model) ->
        nil

      Map.get(params, "reasoning_effort") in ["none", "off", false, nil] and
          Map.has_key?(params, "reasoning_effort") ->
        nil

      true ->
        reasoning_effort(params)
    end
  end

  # gpt-4o, gpt-4.1 and the chat-completions style models in the Responses API
  # reject `reasoning.effort`. Only the o-series and gpt-5 reasoning models
  # accept it.
  defp reasoning_capable_model?(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "gpt-5") -> true
      String.starts_with?(model, "o1") -> true
      String.starts_with?(model, "o3") -> true
      String.starts_with?(model, "o4") -> true
      true -> false
    end
  end

  defp reasoning_capable_model?(_model), do: false

  defp reasoning_effort(%{"reasoning_effort" => effort}), do: validate_reasoning_effort(effort)

  defp reasoning_effort(%{"reasoning" => %{"effort" => effort}}),
    do: validate_reasoning_effort(effort)

  defp reasoning_effort(_params),
    do: validate_reasoning_effort(Maraithon.LLM.openai_reasoning_effort())

  defp validate_reasoning_effort(effort) when is_binary(effort) and byte_size(effort) <= 32 do
    normalized = String.downcase(String.trim(effort))

    if normalized in @reasoning_efforts do
      normalized
    else
      "high"
    end
  end

  defp validate_reasoning_effort(_effort), do: "high"

  defp configured_model(value, default)
       when is_binary(value) and byte_size(value) <= 160 do
    if String.valid?(value) do
      model = String.trim(value)
      if Regex.match?(~r/\A[A-Za-z0-9._:\/-]{1,160}\z/, model), do: model, else: default
    else
      default
    end
  end

  defp configured_model(_value, default), do: default

  defp valid_api_key?(value),
    do:
      is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value) and
        not String.contains?(value, ["\r", "\n"])

  defp request_timeout(value) when is_integer(value) and value > 0,
    do: min(value, 300_000)

  defp request_timeout(_value), do: 120_000

  defp extract_retry_after(headers, body) do
    cond do
      value = header_value(headers, "retry-after-ms") -> parse_retry_after(value, :milliseconds)
      value = header_value(headers, "retry-after") -> parse_retry_after(value, :seconds)
      true -> extract_retry_after_from_body(body)
    end
  end

  defp header_value(headers, name) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {^name, value} ->
        value

      {key, value} when is_binary(key) ->
        if String.downcase(key) == name, do: value

      _ ->
        nil
    end)
  end

  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) || Map.get(headers, String.downcase(name)) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp parse_retry_after(value, unit) when is_binary(value) and byte_size(value) <= 32 do
    multiplier = if(unit == :milliseconds, do: 1, else: 1_000)

    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed * multiplier, @max_retry_after_ms)
      _ -> @default_retry_after_ms
    end
  end

  defp parse_retry_after(_value, _unit), do: @default_retry_after_ms

  defp extract_retry_after_from_body(%{"error" => %{"message" => message}})
       when is_binary(message) and byte_size(message) <= 4_096 do
    case Regex.run(~r/retry after ([0-9]{1,8})/i, message) do
      [_, seconds] -> min(String.to_integer(seconds) * 1_000, @max_retry_after_ms)
      _ -> @default_retry_after_ms
    end
  end

  defp extract_retry_after_from_body(_body), do: @default_retry_after_ms

  defp handle_429(headers, body, log_context) do
    case quota_error(body) do
      {:insufficient_quota, _detail} ->
        Logger.error("#{log_context} quota exceeded", failure_code: "insufficient_quota")
        {:error, {:insufficient_quota, "Provider quota exceeded"}}

      nil ->
        retry_after = extract_retry_after(headers, body)
        Logger.warning("Rate limited, retry after #{retry_after}ms")
        {:error, {:rate_limited, retry_after}}
    end
  end

  defp quota_error(%{"error" => %{} = error}) do
    code = normalize_error_field(Map.get(error, "code"))
    type = normalize_error_field(Map.get(error, "type"))

    if "insufficient_quota" in [code, type] do
      {:insufficient_quota, :redacted}
    end
  end

  defp quota_error(_body), do: nil

  defp normalize_error_field(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_error_field(_value), do: nil

  defp base_url do
    value =
      Application.get_env(:maraithon, :openai, [])
      |> Keyword.get(:base_url, @default_base_url)

    if valid_base_url?(value), do: value, else: @default_base_url
  end

  defp valid_base_url?(value)
       when is_binary(value) and byte_size(value) <= 2_048 do
    if String.valid?(value) do
      case URI.parse(value) do
        %URI{scheme: scheme, host: host, userinfo: nil}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          true

        _other ->
          false
      end
    else
      false
    end
  rescue
    _error -> false
  end

  defp valid_base_url?(_value), do: false
end
