defmodule Maraithon.InsightNotifications.MemoryGate do
  @moduledoc """
  Memory-aware interrupt gate (SPEC 07 R4).

  Before a proactive insight is allowed to interrupt via Telegram, this
  recalls durable `preference`/`instruction`/`relationship` memories using
  the insight summary as the query. When none are relevant, this is a fast
  no-op (allow) with zero extra model calls. When relevant memories exist,
  a lightweight routing-tier model call decides whether they should hold
  this specific interrupt — e.g. a "never surface newsletters" preference
  memory holding a matching insight. This is a semantic judgment call, so
  the runtime never keyword-matches memory content; it only fetches
  candidates and deterministically applies whatever the model decides.

  Fails open (allow) on any recall/model/timeout error so a memory-layer
  hiccup never silently suppresses a legitimate interrupt.
  """

  alias Maraithon.Insights.Insight
  alias Maraithon.LLM
  alias Maraithon.Memory

  require Logger

  @kinds ["preference", "instruction", "relationship"]
  @default_memory_limit 6
  @default_gate_timeout_ms 4_000
  @sentinel "MEMORY_INTERRUPT_GATE_JSON_V1"

  @doc """
  Returns true when `insight` should be allowed to interrupt (Telegram
  push), false when a matching durable memory should hold it instead.
  """
  def allow_interrupt?(user_id, insight, opts \\ [])

  def allow_interrupt?(user_id, %Insight{} = insight, opts) when is_binary(user_id) do
    case relevant_memories(user_id, insight, opts) do
      [] ->
        true

      memories ->
        case model_decision(insight, memories, opts) do
          {:ok, "hold", reason} ->
            Logger.info("Memory-aware interrupt gate held an insight",
              user_id: user_id,
              insight_id: insight.id,
              reason: reason
            )

            false

          _other ->
            true
        end
    end
  end

  def allow_interrupt?(_user_id, _insight, _opts), do: true

  @doc """
  Same recall step as `allow_interrupt?/3`, exposed separately so callers
  that already run their own model decision (e.g. `DeliveryPlanner`'s batch
  plan) can fold these memories into their own prompt context instead of
  paying for a second model call.
  """
  def relevant_memories(user_id, insight, opts \\ [])

  def relevant_memories(user_id, %Insight{} = insight, opts) when is_binary(user_id) do
    recall_memories(user_id, insight_query(insight), opts)
  end

  def relevant_memories(_user_id, _insight, _opts), do: []

  @doc """
  Recalls `preference`/`instruction`/`relationship` memories for an
  arbitrary text query (title/summary of one or more pending proactive
  items). Used directly by callers that don't have an `%Insight{}` struct
  (e.g. `DeliveryPlanner`'s batched candidates).
  """
  def recall_memories(user_id, query, opts \\ [])

  def recall_memories(user_id, query, opts) when is_binary(user_id) and is_binary(query) do
    limit = Keyword.get(opts, :memory_limit, @default_memory_limit)

    user_id
    |> Memory.prompt_context(query: query, kinds: @kinds, limit: limit)
    |> Map.get(:memories, [])
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  def recall_memories(_user_id, _query, _opts), do: []

  defp insight_query(%Insight{} = insight) do
    [insight.title, insight.summary, insight.category]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp model_decision(%Insight{} = insight, memories, opts) do
    params = build_request(insight, memories, opts)
    llm_complete = Keyword.get(opts, :llm_complete, &LLM.complete_routing/1)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_gate_timeout_ms)

    task = Task.async(fn -> llm_complete.(params) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, response}} -> decode_decision(response)
      {:ok, {:error, reason}} -> {:error, reason}
      _other -> {:error, :unavailable}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp decode_decision(response) do
    with content when is_binary(content) <- response_content(response),
         {:ok, decoded} <- decode_json(content),
         decision when decision in ["allow", "hold"] <- Map.get(decoded, "decision") do
      {:ok, decision, Map.get(decoded, "reason")}
    else
      _other -> {:error, :invalid_response}
    end
  end

  defp response_content(%{content: content}) when is_binary(content), do: content
  defp response_content(%{"content" => content}) when is_binary(content), do: content
  defp response_content(_response), do: nil

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

  defp build_request(insight, memories, opts) do
    %{
      "messages" => [
        %{"role" => "system", "content" => system_prompt()},
        %{"role" => "user", "content" => build_prompt(insight, memories)}
      ],
      "max_tokens" => Keyword.get(opts, :max_tokens, 300),
      "temperature" => 0.0,
      "reasoning_effort" => "low"
    }
  end

  defp system_prompt do
    "You are a precise gatekeeper deciding whether a proactive notification should " <>
      "interrupt the operator, given their durable standing preferences, instructions, " <>
      "and relationship context. Be conservative: only hold when a memory clearly applies."
  end

  defp build_prompt(%Insight{} = insight, memories) do
    """
    Decide whether this proactive insight should be allowed to interrupt the operator via Telegram right now, or held back because a durable memory below says not to surface it (or something equivalent).

    Return ONLY valid JSON:
    #{@sentinel}
    {"decision":"allow|hold","reason":"short reason","matched_memory_id":"id or null"}

    Rules:
    - Use "hold" only when a memory clearly applies to this specific insight — e.g. a "never surface X" or "don't interrupt me about Y" preference/instruction, or a relationship note saying this contact/topic should not trigger a push.
    - Default to "allow" when memories are only tangentially related or ambiguous.

    INSIGHT_JSON:
    #{Jason.encode!(insight_for_prompt(insight))}

    MEMORIES_JSON:
    #{Jason.encode!(Enum.map(memories, &memory_for_prompt/1))}
    """
  end

  defp insight_for_prompt(%Insight{} = insight) do
    %{
      title: insight.title,
      summary: insight.summary,
      category: insight.category,
      source: insight.source
    }
  end

  defp memory_for_prompt(memory) do
    %{
      id: Map.get(memory, :id) || Map.get(memory, "id"),
      kind: Map.get(memory, :kind) || Map.get(memory, "kind"),
      title: Map.get(memory, :title) || Map.get(memory, "title"),
      content:
        Map.get(memory, :summary) || Map.get(memory, "summary") || Map.get(memory, :content) ||
          Map.get(memory, "content"),
      polarity: Map.get(memory, :polarity) || Map.get(memory, "polarity")
    }
  end
end
