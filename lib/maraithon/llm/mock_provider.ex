defmodule Maraithon.LLM.MockProvider do
  @moduledoc """
  Mock LLM provider for testing.
  """

  @behaviour Maraithon.LLM.Adapter

  alias Maraithon.Spend

  require Logger

  @impl true
  def complete(params) do
    Logger.debug("MockProvider.complete called", params: inspect(params))

    # Simulate some latency
    Process.sleep(100)

    messages = params["messages"] || []
    last_message = List.last(messages) || %{}
    user_content = last_message["content"] || ""
    model = "mock-v1"
    tokens_in = String.length(user_content)
    tokens_out = 50

    response = %{
      content: generate_mock_response(user_content),
      model: model,
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      finish_reason: "stop",
      usage: Spend.calculate_cost(model, tokens_in, tokens_out)
    }

    {:ok, response}
  end

  defp generate_mock_response(prompt) do
    cond do
      String.contains?(prompt, Maraithon.Todos.Intelligence.sentinel()) ->
        todo_intelligence_response(prompt)

      String.contains?(prompt, Maraithon.Memory.Intelligence.sentinel()) ->
        memory_intelligence_response(prompt)

      String.contains?(prompt, "review") ->
        """
        **Code Review Summary**

        The code looks generally well-structured. Here are some observations:

        1. Consider adding more documentation
        2. Some functions could be broken into smaller pieces
        3. Test coverage could be improved

        Overall: Good code with room for minor improvements.
        """

      String.contains?(prompt, "summarize") ->
        """
        **Summary**

        Based on my analysis, the key points are:
        - The system is functioning normally
        - No critical issues detected
        - Activity levels are within expected ranges
        """

      true ->
        """
        Mock response generated at #{DateTime.utc_now() |> DateTime.to_iso8601()}.

        This is a placeholder response from the mock LLM provider.
        In production, this would be a real response from Claude.
        """
    end
  end

  defp todo_intelligence_response(prompt) do
    candidates = extract_json_after(prompt, "CANDIDATE_TODOS_JSON:") || []

    decisions =
      candidates
      |> Enum.with_index()
      |> Enum.map(fn {candidate, index} ->
        todo = candidate |> stringify_top_level_keys() |> ensure_mock_todo(index)

        %{
          "candidate_index" => index,
          "action" => "create",
          "existing_todo_id" => nil,
          "dedupe_key" => todo["dedupe_key"],
          "reasoning" => "Mock todo intelligence accepted the candidate.",
          "todo" => todo
        }
      end)

    Jason.encode!(%{
      "summary" => "Mock todo intelligence decisions.",
      "decisions" => decisions
    })
  end

  defp memory_intelligence_response(prompt) do
    candidates = extract_json_after(prompt, "CANDIDATE_MEMORIES_JSON:") || []

    selected =
      candidates
      |> Enum.take(12)
      |> Enum.map(fn candidate ->
        candidate = stringify_top_level_keys(candidate)

        %{
          "memory_id" => candidate["id"],
          "relevance" => 0.9,
          "reason" => "Mock memory intelligence selected this durable memory."
        }
      end)
      |> Enum.reject(&is_nil(&1["memory_id"]))

    Jason.encode!(%{
      "summary" => "Mock memory intelligence selected relevant memories.",
      "selected" => selected
    })
  end

  defp extract_json_after(prompt, marker) do
    case String.split(prompt, marker, parts: 2) do
      [_before, json] ->
        case Jason.decode(String.trim(json)) do
          {:ok, decoded} -> decoded
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp ensure_mock_todo(candidate, index) do
    source = read_string(candidate, "source", "telegram")
    kind = read_string(candidate, "kind", "general")
    title = read_string(candidate, "title", "Open todo")
    summary = read_string(candidate, "summary", read_string(candidate, "todo", title))
    next_action = read_string(candidate, "next_action", "Review and decide the next step.")
    source_item_id = read_string(candidate, "source_item_id", nil)

    dedupe_key =
      read_string(
        candidate,
        "dedupe_key",
        mock_dedupe_key(source, kind, source_item_id, title, index)
      )

    candidate
    |> Map.put("source", source)
    |> Map.put("kind", kind)
    |> Map.put_new("attention_mode", "act_now")
    |> Map.put("title", title)
    |> Map.put("summary", summary)
    |> Map.put("next_action", next_action)
    |> Map.put_new("priority", 50)
    |> Map.put_new("status", "open")
    |> Map.put("dedupe_key", dedupe_key)
    |> Map.update("metadata", %{}, fn
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end)
    |> Map.update("action_draft", %{}, fn
      draft when is_map(draft) -> draft
      draft when is_binary(draft) -> %{"text" => draft}
      _other -> %{}
    end)
  end

  defp mock_dedupe_key(source, kind, source_item_id, title, index) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "todo-#{index}"
        value -> value
      end

    item = source_item_id || "#{slug}-#{index}"
    "#{source}:#{kind}:#{item}"
  end

  defp read_string(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _other ->
        default
    end
  end

  defp stringify_top_level_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
