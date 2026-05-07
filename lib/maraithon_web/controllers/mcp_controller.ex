defmodule MaraithonWeb.McpController do
  use MaraithonWeb, :controller

  alias Maraithon.Tools

  @protocol_version "2025-03-26"

  def call(conn, %{"jsonrpc" => "2.0", "method" => method} = request) do
    id = Map.get(request, "id")

    case dispatch(method, Map.get(request, "params", %{})) do
      {:ok, result} ->
        json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

      {:error, code, message, data} ->
        json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => compact(%{"code" => code, "message" => message, "data" => data})
        })
    end
  end

  def call(conn, _params) do
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

  defp dispatch("tools/list", _params) do
    {:ok, %{"tools" => Enum.map(Tools.describe(), &mcp_tool_descriptor/1)}}
  end

  defp dispatch("tools/call", %{"name" => name} = params) when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    if Tools.exists?(name) do
      case Tools.execute(name, arguments) do
        {:ok, result} ->
          {:ok,
           %{
             "content" => [
               %{"type" => "text", "text" => Jason.encode!(normalize(result), pretty: true)}
             ],
             "structuredContent" => normalize(result),
             "isError" => false
           }}

        {:error, reason} ->
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => error_text(reason)}],
             "isError" => true
           }}
      end
    else
      {:error, -32602, "Unknown tool: #{name}", nil}
    end
  end

  defp dispatch("tools/call", _params), do: {:error, -32602, "Tool name is required", nil}
  defp dispatch(method, _params), do: {:error, -32601, "Method not found: #{method}", nil}

  defp mcp_tool_descriptor(%{name: name, description: description, input_schema: input_schema}) do
    %{"name" => name, "description" => description, "inputSchema" => input_schema}
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
  defp error_text(reason), do: inspect(reason)

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
