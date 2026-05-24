defmodule MaraithonWeb.McpController do
  use MaraithonWeb, :controller

  alias Maraithon.Tools

  @protocol_version "2025-03-26"
  @batch_timeout_ms 30_000
  @batch_max_concurrency 8
  @tool_call_timeout_ms 25_000

  def handle(conn, %{"_json" => requests}) when is_list(requests), do: handle(conn, requests)

  def handle(conn, requests) when is_list(requests) do
    responses =
      requests
      |> Task.async_stream(&response_for/1,
        max_concurrency: @batch_max_concurrency,
        ordered: true,
        timeout: @batch_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, response} -> response
        {:exit, reason} -> error_response(nil, -32603, "Batch request failed", inspect(reason))
      end)

    json(conn, responses)
  end

  def handle(conn, %{"jsonrpc" => "2.0", "method" => _method} = request) do
    json(conn, response_for(request))
  end

  def handle(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32600, "message" => "Invalid JSON-RPC request"}
    })
  end

  defp dispatch("initialize", _params) do
    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "maraithon", "version" => app_version()}
     }}
  end

  defp dispatch("notifications/initialized", _params), do: {:ok, %{}}

  defp dispatch("tools/list", params) do
    names = if is_map(params), do: Map.get(params, "names"), else: nil
    {:ok, %{"tools" => Enum.map(Tools.describe(names), &mcp_tool_descriptor/1)}}
  end

  defp dispatch("tools/call", %{"name" => name} = params) when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    with true <- is_map(arguments) || {:error, -32602, "Tool arguments must be an object", nil} do
      case execute_tool(name, arguments, params) do
        {:ok, result} ->
          normalized = normalize(result)

          {:ok,
           %{
             "content" => [
               %{"type" => "text", "text" => encode_tool_text(normalized, params)}
             ],
             "structuredContent" => normalized,
             "isError" => false
           }}

        {:error, {:tool_policy_denied, decision}} ->
          {:error, -32070, Map.get(decision, "message", "Tool call denied"),
           %{"policy_decision" => decision}}

        {:error, {:tool_policy_needs_confirmation, decision}} ->
          {:error, -32071, Map.get(decision, "message", "Tool call requires confirmation"),
           %{"policy_decision" => decision}}

        {:error, reason} ->
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => error_text(reason)}],
             "isError" => true
           }}
      end
    else
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", _params), do: {:error, -32602, "Tool name is required", nil}
  defp dispatch(method, _params), do: {:error, -32601, "Method not found: #{method}", nil}

  defp execute_tool(name, arguments, params) do
    task =
      Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
        Tools.execute(name, arguments, tool_context(params))
      end)

    case Task.yield(task, @tool_call_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "tool_crashed: #{inspect(reason)}"}
      nil -> {:error, "tool_timeout: #{name} exceeded #{@tool_call_timeout_ms}ms"}
    end
  end

  defp tool_context(params) when is_map(params) do
    %{
      surface: "mcp",
      confirmed?: confirmed?(params),
      confirmation_state: confirmation_state(params)
    }
  end

  defp confirmed?(params) when is_map(params) do
    truthy?(Map.get(params, "confirmed")) or
      truthy?(get_in(params, ["_meta", "confirmed"])) or
      truthy?(get_in(params, ["arguments", "confirmed"])) or
      confirmation_state(params) == "confirmed"
  end

  defp confirmation_state(params) when is_map(params) do
    case Map.get(params, "confirmation_state") || get_in(params, ["_meta", "confirmation_state"]) ||
           get_in(params, ["arguments", "confirmation_state"]) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp response_for(%{"jsonrpc" => "2.0", "method" => method} = request) do
    id = Map.get(request, "id")

    case dispatch(method, Map.get(request, "params", %{})) do
      {:ok, result} ->
        %{"jsonrpc" => "2.0", "id" => id, "result" => result}

      {:error, code, message, data} ->
        error_response(id, code, message, data)
    end
  end

  defp response_for(_request) do
    error_response(nil, -32600, "Invalid JSON-RPC request", nil)
  end

  defp error_response(id, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => compact(%{"code" => code, "message" => message, "data" => data})
    }
  end

  defp mcp_tool_descriptor(%{
         name: name,
         description: description,
         input_schema: input_schema,
         annotations: annotations
       }) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => input_schema,
      "annotations" => annotations
    }
  end

  defp normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize(value) when is_struct(value), do: value |> Map.from_struct() |> normalize()
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize(nested)} end)
  end

  defp normalize(value), do: value

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text({:tool_policy_denied, decision}), do: Map.get(decision, "message", "Denied")

  defp error_text({:tool_policy_needs_confirmation, decision}),
    do: Map.get(decision, "message", "Confirmation required")

  defp error_text(reason), do: inspect(reason)

  defp encode_tool_text(result, params) do
    if pretty_response?(params) do
      Jason.encode!(result, pretty: true)
    else
      Jason.encode!(result)
    end
  end

  defp pretty_response?(params) when is_map(params) do
    Map.get(params, "pretty") == true or get_in(params, ["arguments", "pretty"]) == true
  end

  defp pretty_response?(_params), do: false

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp app_version do
    Application.spec(:maraithon, :vsn)
    |> to_string()
  end
end
