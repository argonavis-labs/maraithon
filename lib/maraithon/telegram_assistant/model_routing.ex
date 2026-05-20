defmodule Maraithon.TelegramAssistant.ModelRouting do
  @moduledoc """
  Selects the model tier for a Telegram assistant turn.

  This is a cost/latency router only. Semantic intent, tool choice, and final
  judgment still belong to the model-facing assistant contract.
  """

  alias Maraithon.LLM

  @default_chat_reasoning_effort "low"
  @default_reasoning_max_tokens 6_000

  @planning_patterns [
    ~r/\bmorning\s+brief(?:ing)?\b/u,
    ~r/\bdaily\s+brief(?:ing)?\b/u,
    ~r/\bbrief\s+me\b/u,
    ~r/\bwhat\s+should\s+i\s+(do|work\s+on|focus\s+on|review)\b/u,
    ~r/\bwhat\s+needs\s+my\s+attention\b/u,
    ~r/\bwhat\s+am\s+i\s+missing\b/u,
    ~r/\bnext\s+best\s+action\b/u,
    ~r/\b(triage|prioriti[sz]e|rank)\b.*\b(todos?|to-dos?|tasks?|work|open\s+loops?|inbox)\b/u,
    ~r/\b(todos?|to-dos?|tasks?|open\s+loops?)\b.*\b(full|detail|detailed|complete|all|everything|list)\b/u,
    ~r/\b(full|detailed|complete|all)\b.*\b(todos?|to-dos?|tasks?|open\s+loops?)\b/u
  ]

  def profile_for(attrs) when is_map(attrs) do
    tier = tier_for_text(Map.get(attrs, :text) || Map.get(attrs, "text"))
    model = model_for_tier(tier)
    reasoning_effort = reasoning_effort_for_tier(tier)

    %{
      tier: tier,
      model: model,
      reasoning_effort: reasoning_effort,
      max_tokens: max_tokens_for_tier(tier),
      llm_opts: llm_opts(tier, model, reasoning_effort)
    }
  end

  def tier_for_text(text) when is_binary(text) do
    normalized = normalize_text(text)

    if Enum.any?(@planning_patterns, &Regex.match?(&1, normalized)) do
      :reasoning
    else
      :chat
    end
  end

  def tier_for_text(_text), do: :chat

  defp llm_opts(tier, model, reasoning_effort) do
    []
    |> maybe_put(:chat_model, model)
    |> maybe_put(:reasoning_effort, reasoning_effort)
    |> maybe_put(:max_tokens, max_tokens_for_tier(tier))
  end

  defp model_for_tier(:reasoning), do: non_empty(LLM.model()) || non_empty(LLM.chat_model())
  defp model_for_tier(:chat), do: non_empty(LLM.chat_model()) || non_empty(LLM.model())

  defp reasoning_effort_for_tier(:reasoning), do: non_empty(LLM.intelligence()) || "high"

  defp reasoning_effort_for_tier(:chat) do
    config()
    |> Keyword.get(:chat_reasoning_effort, @default_chat_reasoning_effort)
    |> non_empty()
    |> case do
      nil -> @default_chat_reasoning_effort
      value -> value
    end
  end

  defp max_tokens_for_tier(:reasoning) do
    config()
    |> Keyword.get(:reasoning_max_tokens, @default_reasoning_max_tokens)
    |> positive_integer(@default_reasoning_max_tokens)
  end

  defp max_tokens_for_tier(:chat), do: nil

  defp normalize_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s-]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp config do
    Application.get_env(:maraithon, :telegram_assistant, [])
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp non_empty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty(_value), do: nil

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
