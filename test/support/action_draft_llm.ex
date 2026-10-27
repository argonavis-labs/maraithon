defmodule Maraithon.TestSupport.ActionDraftLLM do
  @moduledoc false

  @behaviour Maraithon.LLM.Adapter

  alias Maraithon.Spend

  def complete(params) do
    prompt =
      params
      |> Map.get("messages", [])
      |> List.last()
      |> case do
        %{"content" => content} -> content
        _ -> ""
      end

    maybe_record_prompt(prompt)

    content =
      cond do
        String.contains?(prompt, Maraithon.Todos.Intelligence.sentinel()) ->
          todo_intelligence_response(prompt)

        String.contains?(prompt, Maraithon.Memory.Intelligence.sentinel()) ->
          memory_intelligence_response(prompt)

        String.contains?(prompt, "\"subject\":\"...\",\"body\":\"...\"") ->
          ~s({"subject":"Re: Quick follow-up","body":"Hi there,\\n\\nFollowing up on this now. I will send the remaining detail by end of day.\\n\\nBest,\\nMaraithon"})

        String.contains?(prompt, "\"text\":\"...\"") ->
          ~s({"text":"Following up on this now. Owner is me, next step is in progress, ETA today."})

        true ->
          ~s({"text":"Fallback draft"})
      end

    {:ok,
     %{
       content: content,
       model: "test-action-draft",
       tokens_in: 100,
       tokens_out: 40,
       finish_reason: "stop",
       usage: Spend.calculate_cost("test-action-draft", 100, 40)
     }}
  end

  defp maybe_record_prompt(prompt) do
    case Process.whereis(:action_draft_prompt_recorder) do
      nil ->
        :ok

      pid ->
        Agent.update(pid, fn prompts -> [prompt | prompts] end)
        :ok
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
          "reasoning" => "Test todo intelligence accepted the candidate.",
          "todo" => todo
        }
      end)

    Jason.encode!(%{
      "summary" => "Test todo intelligence decisions.",
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
          "reason" => "Test memory intelligence selected this durable memory."
        }
      end)
      |> Enum.reject(&is_nil(&1["memory_id"]))

    Jason.encode!(%{
      "summary" => "Test memory intelligence selected relevant memories.",
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

    next_action =
      read_string(
        candidate,
        "next_action",
        "Open the source item, confirm the specific request, and decide whether this still matters."
      )

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
