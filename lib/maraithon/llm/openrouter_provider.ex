defmodule Maraithon.LLM.OpenRouterProvider do
  @moduledoc """
  OpenRouter chat completions provider.

  OpenRouter exposes an OpenAI-compatible chat completions endpoint. This module
  adapts the app's existing LLM provider contract to that endpoint without
  changing the higher-level routing and assistant code.
  """

  @behaviour Maraithon.LLM.Adapter

  alias Maraithon.Spend
  alias Maraithon.Tracing

  require Logger

  @default_base_url "https://openrouter.ai/api/v1/chat/completions"
  @default_retry_after_ms 60_000
  @reasoning_efforts ~w(minimal low medium high xhigh)
  @forwarded_params [
    {"top_p", :top_p},
    {"seed", :seed},
    {"presence_penalty", :presence_penalty},
    {"frequency_penalty", :frequency_penalty},
    {"response_format", :response_format},
    {"tools", :tools},
    {"tool_choice", :tool_choice},
    {"parallel_tool_calls", :parallel_tool_calls},
    {"structured_outputs", :structured_outputs},
    {"logprobs", :logprobs},
    {"top_logprobs", :top_logprobs}
  ]

  @impl true
  def complete(params) do
    api_key = Maraithon.LLM.openrouter_api_key()

    if blank?(api_key) do
      {:error, "OPENROUTER_API_KEY not configured"}
    else
      do_complete(params, api_key)
    end
  end

  @impl true
  def stream_complete(params, on_chunk) when is_function(on_chunk, 1) do
    api_key = Maraithon.LLM.openrouter_api_key()

    if blank?(api_key) do
      {:error, "OPENROUTER_API_KEY not configured"}
    else
      do_stream_complete(params, api_key, on_chunk)
    end
  end

  defp do_complete(params, api_key) do
    body = build_body(params)
    model = body.model

    Tracing.with_span("llm.request", request_span_attributes(body, false), fn ->
      do_complete_request(body, params, api_key, model)
    end)
  end

  defp do_complete_request(body, params, api_key, model) do
    timeout = params["timeout_ms"] || 120_000

    Logger.info("Calling OpenRouter Chat Completions API",
      model: model,
      message_count: length(body.messages),
      reasoning_effort: get_in(body, [:reasoning, :effort]) || "none"
    )

    case Req.post(base_url(),
           json: body,
           headers: headers(api_key),
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: response}} ->
        parse_response(response)

      {:ok, %{status: 402, body: body}} ->
        handle_quota_error(body)

      {:ok, %{status: 429, headers: headers, body: body}} ->
        handle_429(headers, body)

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenRouter API error", status: status, body: inspect(body))
        {:error, {:api_error, status, body}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("OpenRouter API timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("OpenRouter API network error", reason: inspect(reason))
        {:error, {:network_error, reason}}
    end
  end

  defp do_stream_complete(params, api_key, on_chunk) do
    # Optional callback for model reasoning deltas; never sent to the API.
    {on_reasoning, params} = Map.pop(params, "_on_reasoning")

    body =
      params
      |> build_body()
      |> Map.put(:stream, true)

    model = body.model

    Tracing.with_span("llm.request", request_span_attributes(body, true), fn ->
      do_stream_request(body, params, api_key, {on_chunk, on_reasoning}, model)
    end)
  end

  defp do_stream_request(body, params, api_key, on_chunk, model) do
    timeout = params["timeout_ms"] || 120_000

    Logger.info("Calling OpenRouter Chat Completions API (streaming)",
      model: model,
      message_count: length(body.messages),
      reasoning_effort: get_in(body, [:reasoning, :effort]) || "none"
    )

    request =
      Req.post(base_url(),
        json: body,
        headers: [{"accept", "text/event-stream"} | headers(api_key)],
        receive_timeout: timeout,
        into: stream_collector(on_chunk)
      )

    case request do
      {:ok, %{status: 200, private: %{stream_acc: acc}}} ->
        finalize_stream(acc, model)

      {:ok, %{status: 402, body: body}} ->
        handle_quota_error(body)

      {:ok, %{status: 429, headers: headers, body: body}} ->
        handle_429(headers, body)

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenRouter API stream error", status: status, body: inspect(body))
        {:error, {:api_error, status, body}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("OpenRouter API stream timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("OpenRouter API stream network error", reason: inspect(reason))
        {:error, {:network_error, reason}}
    end
  end

  defp build_body(params) when is_map(params) do
    model = params["model"] || Maraithon.LLM.openrouter_model()

    %{
      model: model,
      messages: normalize_messages(params["messages"] || []),
      max_tokens: params["max_tokens"] || params["max_output_tokens"] || 2048,
      temperature: params["temperature"] || 0.7
    }
    |> maybe_put_reasoning(params)
    |> forward_params(params)
  end

  defp request_span_attributes(body, streaming) do
    %{
      provider: "openrouter",
      model: body.model,
      streaming: streaming,
      message_count: length(body.messages),
      max_tokens: body.max_tokens,
      temperature: body.temperature,
      reasoning_effort: get_in(body, [:reasoning, :effort]) || "none"
    }
  end

  defp parse_response(response) do
    model = response["model"] || "unknown"
    content = extract_message_content(response["choices"] || [])
    finish_reason = extract_finish_reason(response["choices"] || [])
    input_tokens = usage_value(response, "prompt_tokens", "input_tokens")
    output_tokens = usage_value(response, "completion_tokens", "output_tokens")
    usage = Spend.calculate_cost(model, input_tokens, output_tokens)

    if content != "" do
      Logger.info("LLM call completed",
        provider: "openrouter",
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
    else
      {:error, {:invalid_response, response}}
    end
  end

  defp extract_message_content([%{"message" => %{"content" => content}} | _]) do
    normalize_content(content)
  end

  defp extract_message_content(_choices), do: ""

  defp extract_finish_reason([%{"finish_reason" => reason} | _]) when is_binary(reason),
    do: reason

  defp extract_finish_reason(_choices), do: "unknown"

  defp usage_value(response, primary_key, fallback_key) do
    get_in(response, ["usage", primary_key]) || get_in(response, ["usage", fallback_key]) || 0
  end

  defp stream_collector(callbacks) do
    callbacks = normalize_stream_callbacks(callbacks)

    fn {:data, data}, {req, resp} ->
      acc =
        Map.get(resp.private, :stream_acc, %{
          buffer: "",
          text: "",
          model: nil,
          finish_reason: nil,
          usage: nil
        })

      next_acc =
        acc
        |> Map.update!(:buffer, &(&1 <> data))
        |> drain_events(callbacks)

      {:cont, {req, Req.Response.put_private(resp, :stream_acc, next_acc)}}
    end
  end

  defp normalize_stream_callbacks({on_chunk, on_reasoning}), do: {on_chunk, on_reasoning}
  defp normalize_stream_callbacks(on_chunk), do: {on_chunk, nil}

  defp drain_events(%{buffer: buffer} = acc, callbacks) do
    case :binary.split(buffer, "\n\n") do
      [event_block, rest] ->
        next_acc =
          acc
          |> Map.put(:buffer, rest)
          |> apply_event(event_block, callbacks)

        drain_events(next_acc, callbacks)

      [_partial] ->
        acc
    end
  end

  defp apply_event(acc, event_block, on_chunk) do
    data_lines =
      event_block
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn
        "data: " <> rest -> [rest]
        "data:" <> rest -> [String.trim_leading(rest)]
        _ -> []
      end)

    case data_lines do
      [] ->
        acc

      lines ->
        payload = Enum.join(lines, "\n")

        cond do
          payload == "[DONE]" ->
            acc

          true ->
            case Jason.decode(payload) do
              {:ok, json} -> apply_decoded_event(acc, json, on_chunk)
              {:error, _} -> acc
            end
        end
    end
  end

  defp apply_decoded_event(acc, %{"choices" => choices} = event, {on_chunk, on_reasoning}) do
    delta = extract_stream_delta(choices)

    if delta != "" do
      safe_callback(on_chunk, delta)
    end

    reasoning_delta = extract_reasoning_delta(choices)

    if reasoning_delta != "" and is_function(on_reasoning, 1) do
      safe_callback(on_reasoning, reasoning_delta)
    end

    acc
    |> Map.update!(:text, &(&1 <> delta))
    |> maybe_put_stream_model(event["model"])
    |> maybe_put_stream_finish_reason(extract_stream_finish_reason(choices))
    |> maybe_put_stream_usage(event["usage"])
  end

  defp apply_decoded_event(acc, %{"usage" => usage} = event, _on_chunk) do
    acc
    |> maybe_put_stream_model(event["model"])
    |> maybe_put_stream_usage(usage)
  end

  defp apply_decoded_event(acc, _event, _on_chunk), do: acc

  defp safe_callback(callback, delta) do
    callback.(delta)
  rescue
    error ->
      Logger.warning("Stream chunk callback raised", reason: Exception.message(error))
  end

  defp extract_stream_delta([%{"delta" => %{"content" => content}} | _]),
    do: normalize_content(content)

  defp extract_stream_delta(_choices), do: ""

  defp extract_reasoning_delta([%{"delta" => %{"reasoning" => reasoning}} | _])
       when is_binary(reasoning),
       do: reasoning

  defp extract_reasoning_delta([%{"delta" => %{"reasoning_content" => reasoning}} | _])
       when is_binary(reasoning),
       do: reasoning

  defp extract_reasoning_delta(_choices), do: ""

  defp extract_stream_finish_reason([%{"finish_reason" => reason} | _])
       when is_binary(reason),
       do: reason

  defp extract_stream_finish_reason(_choices), do: nil

  defp maybe_put_stream_model(acc, model) when is_binary(model) and model != "",
    do: Map.put(acc, :model, model)

  defp maybe_put_stream_model(acc, _model), do: acc

  defp maybe_put_stream_finish_reason(acc, reason) when is_binary(reason) and reason != "",
    do: Map.put(acc, :finish_reason, reason)

  defp maybe_put_stream_finish_reason(acc, _reason), do: acc

  defp maybe_put_stream_usage(acc, %{} = usage), do: Map.put(acc, :usage, usage)
  defp maybe_put_stream_usage(acc, _usage), do: acc

  defp finalize_stream(%{text: ""} = acc, _requested_model) do
    Logger.warning("OpenRouter stream ended without text")
    {:error, {:invalid_response, %{reason: "stream_incomplete", usage: acc.usage}}}
  end

  defp finalize_stream(acc, requested_model) do
    parse_response(%{
      "model" => acc.model || requested_model,
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => acc.text},
          "finish_reason" => acc.finish_reason || "stop"
        }
      ],
      "usage" => acc.usage || %{"prompt_tokens" => 0, "completion_tokens" => 0}
    })
  end

  defp normalize_messages(messages) when is_list(messages) do
    Enum.map(messages, &normalize_message/1)
  end

  defp normalize_message(%{"role" => role, "content" => content}) do
    %{
      role: normalize_role(role),
      content: normalize_content(content)
    }
  end

  defp normalize_message(%{role: role, content: content}) do
    %{
      role: normalize_role(role),
      content: normalize_content(content)
    }
  end

  defp normalize_message(message) when is_binary(message) do
    %{role: "user", content: message}
  end

  defp normalize_message(_message), do: %{role: "user", content: ""}

  defp normalize_role(role) when role in ["system", "user", "assistant", "tool"], do: role

  defp normalize_role(role) when role in [:system, :user, :assistant, :tool],
    do: Atom.to_string(role)

  defp normalize_role(_role), do: "user"

  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      text when is_binary(text) -> text
      other -> inspect(other)
    end)
  end

  defp normalize_content(nil), do: ""
  defp normalize_content(content), do: inspect(content)

  defp maybe_put_reasoning(body, params) do
    case reasoning_value(params) do
      nil -> body
      # Hybrid-thinking models (qwen3.x) reason by default when the field is
      # omitted; "none" must be an explicit opt-out or chat-tier calls burn
      # a full hidden thinking phase per turn.
      :disabled -> Map.put(body, :reasoning, %{enabled: false})
      %{} = reasoning -> Map.put(body, :reasoning, reasoning)
      effort -> Map.put(body, :reasoning, %{effort: effort})
    end
  end

  defp reasoning_value(%{"reasoning" => %{} = reasoning}), do: atomize_known_reasoning(reasoning)

  defp reasoning_value(%{"reasoning_effort" => effort}), do: validate_reasoning_effort(effort)

  defp reasoning_value(_params),
    do: validate_reasoning_effort(Maraithon.LLM.openrouter_reasoning_effort())

  defp atomize_known_reasoning(reasoning) do
    Enum.reduce(reasoning, %{}, fn
      {"effort", effort}, acc ->
        case validate_reasoning_effort(effort) do
          nil -> acc
          value -> Map.put(acc, :effort, value)
        end

      {"max_tokens", value}, acc ->
        Map.put(acc, :max_tokens, value)

      {"exclude", value}, acc ->
        Map.put(acc, :exclude, value)

      {"enabled", value}, acc when is_boolean(value) ->
        Map.put(acc, :enabled, value)

      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
    |> case do
      empty when map_size(empty) == 0 -> nil
      value -> value
    end
  end

  defp validate_reasoning_effort(effort) when effort in ["none", "off", false, nil], do: nil

  defp validate_reasoning_effort(effort) when is_binary(effort) do
    normalized = effort |> String.downcase() |> String.trim()

    cond do
      normalized == "" -> nil
      normalized in ["none", "off"] -> :disabled
      normalized in @reasoning_efforts -> normalized
      true -> "medium"
    end
  end

  defp validate_reasoning_effort(_effort), do: nil

  defp forward_params(body, params) do
    Enum.reduce(@forwarded_params, body, fn {key, body_key}, acc ->
      case Map.fetch(params, key) do
        {:ok, value} -> Map.put(acc, body_key, value)
        :error -> acc
      end
    end)
  end

  defp headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]
    |> maybe_add_header("http-referer", config_value(:http_referer))
    |> maybe_add_header("x-openrouter-title", config_value(:app_title))
  end

  defp maybe_add_header(headers, _name, nil), do: headers
  defp maybe_add_header(headers, _name, ""), do: headers
  defp maybe_add_header(headers, name, value), do: headers ++ [{name, value}]

  defp handle_429(headers, body) do
    case quota_error(body) do
      {:insufficient_quota, _message} = error ->
        handle_quota_error(body, error)

      nil ->
        retry_after = extract_retry_after(headers, body)
        Logger.warning("OpenRouter rate limited, retry after #{retry_after}ms")
        {:error, {:rate_limited, retry_after}}
    end
  end

  defp handle_quota_error(body, error \\ nil) do
    {:insufficient_quota, message} =
      error || quota_error(body) || {:insufficient_quota, "OpenRouter quota exceeded"}

    Logger.error("OpenRouter quota exceeded", message: message)
    {:error, {:insufficient_quota, message}}
  end

  defp quota_error(%{"error" => %{} = error}) do
    code = normalize_error_field(Map.get(error, "code"))
    type = normalize_error_field(Map.get(error, "type"))
    message = error_message(error)

    cond do
      "insufficient_quota" in [code, type] -> {:insufficient_quota, message}
      String.contains?(String.downcase(message), "insufficient") -> {:insufficient_quota, message}
      String.contains?(String.downcase(message), "credits") -> {:insufficient_quota, message}
      true -> nil
    end
  end

  defp quota_error(_body), do: nil

  defp normalize_error_field(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_error_field(_value), do: nil

  defp error_message(%{"message" => message}) when is_binary(message) do
    message
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp error_message(_error), do: "OpenRouter quota exceeded"

  defp extract_retry_after(headers, body) do
    case header_value(headers, "retry-after-ms") || header_value(headers, "retry-after") do
      nil -> extract_retry_after_from_body(body)
      value -> parse_retry_after(value)
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

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 1_000 -> parsed
      {parsed, ""} when parsed > 0 -> parsed * 1_000
      _ -> @default_retry_after_ms
    end
  end

  defp parse_retry_after(_value), do: @default_retry_after_ms

  defp extract_retry_after_from_body(%{"error" => %{"message" => message}})
       when is_binary(message) do
    case Regex.run(~r/retry after (\d+)/i, message) do
      [_, seconds] -> String.to_integer(seconds) * 1_000
      _ -> @default_retry_after_ms
    end
  end

  defp extract_retry_after_from_body(_body), do: @default_retry_after_ms

  defp config_value(key) do
    :maraithon
    |> Application.get_env(:openrouter, [])
    |> Keyword.get(key)
    |> case do
      nil ->
        case key do
          :http_referer -> Maraithon.LLM.openrouter_http_referer()
          :app_title -> Maraithon.LLM.openrouter_app_title()
          _ -> nil
        end

      value ->
        value
    end
  end

  defp base_url do
    config_value(:base_url) || @default_base_url
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)
end
