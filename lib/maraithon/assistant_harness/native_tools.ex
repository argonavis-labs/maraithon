defmodule Maraithon.AssistantHarness.NativeTools do
  @moduledoc """
  Provider protocol bridge for linked-todo conversations. Execution still belongs
  to the existing Runner and Toolbox. Provider continuation is transient; durable
  tool evidence remains the recovery source of truth.
  """

  alias Maraithon.{LLM, PromptBudget}

  @finish "maraithon_finish"
  @message_bytes 24_000
  @history_bytes 40_000

  def enabled?(payload, opts) do
    mode =
      Keyword.get(
        opts,
        :tool_protocol,
        Application.get_env(:maraithon, :todo_tool_protocol, :native)
      )

    todo = payload |> value(:context, %{}) |> value(:linked_item, %{}) |> value(:todo, %{})

    mode == :native and LLM.provider() == Maraithon.LLM.OpenRouterProvider and
      is_binary(value(todo, :id, nil))
  end

  def request(params, payload) do
    tools = Enum.map(value(payload, :tools, []), &%{"type" => "function", "function" => &1})
    exchanges = value(payload, :_native_exchanges, []) |> List.flatten()

    params
    |> Map.put("tools", tools ++ [finish_tool()])
    |> Map.put("tool_choice", "required")
    |> Map.put("parallel_tool_calls", true)
    |> Map.update!("messages", &(&1 ++ exchanges))
  end

  def contract do
    """
    Use provider-native function calls. Do not print a JSON envelope in content.
    Request up to three available functions to gather evidence or prepare actions.
    When ready to reply, call `#{@finish}` alone with the final assistant_message,
    message_class, summary, and optional correction. It is a response, not an action.
    Never mix it with other calls. The decision examples below describe semantics:
    `tool_calls` means native function calls; `final` means `#{@finish}`.
    Native tool messages contain actual execution results. Older exchanges may be
    compacted into the action/result history. Use that evidence without repeating
    completed actions. All approval and execution rules below still apply.
    """
  end

  def decode(%{message: %{"tool_calls" => calls} = message, finish_reason: "tool_calls"}, params) do
    with true <- valid_message?(message),
         :ok <- allowed_calls(calls, params),
         {:ok, decoded} <- decode_calls(calls) do
      {:ok, Map.put(decoded, "_native_message", message)}
    else
      {:error, {:assistant_harness_unknown_tool, _}} = error -> error
      _ -> {:error, :assistant_harness_invalid_tool_calls}
    end
  end

  def decode(_response, _params), do: {:error, :assistant_harness_invalid_tool_calls}

  defp allowed_calls(calls, params) do
    names = Enum.map(params["tools"] || [], &get_in(&1, ["function", "name"]))

    case Enum.find(calls, &(&1["function"]["name"] not in names)) do
      nil -> :ok
      call -> {:error, {:assistant_harness_unknown_tool, call["function"]["name"]}}
    end
  end

  def valid_message?(%{"tool_calls" => calls} = message) when is_list(calls) do
    calls != [] and length(calls) <= 3 and
      PromptBudget.encoded_bytes(message) <= @message_bytes and
      Enum.all?(calls, &valid_call?/1) and
      length(Enum.uniq_by(calls, & &1["id"])) == length(calls)
  end

  def valid_message?(_), do: false

  defp valid_call?(%{
         "id" => id,
         "type" => "function",
         "function" => %{"name" => name, "arguments" => args}
       }) do
    is_binary(id) and byte_size(id) in 1..255 and String.valid?(id) and
      is_binary(name) and byte_size(name) in 1..255 and String.valid?(name) and
      is_binary(args) and match?({:ok, %{}}, Jason.decode(args))
  end

  defp valid_call?(_), do: false

  defp decode_calls([%{"function" => %{"name" => @finish, "arguments" => args}}]) do
    with {:ok, %{"assistant_message" => message} = final} <- Jason.decode(args),
         true <- is_binary(message) and String.trim(message) != "" do
      {:ok, final |> Map.put("status", "final") |> Map.put("tool_calls", [])}
    else
      _ -> {:error, :invalid_final}
    end
  end

  defp decode_calls(calls) do
    if Enum.any?(calls, &(&1["function"]["name"] == @finish)) do
      {:error, :mixed_final}
    else
      {:ok,
       %{
         "status" => "tool_calls",
         "tool_calls" =>
           Enum.map(calls, fn call ->
             %{
               "tool" => call["function"]["name"],
               "arguments" => Jason.decode!(call["function"]["arguments"])
             }
           end)
       }}
    end
  end

  def attach(normalized, decoded) do
    case {normalized["status"], decoded["_native_message"]} do
      {"tool_calls", %{} = message} -> Map.put(normalized, "_native_message", message)
      _ -> normalized
    end
  end

  def record_exchange(state, entries) do
    case Map.get(state, :native_message) do
      %{"tool_calls" => calls} = message when length(calls) == length(entries) ->
        results =
          Enum.zip_with(calls, entries, fn call, entry ->
            result = Map.take(entry, ["result", "error"])

            %{
              "role" => "tool",
              "tool_call_id" => call["id"],
              "content" =>
                Jason.encode!(
                  PromptBudget.bounded(result, 4_000,
                    max_depth: 7,
                    string_bytes: 2_000,
                    list_items: 20,
                    map_entries: 40
                  )
                )
            }
          end)

        exchanges = Map.get(state, :native_exchanges, []) ++ [[message | results]]

        state
        |> Map.put(:native_exchanges, bound_exchanges(exchanges))
        |> Map.delete(:native_message)

      _ ->
        Map.delete(state, :native_message)
    end
  end

  # Drop whole exchanges, never a call ID, paired result, or opaque reasoning block.
  defp bound_exchanges([_old | rest] = exchanges) do
    if PromptBudget.encoded_bytes(exchanges) > @history_bytes,
      do: bound_exchanges(rest),
      else: exchanges
  end

  defp bound_exchanges([]), do: []

  defp finish_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => @finish,
        "description" =>
          "Finish this turn with a grounded reply or approval prompt. This function executes no action.",
        "parameters" => %{
          "type" => "object",
          "required" => ["assistant_message", "message_class"],
          "additionalProperties" => false,
          "properties" => %{
            "assistant_message" => %{"type" => "string"},
            "message_class" => %{
              "type" => "string",
              "enum" =>
                ~w(assistant_reply approval_prompt action_result system_notice todo_digest)
            },
            "summary" => %{
              "type" => "string",
              "description" => "Brief decision summary, not private reasoning."
            },
            "correction" => %{
              "type" => "object",
              "properties" => %{
                "detected" => %{"type" => "boolean"},
                "kind" => %{
                  "type" => "string",
                  "enum" => ~w(wrong_person already_done misunderstood value_correction other)
                },
                "subject" => %{"type" => "string"},
                "original_value" => %{"type" => "string"},
                "corrected_value" => %{"type" => "string"},
                "resource_type" => %{"type" => ["string", "null"]},
                "resource_id" => %{"type" => ["string", "null"]}
              }
            }
          }
        }
      }
    }
  end

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_, _, default), do: default
end
