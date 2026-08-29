defmodule Maraithon.LLM.OpenRouterProvider do
  @moduledoc """
  OpenRouter chat completions provider.

  OpenRouter exposes an OpenAI-compatible chat completions endpoint. This module
  adapts the app's existing LLM provider contract to that endpoint without
  changing the higher-level routing and assistant code.
  """

  @behaviour Maraithon.LLM.Adapter

  alias Maraithon.LLM.RequestBudget
  alias Maraithon.Spend
  alias Maraithon.Tracing

  require Logger

  @default_base_url "https://openrouter.ai/api/v1/chat/completions"
  @default_retry_after_ms 60_000
  @max_stream_buffer_bytes 256_000
  @max_stream_text_bytes 128_000
  @max_stream_reasoning_bytes 1_000_000
  @max_stream_wire_bytes 2_000_000
  @max_stream_events 10_000
  @max_stream_chunks 10_000
  @max_stream_parse_work_bytes 8_000_000
  @max_response_body_bytes 512_000
  @max_response_content_bytes 128_000
  @max_retry_after_ms 86_400_000
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
    with {:ok, bounded_params} <- RequestBudget.validate(params) do
      api_key = Maraithon.LLM.openrouter_api_key()

      if blank?(api_key) do
        {:error, "OPENROUTER_API_KEY not configured"}
      else
        do_complete(bounded_params, api_key)
      end
    end
  end

  @impl true
  def stream_complete(params, on_chunk) when is_function(on_chunk, 1) do
    with {:ok, bounded_params} <- RequestBudget.validate(params) do
      api_key = Maraithon.LLM.openrouter_api_key()

      if blank?(api_key) do
        {:error, "OPENROUTER_API_KEY not configured"}
      else
        do_stream_complete(bounded_params, api_key, on_chunk)
      end
    end
  end

  defp do_complete(params, api_key) do
    body = build_body(params)
    model = body.model

    with :ok <- RequestBudget.validate_body(body) do
      Tracing.with_span("llm.request", request_span_attributes(body, false), fn ->
        do_complete_request(body, params, api_key, model)
      end)
    end
  end

  defp do_complete_request(body, params, api_key, model) do
    timeout = request_timeout(params["timeout_ms"])

    Logger.info("Calling OpenRouter Chat Completions API",
      model: model,
      message_count: length(body.messages),
      reasoning_effort: get_in(body, [:reasoning, :effort]) || "none"
    )

    request = fn ->
      Req.post(base_url(),
        json: body,
        headers: headers(api_key),
        receive_timeout: timeout,
        decode_body: false,
        compressed: false,
        into: response_collector()
      )
    end

    case request_with_deadline(request, timeout) do
      {:ok, %{status: 200, private: %{response_overflow: true}}} ->
        invalid_http_response(model, "response_body_too_large")

      {:ok, %{status: 200} = response} ->
        parse_http_response(collected_response_body(response), model)

      {:ok, %{status: 402}} ->
        handle_quota_error(%{})

      {:ok, %{status: 429, headers: headers} = response} ->
        handle_429(headers, response |> collected_response_body() |> decode_error_body())

      {:ok, %{status: status}} ->
        Logger.error("OpenRouter API error", status: status, failure_code: "http_error")
        {:error, {:api_error, status, :redacted}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("OpenRouter API timeout")
        {:error, :timeout}

      {:error, reason} ->
        error_class = transport_error_class(reason)

        Logger.error("OpenRouter API network error",
          failure_code: "network_error",
          error: error_class
        )

        {:error, {:network_error, error_class}}
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

    with :ok <- RequestBudget.validate_body(body) do
      Tracing.with_span("llm.request", request_span_attributes(body, true), fn ->
        do_stream_request(body, params, api_key, {on_chunk, on_reasoning}, model)
      end)
    end
  end

  defp do_stream_request(body, params, api_key, on_chunk, model) do
    timeout = request_timeout(params["timeout_ms"])

    Logger.info("Calling OpenRouter Chat Completions API (streaming)",
      model: model,
      message_count: length(body.messages),
      reasoning_effort: get_in(body, [:reasoning, :effort]) || "none"
    )

    request = fn proxy_callbacks ->
      Req.post(base_url(),
        json: body,
        headers: [{"accept", "text/event-stream"} | headers(api_key)],
        receive_timeout: timeout,
        into: stream_collector(proxy_callbacks)
      )
    end

    case request_with_stream_deadline(request, timeout, on_chunk) do
      {:ok, %{status: 200, private: %{stream_acc: acc}}} ->
        finalize_stream(acc, model, on_chunk)

      {:ok, %{status: 200}} ->
        Logger.warning("OpenRouter stream returned no events",
          provider: "openrouter",
          model: safe_requested_model(model),
          failure_code: "stream_missing_events"
        )

        {:error,
         {:invalid_response,
          %{
            model: safe_requested_model(model),
            reason: "stream_missing_events",
            finish_reason: "unknown",
            usage: zero_usage_summary(),
            choice_count: 0
          }}}

      {:ok, %{status: 402}} ->
        handle_quota_error(%{})

      {:ok, %{status: 429, headers: headers} = response} ->
        handle_429(headers, response |> collected_response_body() |> decode_error_body())

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenRouter API stream error", status: status, failure_code: "http_error")
        _ = body
        {:error, {:api_error, status, :redacted}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("OpenRouter API stream timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("OpenRouter API stream network error",
          failure_code: "network_error",
          error: transport_error_class(reason)
        )

        {:error, {:network_error, transport_error_class(reason)}}
    end
  end

  defp response_collector do
    fn {:data, data}, state when is_binary(data) -> collect_response_data(data, state) end
  end

  defp collect_response_data(data, {req, resp}) do
    bytes = Map.get(resp.private, :response_bytes, 0) + byte_size(data)

    if bytes > @max_response_body_bytes do
      next_resp =
        resp
        |> Req.Response.put_private(:response_bytes, bytes)
        |> Req.Response.put_private(:response_chunks, [])
        |> Req.Response.put_private(:response_overflow, true)

      {:halt, {req, next_resp}}
    else
      chunks = [data | Map.get(resp.private, :response_chunks, [])]

      next_resp =
        resp
        |> Req.Response.put_private(:response_bytes, bytes)
        |> Req.Response.put_private(:response_chunks, chunks)

      {:cont, {req, next_resp}}
    end
  end

  defp collected_response_body(%{private: private}) when is_map(private) do
    private
    |> Map.get(:response_chunks, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp collected_response_body(_response), do: ""

  defp request_timeout(value) when is_integer(value) and value > 0,
    do: min(value, 300_000)

  defp request_timeout(_value), do: 120_000

  defp request_with_deadline(request, timeout)
       when is_function(request, 0) and is_integer(timeout) and timeout > 0 do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn -> run_owned_request(parent, ref, request) end)

    await_request_result(ref, pid, monitor_ref, deadline_ms(timeout), nil)
  end

  defp request_with_stream_deadline(request, timeout, callbacks)
       when is_function(request, 1) and is_integer(timeout) and timeout > 0 do
    parent = self()
    ref = make_ref()
    callbacks = normalize_stream_callbacks(callbacks)

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        run_owned_request(parent, ref, fn ->
          proxy_callbacks = stream_callback_proxies(parent, ref, timeout, callbacks)
          request.(proxy_callbacks)
        end)
      end)

    await_request_result(ref, pid, monitor_ref, deadline_ms(timeout), callbacks)
  end

  defp run_owned_request(parent, ref, request) do
    worker = self()
    notify_request_worker(worker)
    watcher = spawn(fn -> watch_request_owner(parent, worker) end)
    result = safe_request(request)
    send(parent, {ref, :result, result})
    send(watcher, {:request_finished, worker})
  end

  defp notify_request_worker(worker) do
    case Application.get_env(:maraithon, :openrouter, [])[:request_worker_observer] do
      observer when is_pid(observer) -> send(observer, {:openrouter_request_worker, worker})
      _other -> :ok
    end
  end

  defp watch_request_owner(parent, worker) do
    parent_ref = Process.monitor(parent)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
        Process.exit(worker, :kill)

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        :ok

      {:request_finished, ^worker} ->
        Process.demonitor(parent_ref, [:flush])
        Process.demonitor(worker_ref, [:flush])
        :ok
    end
  end

  defp safe_request(request) do
    request.()
  rescue
    _error -> {:error, %{reason: :request_failed}}
  catch
    _kind, _reason -> {:error, %{reason: :request_failed}}
  end

  defp stream_callback_proxies(parent, ref, timeout, {_on_chunk, on_reasoning}) do
    on_chunk = fn delta -> proxy_stream_callback(parent, ref, :chunk, delta, timeout) end

    reasoning_callback =
      if is_function(on_reasoning, 1) do
        fn delta -> proxy_stream_callback(parent, ref, :reasoning, delta, timeout) end
      end

    {on_chunk, reasoning_callback}
  end

  defp proxy_stream_callback(parent, ref, kind, delta, timeout) do
    send(parent, {ref, :stream_callback, kind, delta, self()})

    receive do
      {^ref, :stream_callback_ack} -> :ok
    after
      timeout -> :ok
    end
  end

  defp await_request_result(ref, pid, monitor_ref, deadline, callbacks) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, :result, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {^ref, :stream_callback, kind, delta, worker} ->
        deliver_stream_callback(callbacks, kind, delta)
        send(worker, {ref, :stream_callback_ack})
        await_request_result(ref, pid, monitor_ref, deadline, callbacks)

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        drain_request_messages(ref)
        {:error, %{reason: :request_failed}}
    after
      remaining_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> Process.demonitor(monitor_ref, [:flush])
        end

        drain_request_messages(ref)
        {:error, %{reason: :timeout}}
    end
  end

  defp drain_request_messages(ref) do
    receive do
      {^ref, :result, _result} -> drain_request_messages(ref)
      {^ref, :stream_callback, _kind, _delta, _worker} -> drain_request_messages(ref)
    after
      0 -> :ok
    end
  end

  defp deliver_stream_callback({on_chunk, _on_reasoning}, :chunk, delta),
    do: safe_callback(on_chunk, delta)

  defp deliver_stream_callback({_on_chunk, on_reasoning}, :reasoning, delta)
       when is_function(on_reasoning, 1),
       do: safe_callback(on_reasoning, delta)

  defp deliver_stream_callback(_callbacks, _kind, _delta), do: :ok

  defp deadline_ms(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp build_body(params) when is_map(params) do
    model =
      configured_model(
        params["model"] || Maraithon.LLM.openrouter_model(),
        "moonshotai/kimi-k3"
      )

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

  defp parse_http_response(response, requested_model) when is_binary(response) do
    cond do
      byte_size(response) > @max_response_body_bytes ->
        invalid_http_response(requested_model, "response_body_too_large")

      true ->
        case Jason.decode(response) do
          {:ok, decoded} -> parse_response(decoded, requested_model)
          {:error, _reason} -> invalid_http_response(requested_model, "invalid_json")
        end
    end
  end

  defp parse_http_response(response, requested_model),
    do: parse_response(response, requested_model)

  defp invalid_http_response(requested_model, reason) do
    model = safe_requested_model(requested_model)

    Logger.warning("OpenRouter returned an invalid response",
      provider: "openrouter",
      model: model,
      failure_code: reason
    )

    {:error,
     {:invalid_response,
      %{
        model: model,
        reason: reason,
        response_shape: "invalid",
        finish_reason: "unknown",
        usage: zero_usage_summary(),
        choice_count: 0
      }}}
  end

  defp decode_error_body(body) when is_map(body), do: body

  defp decode_error_body(body) when is_binary(body) and byte_size(body) <= 16_000 do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp decode_error_body(_body), do: %{}

  defp parse_response(response, requested_model) when is_map(response) do
    model = safe_model(Map.get(response, "model"), requested_model)
    {choices, choices_valid?} = bounded_response_choices(response)
    provider_error? = provider_error_marker?(response, choices)
    refusal? = choices_valid? and provider_refusal?(choices)
    content = if choices_valid?, do: extract_message_content(choices), else: ""
    finish_reason = choices |> extract_finish_reason() |> safe_finish_reason()
    input_tokens = usage_value(response, "prompt_tokens", "input_tokens")
    output_tokens = usage_value(response, "completion_tokens", "output_tokens")
    usage = Spend.calculate_cost(model, input_tokens, output_tokens)

    cond do
      not choices_valid? ->
        invalid_http_response(requested_model, "invalid_choices_shape")

      provider_error? ->
        {:error, {:provider_error, :redacted}}

      refusal? ->
        {:error, {:provider_refusal, :redacted}}

      finish_reason == "content_filter" ->
        {:error, {:content_filtered, :redacted}}

      byte_size(content) > @max_response_content_bytes ->
        invalid_http_response(requested_model, "response_content_too_large")

      not String.valid?(content) ->
        invalid_http_response(requested_model, "invalid_response_encoding")

      String.trim(content) == "" ->
        summary = invalid_response_summary(response, model, finish_reason)

        Logger.warning("LLM call returned empty content",
          provider: "openrouter",
          model: model,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          reasoning_tokens: summary.usage.reasoning_tokens,
          cost_usd: usage.total_cost,
          finish_reason: safe_finish_reason(finish_reason),
          choice_count: length(choices),
          failure_code: "empty_content"
        )

        {:error, {:invalid_response, summary}}

      finish_reason == "length" ->
        {:error, {:incomplete_response, %{reason: "provider_incomplete"}}}

      finish_reason != "stop" ->
        invalid_http_response(requested_model, "invalid_finish_reason")

      true ->
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
    end
  end

  defp parse_response(response, requested_model) do
    model = safe_requested_model(requested_model)
    response_shape = response_shape(response)

    Logger.warning("OpenRouter returned an invalid response shape",
      provider: "openrouter",
      model: model,
      response_shape: response_shape,
      failure_code: "invalid_response_shape"
    )

    {:error,
     {:invalid_response,
      %{
        model: model,
        reason: "invalid_response_shape",
        response_shape: response_shape,
        finish_reason: "unknown",
        usage: zero_usage_summary(),
        choice_count: 0
      }}}
  end

  defp safe_finish_reason(reason)
       when reason in ["stop", "length", "content_filter", "tool_calls", "error", "unknown"],
       do: reason

  defp safe_finish_reason(_reason), do: "other"

  defp invalid_response_summary(response, model, finish_reason) do
    input_tokens = usage_value(response, "prompt_tokens", "input_tokens")
    output_tokens = usage_value(response, "completion_tokens", "output_tokens")

    usage = response_usage(response)
    completion_details = map_value(usage, "completion_tokens_details")

    reasoning_tokens =
      usage
      |> Map.get("reasoning_tokens")
      |> Kernel.||(Map.get(completion_details, "reasoning_tokens"))
      |> normalize_token_count()

    %{
      model: model,
      finish_reason: safe_finish_reason(finish_reason),
      usage: %{
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        reasoning_tokens: reasoning_tokens,
        total_tokens: input_tokens + output_tokens
      },
      choice_count: response |> response_choices() |> length()
    }
  end

  defp bounded_response_choices(response) when is_map(response) do
    case Map.get(response, "choices") do
      choices when is_list(choices) ->
        prefix = Enum.take(choices, 101)
        {prefix, length(prefix) <= 100}

      _other ->
        {[], false}
    end
  rescue
    _error -> {[], false}
  end

  defp provider_error_marker?(response, choices) do
    present_error?(Map.get(response, "error")) or
      Enum.any?(choices, fn
        %{} = choice -> present_error?(Map.get(choice, "error"))
        _choice -> false
      end)
  end

  defp present_error?(nil), do: false
  defp present_error?(false), do: false
  defp present_error?(%{} = value), do: map_size(value) > 0
  defp present_error?(""), do: false
  defp present_error?(_value), do: true

  defp provider_refusal?(choices) when is_list(choices) do
    Enum.any?(choices, fn
      %{"message" => message} when is_map(message) -> refusal_message?(message)
      _choice -> false
    end)
  end

  defp refusal_message?(message) do
    non_empty_refusal?(Map.get(message, "refusal")) or
      refusal_content?(Map.get(message, "content"))
  end

  defp non_empty_refusal?(value) when is_binary(value) and byte_size(value) <= 64_000,
    do: value != ""

  defp non_empty_refusal?(_value), do: false

  defp refusal_content?(content) when is_list(content) do
    prefix = Enum.take(content, 101)

    length(prefix) > 100 or
      Enum.any?(prefix, fn
        %{"type" => type} when type in ["refusal", "content_filter"] -> true
        %{"refusal" => refusal} -> non_empty_refusal?(refusal)
        _block -> false
      end)
  rescue
    _error -> true
  end

  defp refusal_content?(_content), do: false

  defp extract_message_content([%{"message" => %{"content" => content}} | _]) do
    normalize_content(content)
  end

  defp extract_message_content(_choices), do: ""

  defp extract_finish_reason([%{"finish_reason" => reason} | _]) when is_binary(reason),
    do: reason

  defp extract_finish_reason(_choices), do: "unknown"

  defp usage_value(response, primary_key, fallback_key) do
    usage = response_usage(response)

    usage
    |> Map.get(primary_key)
    |> Kernel.||(Map.get(usage, fallback_key))
    |> normalize_token_count()
  end

  defp response_choices(response) when is_map(response) do
    case Map.get(response, "choices") do
      choices when is_list(choices) -> choices
      _other -> []
    end
  end

  defp response_choices(_response), do: []

  defp response_usage(response) when is_map(response),
    do: map_value(response, "usage")

  defp response_usage(_response), do: %{}

  defp map_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp map_value(_value, _key), do: %{}

  defp zero_usage_summary do
    %{input_tokens: 0, output_tokens: 0, reasoning_tokens: 0, total_tokens: 0}
  end

  defp response_shape(value) when is_list(value), do: "list"
  defp response_shape(value) when is_binary(value), do: "string"
  defp response_shape(value) when is_number(value), do: "number"
  defp response_shape(value) when is_boolean(value), do: "boolean"
  defp response_shape(nil), do: "null"
  defp response_shape(_value), do: "other"

  defp normalize_token_count(value) when is_integer(value) and value >= 0,
    do: min(value, 100_000_000)

  defp normalize_token_count(value) when is_float(value) and value >= 0,
    do: value |> trunc() |> normalize_token_count()

  defp normalize_token_count(value) when is_binary(value) and byte_size(value) <= 32 do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> normalize_token_count(parsed)
      _other -> 0
    end
  end

  defp normalize_token_count(_value), do: 0

  defp safe_model(value, fallback) when is_binary(value) do
    model = String.trim(value)

    if Regex.match?(~r/\A[A-Za-z0-9._:\/-]{1,160}\z/, model) do
      model
    else
      safe_requested_model(fallback)
    end
  end

  defp safe_model(_value, fallback), do: safe_requested_model(fallback)

  defp safe_requested_model(value) when is_binary(value) do
    model = String.trim(value)
    if Regex.match?(~r/\A[A-Za-z0-9._:\/-]{1,160}\z/, model), do: model, else: "unknown"
  end

  defp safe_requested_model(_value), do: "unknown"

  @doc false
  def parse_stream_chunks(chunks, callbacks, model \\ "test/model") when is_list(chunks) do
    callbacks = normalize_stream_callbacks(callbacks)

    acc =
      Enum.reduce_while(chunks, new_stream_acc(), fn chunk, acc ->
        next_acc = append_stream_data(acc, chunk, callbacks)

        if is_nil(next_acc.error),
          do: {:cont, next_acc},
          else: {:halt, next_acc}
      end)

    finalize_stream(acc, model, callbacks)
  end

  defp stream_collector(callbacks) do
    callbacks = normalize_stream_callbacks(callbacks)

    fn {:data, data}, {req, resp} ->
      if resp.status == 200 do
        acc = Map.get(resp.private, :stream_acc, new_stream_acc())
        next_acc = append_stream_data(acc, data, callbacks)
        stream_state = {req, Req.Response.put_private(resp, :stream_acc, next_acc)}

        if next_acc.done or not is_nil(next_acc.error),
          do: {:halt, stream_state},
          else: {:cont, stream_state}
      else
        collect_response_data(data, {req, resp})
      end
    end
  end

  defp new_stream_acc do
    %{
      buffer: "",
      text_chunks: [],
      text_bytes: 0,
      reasoning_bytes: 0,
      reasoning_chunks: [],
      wire_bytes: 0,
      event_count: 0,
      chunk_count: 0,
      parse_work_bytes: 0,
      model: nil,
      finish_reason: nil,
      usage: nil,
      done: false,
      error: nil
    }
  end

  defp normalize_stream_callbacks({on_chunk, on_reasoning}), do: {on_chunk, on_reasoning}
  defp normalize_stream_callbacks(on_chunk), do: {on_chunk, nil}

  defp append_stream_data(%{error: error} = acc, _data, _callbacks) when not is_nil(error),
    do: acc

  defp append_stream_data(%{done: true} = acc, data, _callbacks)
       when is_binary(data) and byte_size(data) > 0,
       do: %{acc | error: "stream_data_after_done"}

  defp append_stream_data(acc, data, callbacks) when is_binary(data) do
    next_wire_bytes = acc.wire_bytes + byte_size(data)
    next_chunk_count = acc.chunk_count + 1
    next_parse_work_bytes = acc.parse_work_bytes + byte_size(acc.buffer) + byte_size(data)

    cond do
      next_wire_bytes > @max_stream_wire_bytes ->
        %{acc | buffer: "", wire_bytes: next_wire_bytes, error: "stream_wire_too_large"}

      next_chunk_count > @max_stream_chunks ->
        %{acc | buffer: "", chunk_count: next_chunk_count, error: "stream_chunk_limit"}

      next_parse_work_bytes > @max_stream_parse_work_bytes ->
        %{
          acc
          | buffer: "",
            parse_work_bytes: next_parse_work_bytes,
            error: "stream_parse_work_limit"
        }

      true ->
        buffer = normalize_sse_newlines(acc.buffer <> data)

        next_acc =
          drain_events(
            %{
              acc
              | buffer: buffer,
                wire_bytes: next_wire_bytes,
                chunk_count: next_chunk_count,
                parse_work_bytes: next_parse_work_bytes
            },
            callbacks
          )

        if byte_size(next_acc.buffer) > @max_stream_buffer_bytes,
          do: %{next_acc | buffer: "", error: "stream_event_too_large"},
          else: next_acc
    end
  end

  defp append_stream_data(acc, _data, _callbacks),
    do: %{acc | error: "invalid_stream_chunk"}

  defp normalize_sse_newlines(value) do
    {body, trailing_carriage_return} =
      if split_crlf_prefix?(value) do
        {binary_part(value, 0, byte_size(value) - 1), "\r"}
      else
        {value, ""}
      end

    normalized =
      body
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")

    normalized <> trailing_carriage_return
  end

  defp split_crlf_prefix?(value) when byte_size(value) == 1, do: value == "\r"

  defp split_crlf_prefix?(value) when is_binary(value) do
    if String.ends_with?(value, "\r") do
      preceding = binary_part(value, byte_size(value) - 2, 1)
      preceding not in ["\r", "\n"]
    else
      false
    end
  end

  defp drain_events(%{error: error} = acc, _callbacks) when not is_nil(error), do: acc

  defp drain_events(%{done: true, buffer: buffer} = acc, _callbacks) do
    if blank_stream_buffer?(buffer),
      do: %{acc | buffer: ""},
      else: %{acc | buffer: "", error: "stream_data_after_done"}
  end

  defp drain_events(%{buffer: buffer} = acc, callbacks) do
    case :binary.split(buffer, "\n\n") do
      [event_block, rest] ->
        event_count = acc.event_count + 1

        next_acc =
          if event_count > @max_stream_events do
            %{acc | buffer: "", event_count: event_count, error: "stream_event_limit"}
          else
            acc
            |> Map.put(:buffer, rest)
            |> Map.put(:event_count, event_count)
            |> apply_event(event_block, callbacks)
          end

        drain_events(next_acc, callbacks)

      [_partial] ->
        acc
    end
  end

  defp apply_event(acc, event_block, callbacks) do
    if String.valid?(event_block) do
      apply_valid_event(acc, event_block, callbacks)
    else
      %{acc | error: "invalid_stream_utf8"}
    end
  end

  defp apply_valid_event(acc, event_block, callbacks) do
    data_lines =
      event_block
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn
        "data: " <> rest -> [rest]
        "data:" <> rest -> [String.trim_leading(rest)]
        _other -> []
      end)

    case data_lines do
      [] ->
        acc

      lines ->
        payload = Enum.join(lines, "\n")

        if payload == "[DONE]" do
          %{acc | done: true}
        else
          case Jason.decode(payload) do
            {:ok, %{} = json} -> apply_decoded_event(acc, json, callbacks)
            {:ok, _other} -> %{acc | error: "invalid_stream_event_shape"}
            {:error, _reason} -> %{acc | error: "malformed_stream_event"}
          end
        end
    end
  end

  defp apply_decoded_event(acc, %{"choices" => choices} = event, {on_chunk, on_reasoning}) do
    delta = extract_stream_delta(choices)
    reasoning_delta = extract_reasoning_delta(choices)

    acc =
      cond do
        present_error?(Map.get(event, "error")) or
            Enum.any?(choices, fn
              %{} = choice -> present_error?(Map.get(choice, "error"))
              _choice -> false
            end) ->
          %{acc | error: "provider_error"}

        provider_refusal?(choices) ->
          %{acc | error: "provider_refusal"}

        true ->
          acc
      end

    acc
    |> append_stream_delta(delta, on_chunk)
    |> deliver_reasoning_delta(reasoning_delta, on_reasoning)
    |> maybe_put_stream_model(event["model"])
    |> maybe_put_stream_finish_reason(extract_stream_finish_reason(choices))
    |> maybe_put_stream_usage(event["usage"])
  end

  defp apply_decoded_event(acc, %{"usage" => usage} = event, _callbacks) do
    acc
    |> maybe_put_stream_model(event["model"])
    |> maybe_put_stream_usage(usage)
  end

  defp apply_decoded_event(acc, _event, _callbacks),
    do: %{acc | error: "invalid_stream_event_shape"}

  defp append_stream_delta(acc, "", _callback), do: acc

  defp append_stream_delta(%{error: error} = acc, _delta, _callback) when not is_nil(error),
    do: acc

  defp append_stream_delta(acc, delta, callback) when is_binary(delta) do
    next_bytes = acc.text_bytes + byte_size(delta)

    if next_bytes <= @max_stream_text_bytes do
      _ = callback
      %{acc | text_chunks: [delta | acc.text_chunks], text_bytes: next_bytes}
    else
      %{acc | error: "stream_text_too_large"}
    end
  end

  defp append_stream_delta(acc, _delta, _callback),
    do: %{acc | error: "invalid_stream_delta"}

  defp deliver_reasoning_delta(acc, "", _callback), do: acc

  defp deliver_reasoning_delta(%{error: error} = acc, _delta, _callback)
       when not is_nil(error),
       do: acc

  defp deliver_reasoning_delta(acc, delta, callback) when is_binary(delta) do
    next_reasoning_bytes = acc.reasoning_bytes + byte_size(delta)

    if next_reasoning_bytes <= @max_stream_reasoning_bytes do
      _ = callback

      %{
        acc
        | reasoning_chunks: [delta | acc.reasoning_chunks],
          reasoning_bytes: next_reasoning_bytes
      }
    else
      %{acc | error: "stream_reasoning_too_large"}
    end
  end

  defp deliver_reasoning_delta(acc, _delta, _callback),
    do: %{acc | error: "invalid_reasoning_delta"}

  defp safe_callback(callback, delta) do
    callback.(delta)
  rescue
    error ->
      Logger.warning("Stream chunk callback raised",
        failure_code: "callback_exception",
        error: error.__struct__
      )
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

  defp maybe_put_stream_finish_reason(%{finish_reason: nil} = acc, reason)
       when is_binary(reason) and reason != "",
       do: %{acc | finish_reason: reason}

  defp maybe_put_stream_finish_reason(%{finish_reason: existing} = acc, reason)
       when is_binary(reason) and reason != "" do
    failure_code =
      if existing == reason,
        do: "stream_repeated_finish_reason",
        else: "stream_conflicting_finish_reason"

    %{acc | error: failure_code}
  end

  defp maybe_put_stream_finish_reason(acc, _reason), do: acc

  defp maybe_put_stream_usage(acc, %{} = usage), do: Map.put(acc, :usage, usage)
  defp maybe_put_stream_usage(acc, _usage), do: acc

  defp finalize_stream(acc, requested_model, callbacks) do
    case stream_completion_error(acc) do
      nil ->
        text = acc.text_chunks |> Enum.reverse() |> IO.iodata_to_binary()

        result =
          parse_response(
            %{
              "model" => acc.model || requested_model,
              "choices" => [
                %{
                  "message" => %{"role" => "assistant", "content" => text},
                  "finish_reason" => acc.finish_reason
                }
              ],
              "usage" => acc.usage || %{"prompt_tokens" => 0, "completion_tokens" => 0}
            },
            requested_model
          )

        case result do
          {:ok, _response} ->
            replay_stream_callbacks(acc, callbacks)
            result

          _error ->
            result
        end

      "provider_refusal" ->
        {:error, {:provider_refusal, :redacted}}

      "provider_error" ->
        {:error, {:provider_error, :redacted}}

      failure_code ->
        model = safe_model(acc.model, requested_model)
        finish_reason = safe_finish_reason(acc.finish_reason || "unknown")

        response = %{
          "choices" => [],
          "usage" => acc.usage || %{},
          "model" => model
        }

        summary =
          response
          |> invalid_response_summary(model, finish_reason)
          |> Map.put(:reason, failure_code)

        Logger.warning("OpenRouter stream did not complete cleanly",
          provider: "openrouter",
          model: model,
          failure_code: failure_code,
          finish_reason: finish_reason,
          input_tokens: summary.usage.input_tokens,
          output_tokens: summary.usage.output_tokens,
          reasoning_tokens: summary.usage.reasoning_tokens
        )

        {:error, {:invalid_response, summary}}
    end
  end

  defp replay_stream_callbacks(acc, callbacks) do
    {on_chunk, on_reasoning} = normalize_stream_callbacks(callbacks)

    if is_function(on_chunk, 1) and acc.text_chunks != [] do
      acc.text_chunks
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> then(&safe_callback(on_chunk, &1))
    end

    if is_function(on_reasoning, 1) and acc.reasoning_chunks != [] do
      acc.reasoning_chunks
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> then(&safe_callback(on_reasoning, &1))
    end
  end

  defp stream_completion_error(%{error: error}) when is_binary(error), do: error
  defp stream_completion_error(%{done: false}), do: "stream_missing_done"

  defp stream_completion_error(%{finish_reason: finish_reason})
       when not is_binary(finish_reason) or finish_reason == "",
       do: "stream_missing_finish_reason"

  defp stream_completion_error(%{buffer: buffer}) do
    if blank_stream_buffer?(buffer), do: nil, else: "stream_incomplete_event"
  end

  defp blank_stream_buffer?(""), do: true

  defp blank_stream_buffer?(buffer) when is_binary(buffer) do
    String.valid?(buffer) and String.trim(buffer) == ""
  end

  defp blank_stream_buffer?(_buffer), do: false

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
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      %{text: text} when is_binary(text) -> [text]
      text when is_binary(text) -> [text]
      _unknown_block -> []
    end)
    |> Enum.join("\n")
  end

  defp normalize_content(_content), do: ""

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
      {key, effort}, acc when key in ["effort", :effort] ->
        case validate_reasoning_effort(effort) do
          nil -> acc
          :disabled -> Map.put(acc, :enabled, false)
          value -> Map.put(acc, :effort, value)
        end

      {key, value}, acc
      when key in ["max_tokens", :max_tokens] and is_integer(value) and value > 0 and
             value <= 32_000 ->
        Map.put(acc, :max_tokens, value)

      {key, value}, acc when key in ["exclude", :exclude] and is_boolean(value) ->
        Map.put(acc, :exclude, value)

      {key, value}, acc when key in ["enabled", :enabled] and is_boolean(value) ->
        Map.put(acc, :enabled, value)

      _unknown, acc ->
        acc
    end)
    |> case do
      empty when map_size(empty) == 0 -> nil
      value -> value
    end
  end

  # Hybrid-thinking models treat an omitted reasoning field as "enabled".
  # Preserve nil/false as "use no override", but turn the explicit string
  # opt-outs into the sentinel that emits `%{enabled: false}`.
  defp validate_reasoning_effort(effort) when effort in ["none", "off"], do: :disabled
  defp validate_reasoning_effort(effort) when effort in [false, nil], do: nil

  defp validate_reasoning_effort(effort) when is_binary(effort) and byte_size(effort) <= 32 do
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
    |> maybe_add_header("http-referer", bounded_header(config_value(:http_referer), 512))
    |> maybe_add_header("x-openrouter-title", bounded_header(config_value(:app_title), 256))
  end

  defp maybe_add_header(headers, _name, nil), do: headers
  defp maybe_add_header(headers, _name, ""), do: headers
  defp maybe_add_header(headers, name, value), do: headers ++ [{name, value}]

  defp bounded_header(value, max_bytes)
       when is_binary(value) and byte_size(value) <= max_bytes do
    if String.valid?(value), do: value, else: nil
  end

  defp bounded_header(_value, _max_bytes), do: nil

  defp handle_429(headers, body) do
    case quota_error(body) do
      {:insufficient_quota, _message} = error ->
        handle_quota_error(body, error)

      nil ->
        retry_after = extract_retry_after(headers, body)

        Logger.warning("OpenRouter rate limited",
          failure_code: "rate_limited",
          retry_after_ms: retry_after
        )

        {:error, {:rate_limited, retry_after}}
    end
  end

  defp handle_quota_error(body, error \\ nil) do
    {:insufficient_quota, message} =
      error || quota_error(body) || {:insufficient_quota, "OpenRouter quota exceeded"}

    Logger.error("OpenRouter quota exceeded", failure_code: "insufficient_quota")
    _ = message
    {:error, {:insufficient_quota, "OpenRouter quota exceeded"}}
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
    cond do
      value = header_value(headers, "retry-after-ms") -> parse_retry_after_ms(value)
      value = header_value(headers, "retry-after") -> parse_retry_after_seconds(value)
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

  defp parse_retry_after_ms(value), do: parse_bounded_retry_after(value, 1)
  defp parse_retry_after_seconds(value), do: parse_bounded_retry_after(value, 1_000)

  defp parse_bounded_retry_after(value, multiplier)
       when is_binary(value) and byte_size(value) <= 16 do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed * multiplier, @max_retry_after_ms)
      _other -> @default_retry_after_ms
    end
  end

  defp parse_bounded_retry_after(_value, _multiplier), do: @default_retry_after_ms

  defp extract_retry_after_from_body(%{"error" => %{"message" => message}})
       when is_binary(message) and byte_size(message) <= 1_000 do
    case Regex.run(~r/retry after (\d{1,10})(?:\D|$)/i, message) do
      [_, seconds] -> parse_retry_after_seconds(seconds)
      _other -> @default_retry_after_ms
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
    value = config_value(:base_url)
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

  defp transport_error_class(%{__struct__: module}) when is_atom(module), do: module
  defp transport_error_class(_reason), do: :transport_error

  defp blank?(value) when is_binary(value) and byte_size(value) <= 4_096,
    do:
      not String.valid?(value) or String.trim(value) == "" or
        String.contains?(value, ["\r", "\n"])

  defp blank?(_value), do: true

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
end
