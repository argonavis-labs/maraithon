defmodule MaraithonAgentLab.Transport do
  alias MaraithonAgentLab.Fixtures
  @model "moonshotai/kimi-k3"
  def turn(mode, messages, api_key) when mode in [:envelope, :native] do
    body = %{
      model: @model,
      messages: messages,
      max_tokens: 2200,
      temperature: 0.0,
      reasoning_effort: "low"
    }

    body = if mode == :native, do: Map.put(body, :tools, native_tools()), else: body
    started = System.monotonic_time(:millisecond)
    # Do not log Req errors: request structs can contain authorization headers.
    case Req.post("https://openrouter.ai/api/v1/chat/completions",
           json: body,
           auth: {:bearer, api_key},
           receive_timeout: 90_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => message} | _]} = response}} ->
        if System.get_env("LAB_SMOKE") == "1" do
          File.write!(
            "results/raw-#{mode}-#{System.unique_integer([:positive])}.json",
            Jason.encode!(
              %{
                message: Map.drop(message, ["reasoning", "reasoning_details"]),
                usage: response["usage"],
                finish_reason: hd(response["choices"])["finish_reason"]
              }, pretty: true)
          )
        end

        calls = if mode == :native, do: native_calls(message), else: envelope_calls(message)

        %{
          calls: calls,
          message: message,
          usage: response["usage"],
          latency_ms: System.monotonic_time(:millisecond) - started
        }

      {:ok, %{status: status}} ->
        raise "provider_http_#{status}"

      {:error, _} ->
        raise "provider_transport_error"
    end
  end

  def turn(:req_llm, context, api_key) do
    started = System.monotonic_time(:millisecond)

    tools =
      Enum.map(Fixtures.tools(), fn tool ->
        ReqLLM.Tool.new!(
          name: tool.name,
          description: tool.description,
          parameter_schema: tool.parameters,
          strict: true,
          callback: fn _ -> {:error, :host_must_execute} end
        )
      end)

    case ReqLLM.generate_text("openrouter:" <> @model, context,
           api_key: api_key,
           tools: tools,
           max_tokens: 2200,
           temperature: 0.0,
           reasoning_effort: :low,
           receive_timeout: 90_000,
           total_timeout: 90_000,
           max_retries: 0
         ) do
      {:ok, response} ->
        calls =
          Enum.map(ReqLLM.Response.tool_calls(response), fn call ->
            call = ReqLLM.ToolCall.to_map(call)
            %{id: call.id, name: call.name, arguments: call.arguments}
          end)

        %{
          calls: calls,
          message: response,
          usage: ReqLLM.Response.usage(response),
          latency_ms: System.monotonic_time(:millisecond) - started
        }

      {:error, error} ->
        if System.get_env("LAB_SMOKE") == "1" do
          message =
            Exception.message(error)
            |> String.replace(api_key, "[redacted]")
            |> String.slice(0, 1200)

          IO.puts("ReqLLM integration error: " <> message)
        end

        raise "req_llm_provider_error"
    end
  end

  def continue(:req_llm, context, response, observations) do
    results =
      Enum.map(observations, fn {call, result} ->
        ReqLLM.Context.tool_result(call.id, call.name, Jason.encode!(result))
      end)

    {:ok, context} = ReqLLM.Context.append_tool_exchange(context, response, results)
    context
  end

  def continue(:native, messages, message, observations) do
    messages ++
      [message] ++
      Enum.map(observations, fn {call, result} ->
        %{role: "tool", tool_call_id: call.id, content: Jason.encode!(result)}
      end)
  end

  def continue(:envelope, messages, message, observations) do
    messages ++
      [
        message,
        %{
          role: "user",
          content:
            Jason.encode!(%{
              tool_results:
                Enum.map(observations, fn {call, result} -> %{tool: call.name, result: result} end)
            })
        }
      ]
  end

  defp native_tools do
    Enum.map(
      Fixtures.tools(),
      &%{
        type: "function",
        function: %{
          name: &1.name,
          description: &1.description,
          parameters: &1.parameters,
          strict: true
        }
      }
    )
  end

  defp native_calls(message) do
    Enum.map(message["tool_calls"] || [], fn call ->
      %{
        id: call["id"],
        name: call["function"]["name"],
        arguments: Jason.decode!(call["function"]["arguments"])
      }
    end)
  end

  defp envelope_calls(message) do
    parsed =
      message["content"]
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()
      |> Jason.decode!()

    unless parsed["status"] == "tool_calls", do: raise("expected_artifact_tool")

    Enum.with_index(parsed["tool_calls"] || [], fn call, index ->
      %{id: "envelope-#{index}", name: call["tool"], arguments: call["arguments"]}
    end)
  end
end
