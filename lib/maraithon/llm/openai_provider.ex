defmodule Maraithon.LLM.OpenAIProvider do
  @moduledoc """
  OpenAI Responses API provider.
  """

  @behaviour Maraithon.LLM.Adapter

  alias Maraithon.Spend
  alias Maraithon.Tracing

  require Logger

  @default_base_url "https://api.openai.com/v1/responses"
  @default_retry_after_ms 60_000
  @reasoning_efforts ~w(low medium high xhigh)

  @impl true
  def complete(params) do
    api_key = Maraithon.LLM.openai_api_key()

    unless api_key do
      {:error, "OPENAI_API_KEY not configured"}
    else
      do_complete(params, api_key)
    end
  end

  @impl true
  def stream_complete(params, on_chunk) when is_function(on_chunk, 1) do
    api_key = Maraithon.LLM.openai_api_key()

    unless api_key do
      {:error, "OPENAI_API_KEY not configured"}
    else
      do_stream_complete(params, api_key, on_chunk)
    end
  end

  defp do_complete(params, api_key) do
    model = params["model"] || Maraithon.LLM.openai_model()

    Tracing.with_span("llm.request", request_span_attributes(params, model), fn ->
      do_complete_request(params, api_key, model)
    end)
  end

  defp do_complete_request(params, api_key, model) do
    timeout = params["timeout_ms"] || 120_000

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

    Logger.info("Calling OpenAI Responses API",
      model: model,
      message_count: length(params["messages"] || []),
      reasoning_effort: Map.get(body, :reasoning, %{}) |> Map.get(:effort, "none")
    )

    case Req.post(base_url(),
           json: body,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"}
           ],
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: response}} ->
        parse_response(response)

      {:ok, %{status: 429, headers: headers, body: body}} ->
        retry_after = extract_retry_after(headers, body)
        Logger.warning("Rate limited, retry after #{retry_after}ms")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenAI API error", status: status, body: inspect(body))
        {:error, {:api_error, status, body}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("OpenAI API timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("OpenAI API network error", reason: inspect(reason))
        {:error, {:network_error, reason}}
    end
  end

  defp do_stream_complete(params, api_key, on_chunk) do
    model = params["model"] || Maraithon.LLM.openai_model()

    Tracing.with_span(
      "llm.request",
      request_span_attributes(params, model, true),
      fn -> do_stream_request(params, api_key, on_chunk, model) end
    )
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

  defp do_stream_request(params, api_key, on_chunk, model) do
    timeout = params["timeout_ms"] || 120_000

    base_body = %{
      model: model,
      input: build_input(params["messages"] || []),
      max_output_tokens: params["max_tokens"] || params["max_output_tokens"] || 2048,
      stream: true
    }

    body =
      case effective_reasoning_effort(params, model) do
        nil -> base_body
        effort -> Map.put(base_body, :reasoning, %{effort: effort})
      end

    Logger.info("Calling OpenAI Responses API (streaming)",
      model: model,
      message_count: length(params["messages"] || []),
      reasoning_effort: Map.get(body, :reasoning, %{}) |> Map.get(:effort, "none")
    )

    request =
      Req.post(base_url(),
        json: body,
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"},
          {"accept", "text/event-stream"}
        ],
        receive_timeout: timeout,
        into: stream_collector(on_chunk)
      )

    case request do
      {:ok, %{status: 200, private: %{stream_acc: acc}}} ->
        finalize_stream(acc, model)

      {:ok, %{status: 429, headers: headers, body: body}} ->
        retry_after = extract_retry_after(headers, body)
        Logger.warning("Rate limited (stream), retry after #{retry_after}ms")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenAI API stream error", status: status, body: inspect(body))
        {:error, {:api_error, status, body}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("OpenAI API stream timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("OpenAI API stream network error", reason: inspect(reason))
        {:error, {:network_error, reason}}
    end
  end

  defp stream_collector(on_chunk) do
    fn {:data, data}, {req, resp} ->
      acc =
        Map.get(resp.private, :stream_acc, %{
          buffer: "",
          text: "",
          response: nil
        })

      next_acc =
        acc
        |> Map.update!(:buffer, &(&1 <> data))
        |> drain_events(on_chunk)

      {:cont, {req, Req.Response.put_private(resp, :stream_acc, next_acc)}}
    end
  end

  defp drain_events(%{buffer: buffer} = acc, on_chunk) do
    case :binary.split(buffer, "\n\n") do
      [event_block, rest] ->
        next_acc =
          acc
          |> Map.put(:buffer, rest)
          |> apply_event(event_block, on_chunk)

        drain_events(next_acc, on_chunk)

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

  defp apply_decoded_event(acc, %{"type" => "response.output_text.delta"} = event, on_chunk) do
    delta = event["delta"] || ""

    if delta != "" do
      try do
        on_chunk.(delta)
      rescue
        error ->
          Logger.warning("Stream chunk callback raised", reason: Exception.message(error))
      end
    end

    Map.update!(acc, :text, &(&1 <> delta))
  end

  defp apply_decoded_event(
         acc,
         %{"type" => "response.completed", "response" => response},
         _on_chunk
       ) do
    Map.put(acc, :response, response)
  end

  defp apply_decoded_event(acc, _event, _on_chunk), do: acc

  defp finalize_stream(%{response: nil} = acc, model) do
    Logger.warning("Stream ended without response.completed event")

    if acc.text != "" do
      synth_response = %{
        "model" => model,
        "status" => "completed",
        "output" => [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => acc.text}]}
        ],
        "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
      }

      parse_response(synth_response)
    else
      {:error, {:invalid_response, %{reason: "stream_incomplete"}}}
    end
  end

  defp finalize_stream(%{response: response}, _model), do: parse_response(response)

  defp parse_response(response) do
    model = response["model"] || "unknown"
    content = extract_output_text(response["output"] || [])
    finish_reason = response["status"] || "unknown"
    input_tokens = get_in(response, ["usage", "input_tokens"]) || 0
    output_tokens = get_in(response, ["usage", "output_tokens"]) || 0
    usage = Spend.calculate_cost(model, input_tokens, output_tokens)

    cond do
      finish_reason == "incomplete" ->
        {:error,
         {:incomplete_response, response["incomplete_details"] || %{status: "incomplete"}}}

      content != "" ->
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

      true ->
        {:error, {:invalid_response, response}}
    end
  end

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
      other -> inspect(other)
    end)
  end

  defp normalize_content(content), do: inspect(content)

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

  defp validate_reasoning_effort(effort) when is_binary(effort) do
    normalized = String.downcase(String.trim(effort))

    if normalized in @reasoning_efforts do
      normalized
    else
      "high"
    end
  end

  defp validate_reasoning_effort(_effort), do: "high"

  defp extract_retry_after(headers, body) do
    case header_value(headers, "retry-after-ms") || header_value(headers, "retry-after") do
      nil ->
        extract_retry_after_from_body(body)

      value ->
        parse_retry_after(value)
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

  defp base_url do
    Application.get_env(:maraithon, :openai, [])
    |> Keyword.get(:base_url, @default_base_url)
  end
end
