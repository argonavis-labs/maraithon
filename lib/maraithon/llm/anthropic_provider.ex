defmodule Maraithon.LLM.AnthropicProvider do
  @moduledoc """
  Anthropic Claude API provider.
  """

  @behaviour Maraithon.LLM.Adapter

  require Logger

  alias Maraithon.Tracing

  @default_base_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @cache_min_chars 1024

  @impl true
  def complete(params) do
    api_key = Maraithon.LLM.anthropic_api_key()

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not configured"}
    else
      do_complete(params, api_key)
    end
  end

  @doc false
  def build_body(params) when is_map(params) do
    model = params["model"] || Maraithon.LLM.anthropic_model()
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

    Tracing.with_span("llm.request", request_span_attributes(body, model), fn ->
      do_request(body, model, params, api_key)
    end)
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

    timeout = params["timeout_ms"] || 120_000

    Logger.info("Calling Anthropic API",
      model: model,
      message_count: length(body.messages),
      cache_blocks: count_cache_blocks(body)
    )

    case Req.post(base_url(),
           json: body,
           headers: headers,
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: response}} ->
        parse_response(response)

      {:ok, %{status: 429, body: body}} ->
        retry_after = extract_retry_after(body)
        Logger.warning("Rate limited, retry after #{retry_after}ms")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error", status: status, body: inspect(body))
        {:error, {:api_error, status, body}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("Anthropic API timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Anthropic API network error", reason: inspect(reason))
        {:error, {:network_error, reason}}
    end
  end

  defp parse_response(response) do
    content =
      case response["content"] do
        [%{"type" => "text", "text" => text} | _] -> text
        _ -> ""
      end

    model = response["model"] || "unknown"
    input_tokens = get_in(response, ["usage", "input_tokens"]) || 0
    output_tokens = get_in(response, ["usage", "output_tokens"]) || 0
    cache_read = get_in(response, ["usage", "cache_read_input_tokens"]) || 0
    cache_write = get_in(response, ["usage", "cache_creation_input_tokens"]) || 0

    # Calculate cost using the Spend module
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
       finish_reason: response["stop_reason"] || "unknown",
       usage: usage
     }}
  end

  defp extract_retry_after(body) do
    case body do
      %{"error" => %{"message" => msg}} ->
        case Regex.run(~r/retry after (\d+)/i, msg) do
          [_, seconds] -> String.to_integer(seconds) * 1000
          _ -> 60_000
        end

      _ ->
        60_000
    end
  end

  defp base_url do
    Application.get_env(:maraithon, :anthropic, [])
    |> Keyword.get(:base_url, @default_base_url)
  end

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
