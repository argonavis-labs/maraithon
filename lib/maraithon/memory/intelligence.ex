defmodule Maraithon.Memory.Intelligence do
  @moduledoc """
  Model-level memory recall selection.

  The local database provides candidate memories. This module asks the model
  which candidates are actually relevant to the current runtime query.
  """

  alias Maraithon.LLM

  @sentinel "MARAITHON_MEMORY_INTELLIGENCE_V1"
  @default_limit 12

  def sentinel, do: @sentinel

  def select_relevant(user_id, query, candidates, opts \\ [])

  def select_relevant(user_id, query, candidates, opts)
      when is_binary(user_id) and is_list(candidates) do
    limit =
      opts
      |> Keyword.get(:limit, @default_limit)
      |> clamp_limit()

    cond do
      candidates == [] ->
        {:ok, %{summary: "No candidate memories.", items: []}}

      disabled?(opts) ->
        {:error, :memory_intelligence_disabled}

      true ->
        prompt = recall_prompt(user_id, query || "", candidates, limit)

        with {:ok, response} <- complete(prompt, opts),
             {:ok, decoded} <- decode_json(response),
             {:ok, selected} <- normalize_selection(decoded, candidates, limit) do
          {:ok,
           %{
             summary: Map.get(decoded, "summary") || "Selected relevant durable memories.",
             items: selected
           }}
        end
    end
  end

  def select_relevant(_user_id, _query, _candidates, _opts), do: {:error, :invalid_args}

  defp recall_prompt(user_id, query, candidates, limit) do
    """
    #{@sentinel}

    You select durable Maraithon memories that should influence the next model/runtime step.

    Return ONLY valid JSON:
    {
      "summary":"short recall summary",
      "selected":[
        {"memory_id":"...", "relevance":0.0, "reason":"why this memory matters now"}
      ]
    }

    Rules:
    - Use reasoning over the memory content and the query. Do not rely on exact keyword matching only.
    - Select at most #{limit} memories.
    - Select none if the memories are not useful for this query.
    - Prefer high-signal durable facts, corrections, preferences, and relevance feedback.
    - If a memory says something is not relevant, select it when it would prevent surfacing similar noise.

    USER_ID:
    #{user_id}

    QUERY:
    #{query}

    CANDIDATE_MEMORIES_JSON:
    #{Jason.encode!(candidates)}
    """
  end

  defp complete(prompt, opts) do
    case Keyword.get(opts, :llm_complete) || configured_llm_complete() do
      fun when is_function(fun, 1) ->
        fun.(prompt)

      _other ->
        default_llm_complete(prompt)
    end
  end

  defp configured_llm_complete do
    config = Application.get_env(:maraithon, :memory_intelligence, [])

    case Keyword.get(config, :llm_complete) do
      fun when is_function(fun, 1) -> fun
      _other -> nil
    end
  end

  defp default_llm_complete(prompt) do
    params = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => 1_000,
      "temperature" => 0.1,
      "reasoning_effort" => "medium"
    }

    if mock_when_unconfigured?() and is_nil(LLM.provider()) do
      with {:ok, response} <- Maraithon.LLM.MockProvider.complete(params) do
        {:ok, response.content}
      end
    else
      case LLM.complete(params) do
        {:ok, response} -> {:ok, response.content}
        {:error, _reason} = error -> error
      end
    end
  end

  defp mock_when_unconfigured? do
    configured? =
      Application.get_env(:maraithon, :memory_intelligence, [])
      |> Keyword.get(:mock_llm_when_unconfigured, false)

    configured? or mix_test_env?()
  end

  defp mix_test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  defp decode_json(%{content: content}) when is_binary(content), do: decode_json(content)

  defp decode_json(content) when is_binary(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, :invalid_json}
    end
  end

  defp decode_json(_content), do: {:error, :invalid_json}

  defp normalize_selection(decoded, candidates, limit) do
    by_id =
      Map.new(candidates, fn candidate ->
        id = Map.get(candidate, :id) || Map.get(candidate, "id")
        {id, candidate}
      end)

    selected =
      decoded
      |> Map.get("selected", [])
      |> Enum.flat_map(fn
        %{"memory_id" => memory_id} = selection when is_binary(memory_id) ->
          case Map.get(by_id, memory_id) do
            nil ->
              []

            candidate ->
              [
                candidate
                |> serialize_candidate()
                |> Map.put(:relevance, normalize_relevance(Map.get(selection, "relevance")))
                |> Map.put(:reason, normalize_reason(Map.get(selection, "reason")))
              ]
          end

        _other ->
          []
      end)
      |> Enum.take(limit)

    {:ok, selected}
  end

  defp normalize_relevance(value) when is_float(value), do: min(max(value, 0.0), 1.0)
  defp normalize_relevance(value) when is_integer(value), do: normalize_relevance(value / 1)

  defp normalize_relevance(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> normalize_relevance(parsed)
      _other -> 0.75
    end
  end

  defp normalize_relevance(_value), do: 0.75

  defp normalize_reason(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "Relevant durable memory."
      normalized -> normalized
    end
  end

  defp normalize_reason(_value), do: "Relevant durable memory."

  defp serialize_candidate(%{} = candidate) do
    %{
      id: Map.get(candidate, :id) || Map.get(candidate, "id"),
      status: Map.get(candidate, :status) || Map.get(candidate, "status"),
      kind: Map.get(candidate, :kind) || Map.get(candidate, "kind"),
      scope: Map.get(candidate, :scope) || Map.get(candidate, "scope"),
      title: Map.get(candidate, :title) || Map.get(candidate, "title"),
      content: Map.get(candidate, :content) || Map.get(candidate, "content"),
      summary:
        Map.get(candidate, :summary) || Map.get(candidate, "summary") ||
          Map.get(candidate, :content) || Map.get(candidate, "content"),
      source: Map.get(candidate, :source) || Map.get(candidate, "source"),
      tags: Map.get(candidate, :tags) || Map.get(candidate, "tags") || [],
      importance: Map.get(candidate, :importance) || Map.get(candidate, "importance") || 0,
      confidence: Map.get(candidate, :confidence) || Map.get(candidate, "confidence") || 0.0,
      polarity: Map.get(candidate, :polarity) || Map.get(candidate, "polarity") || "neutral",
      metadata: Map.get(candidate, :metadata) || Map.get(candidate, "metadata") || %{},
      updated_at: Map.get(candidate, :updated_at) || Map.get(candidate, "updated_at")
    }
  end

  defp disabled?(opts), do: Keyword.get(opts, :disable_llm?, false)

  defp clamp_limit(value) when is_integer(value), do: value |> max(1) |> min(40)

  defp clamp_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> clamp_limit(parsed)
      _other -> @default_limit
    end
  end

  defp clamp_limit(_value), do: @default_limit
end
