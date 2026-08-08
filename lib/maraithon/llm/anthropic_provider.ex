defmodule Maraithon.LLM.AnthropicProvider do
  @moduledoc """
  Anthropic Claude API provider.
  """

  @behaviour Maraithon.LLM.Adapter

  require Logger

  alias Maraithon.LLM.BoundedResponse
  alias Maraithon.LLM.RequestBudget
  alias Maraithon.Tracing

  @default_base_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @cache_min_chars 1024
  @max_response_body_bytes 512_000

  @impl true
  def complete(params) do
    with {:ok, bounded_params} <- RequestBudget.validate(params) do
      api_key = Maraithon.LLM.anthropic_api_key()

      unless valid_api_key?(api_key) do
        {:error, "ANTHROPIC_API_KEY not configured"}
      else
        do_complete(bounded_params, api_key)
      end
    end
  end

  @doc false
  def build_body(params) when is_map(params) do
    model =
      configured_model(
        params["model"] || Maraithon.LLM.anthropic_model(),
        "claude-sonnet-4-20250514"
      )

    raw_messages = params["messages"] || []
    max_tokens = params["max_tokens"] || 2048
    temperature = params["temperature"] || 0.7

    {system_blocks, conversation_messages} = split_system_messages(raw_messages)

    base = %{
      model: model,
      messages: conversation_messages,
      max_tokens: max_tokens,
      temperature: temperature
    }

    case system_blocks do
      [] -> base
      blocks -> Map.put(base, :system, blocks)
    end
  end

  defp do_complete(params, api_key) do
    body = build_body(params)
    model = body.model

    with :ok <- RequestBudget.validate_body(body) do
      Tracing.with_span("llm.request", request_span_attributes(body, model), fn ->
        do_request(body, model, params, api_key)
      end)
    end
  end

  defp request_span_attributes(body, model) do
    %{
      provider: "anthropic",
      model: model,
      message_count: length(body.messages),
      max_tokens: body.max_tokens,
      temperature: body.temperature,
      cache_blocks: count_cache_blocks(body)
    }
  end

  defp do_request(body, model, params, api_key) do
    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]

    timeout = request_timeout(params["timeout_ms"])

    Logger.info("Calling Anthropic API",
      model: model,
      message_count: length(body.messages),
      cache_blocks: count_cache_blocks(body)
    )

    request = fn ->
      Req.post(base_url(),
        json: body,
        headers: headers,
        receive_timeout: timeout,
        decode_body: false,
        compressed: false,
        into: BoundedResponse.collector(@max_response_body_bytes)
      )
    end

    case BoundedResponse.run(request, timeout) do
      {:ok, %{status: 200} = response} ->
        parse_bounded_response(response)

      {:ok, %{status: 429} = response} ->
        retry_after = response |> decode_bounded_error_body() |> extract_retry_after()
        Logger.warning("Rate limited, retry after #{retry_after}ms")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: status}} ->
        Logger.error("Anthropic API error", status: status, failure_code: "api_error")
        {:error, {:api_error, status, :redacted}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("Anthropic API timeout")
        {:error, :timeout}

      {:error, reason} ->
        failure_code = Maraithon.Redaction.error_class(reason)
        Logger.error("Anthropic API network error", failure_code: failure_code)
        {:error, {:network_error, failure_code}}
    end
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
    content =
      case response["content"] do
        [%{"type" => "text", "text" => text} | _] when is_binary(text) -> text
        _other -> ""
      end

    model = safe_model(response["model"])
    response_type = response["type"]
    stop_reason = safe_finish_reason(response["stop_reason"])
    input_tokens = safe_token_count(get_in(response, ["usage", "input_tokens"]))
    output_tokens = safe_token_count(get_in(response, ["usage", "output_tokens"]))
    cache_read = safe_token_count(get_in(response, ["usage", "cache_read_input_tokens"]))
    cache_write = safe_token_count(get_in(response, ["usage", "cache_creation_input_tokens"]))

    cond do
      response_type != "message" ->
        {:error, {:invalid_response, %{reason: "invalid_response_type"}}}

      stop_reason == "refusal" ->
        {:error, {:provider_refusal, :redacted}}

      stop_reason == "max_tokens" ->
        {:error, {:incomplete_response, %{reason: "provider_incomplete"}}}

      stop_reason not in ["end_turn", "stop_sequence"] ->
        {:error, {:invalid_response, %{reason: "invalid_stop_reason"}}}

      content == "" ->
        {:error, {:invalid_response, %{reason: "missing_content"}}}

      byte_size(content) > 128_000 ->
        {:error, {:invalid_response, %{reason: "response_content_too_large"}}}

      true ->
        usage =
          Maraithon.Spend.calculate_cost(model, input_tokens, output_tokens)
          |> Map.put(:cache_read_input_tokens, cache_read)
          |> Map.put(:cache_creation_input_tokens, cache_write)

        Logger.info("LLM call completed",
          model: model,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cache_read_input_tokens: cache_read,
          cache_creation_input_tokens: cache_write,
          cost_usd: usage.total_cost
        )

        {:ok,
         %{
           content: content,
           model: model,
           tokens_in: input_tokens,
           tokens_out: output_tokens,
           finish_reason: safe_finish_reason(response["stop_reason"]),
           usage: usage
         }}
    end
  end

  defp parse_response(_response),
    do: {:error, {:invalid_response, %{reason: "invalid_response_shape"}}}

  defp safe_model(value) when is_binary(value) and byte_size(value) <= 160 do
    value = String.trim(value)
    if Regex.match?(~r/\A[A-Za-z0-9._:\/-]{1,160}\z/, value), do: value, else: "unknown"
  end

  defp safe_model(_value), do: "unknown"

  defp safe_finish_reason(value) when is_binary(value) and byte_size(value) <= 50 do
    if Regex.match?(~r/\A[A-Za-z0-9._-]{1,50}\z/, value), do: value, else: "unknown"
  end

  defp safe_finish_reason(_value), do: "unknown"

  defp safe_token_count(value) when is_integer(value) and value >= 0,
    do: min(value, 100_000_000)

  defp safe_token_count(value) when is_float(value) and value >= 0,
    do: value |> trunc() |> safe_token_count()

  defp safe_token_count(_value), do: 0

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

  defp extract_retry_after(%{"error" => %{"message" => message}})
       when is_binary(message) and byte_size(message) <= 4_096 do
    case Regex.run(~r/retry after ([0-9]{1,8})/i, message) do
      [_, seconds] -> min(String.to_integer(seconds) * 1_000, 86_400_000)
      _ -> 60_000
    end
  end

  defp extract_retry_after(_body), do: 60_000

  defp base_url do
    value =
      Application.get_env(:maraithon, :anthropic, [])
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

  defp split_system_messages(messages) when is_list(messages) do
    {system_text_parts, conversation} =
      Enum.reduce(messages, {[], []}, fn message, {sys_acc, conv_acc} ->
        case classify_message(message) do
          {:system, text} when is_binary(text) and text != "" ->
            {[text | sys_acc], conv_acc}

          {:keep, normalized} ->
            {sys_acc, [normalized | conv_acc]}

          :skip ->
            {sys_acc, conv_acc}
        end
      end)

    system_blocks =
      system_text_parts
      |> Enum.reverse()
      |> build_system_blocks()

    {system_blocks, Enum.reverse(conversation)}
  end

  defp classify_message(%{"role" => "system", "content" => content}),
    do: {:system, message_text(content)}

  defp classify_message(%{role: "system", content: content}),
    do: {:system, message_text(content)}

  defp classify_message(%{"role" => role, "content" => _} = message)
       when role in ["user", "assistant"],
       do: {:keep, message}

  defp classify_message(%{role: role, content: content}) when role in ["user", "assistant"] do
    {:keep, %{"role" => role, "content" => content}}
  end

  defp classify_message(_other), do: :skip

  defp message_text(content) when is_binary(content), do: content

  defp message_text(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _other -> ""
    end)
  end

  defp message_text(_other), do: ""

  defp build_system_blocks([]), do: []

  defp build_system_blocks(parts) do
    text = parts |> Enum.join("\n\n") |> String.trim()

    cond do
      text == "" ->
        []

      String.length(text) >= @cache_min_chars ->
        [
          %{
            type: "text",
            text: text,
            cache_control: %{type: "ephemeral"}
          }
        ]

      true ->
        [%{type: "text", text: text}]
    end
  end

  defp count_cache_blocks(%{system: system}) when is_list(system) do
    Enum.count(system, fn
      %{cache_control: _} -> true
      _ -> false
    end)
  end

  defp count_cache_blocks(_body), do: 0
end
