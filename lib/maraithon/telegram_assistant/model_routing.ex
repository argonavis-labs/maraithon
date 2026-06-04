defmodule Maraithon.TelegramAssistant.ModelRouting do
  @moduledoc """
  Selects the model tier for a Telegram assistant turn.

  This is a cost/latency router only. Semantic intent, tool choice, and final
  judgment still belong to the model-facing assistant contract.
  """

  alias Maraithon.LLM

  @default_chat_reasoning_effort "none"
  @default_reasoning_max_tokens 6_000
  @default_reasoning_wall_clock_ms 120_000
  @default_reasoning_llm_turns 8
  @default_reasoning_tool_steps 18

  @planning_patterns [
    ~r/\bmorning\s+brief(?:ing)?\b/u,
    ~r/\bdaily\s+brief(?:ing)?\b/u,
    ~r/\bbrief\s+me\b/u,
    ~r/\bwhat\s+matters\s+today\b/u,
    ~r/\bwhat\s+can\s+i\s+handle\b.*\b(\d+\s*)?(minutes?|mins?)\b/u,
    ~r/\bwhat\s+should\s+i\s+do\s+(next|today)\b/u,
    ~r/\bwhat\s+should\s+i\s+(do|work\s+on|focus\s+on|review)\b/u,
    ~r/\bwhat\s+needs\s+my\s+attention\b/u,
    ~r/\b(todos?|to-dos?|tasks?|open\s+loops?)\b.*\bneed(?:s)?\b.*\battention\b/u,
    ~r/\bwhat\s+am\s+i\s+missing\b/u,
    ~r/\bwho\s+am\s+i\s+waiting\s+on\b/u,
    ~r/\bwho\s+is\s+waiting\s+on\s+me\b/u,
    ~r/\bwho\s+owes\s+me\b/u,
    ~r/\bwhat\s+do\s+i\s+owe\b/u,
    ~r/\bnext\s+best\s+action\b/u,
    ~r/\b(triage|prioriti[sz]e|rank)\b.*\b(todos?|to-dos?|tasks?|work|open\s+loops?|inbox)\b/u,
    ~r/\b(todos?|to-dos?|tasks?|open\s+loops?)\b.*\b(full|detail|detailed|complete|all|everything|list)\b/u,
    ~r/\b(full|detailed|complete|all)\b.*\b(todos?|to-dos?|tasks?|open\s+loops?)\b/u,
    ~r/\b(meeting\s+prep|prep\s+for|prepare\s+for)\b.*\b(meeting|call|conversation)\b/u,
    ~r/\bwhat\s+should\s+i\s+know\b.*\b(meeting|call|conversation|before)\b/u,
    ~r/\bwho\s+(am\s+i\s+meeting|is\s+on\s+my\s+calendar)\b/u,
    ~r/\b(draft|write)\b.*\b(reply|response|email|message)\b/u,
    ~r/\b(queue|schedule|create)\b.*\b(job|task|review|brief|prep)\b/u,
    ~r/\b(long[-\s]?running|background)\s+(job|task|work)\b/u,
    ~r/\b(connected\s+apps?|connected\s+sources?|crm|calendar|todos?|memory)\b.*\b(search|look|review|context)\b/u,
    ~r/\blook\s+across\b.*\b(accounts?|apps?|sources?|crm|calendar|todos?)\b/u,
    ~r/\b(which|what|who|show|list|review|look\s+up)\b.*\b(contacts?|people|relationships?|crm)\b.*\b(stale|follow[-\s]?ups?|follow\s+up|attention|waiting|owe|next|notes?|reach\s+out|nudge)\b/u,
    ~r/\b(who|which\s+contacts?)\b.*\b(follow\s+up|reach\s+out|nudge|stale)\b/u,
    ~r/\bcontacts?\b.*\b(stale|follow[-\s]?ups?|follow\s+up|attention|waiting|owe|notes?)\b/u
  ]

  @quick_chat_patterns [
    ~r/\bgive\s+me\s+a\s+concise\b.*\breply\s+to\s+someone\b/u,
    ~r/\bwrite\s+a\s+quick\b.*\breply\s+to\s+someone\b/u,
    ~r/\brewrite\s+this\b/u,
    ~r/\bmake\s+this\s+clearer\b/u,
    ~r/\bwordsmith\s+this\b/u
  ]

  @today_mode_patterns [
    ~r/\bwhat\s+matters\s+today\b/u,
    ~r/\bwhat\s+can\s+i\s+handle\b.*\b(\d+\s*)?(minutes?|mins?)\b/u,
    ~r/\bwhat\s+should\s+i\s+do\s+(next|today)\b/u,
    ~r/\bwhat\s+should\s+i\s+(work\s+on|focus\s+on)\b/u,
    ~r/\bwhat\s+needs\s+my\s+attention\b/u,
    ~r/\b(todos?|to-dos?|tasks?|open\s+loops?)\b.*\bneed(?:s)?\b.*\battention\b/u,
    ~r/\bnext\s+best\s+action\b/u
  ]

  @waiting_on_patterns [
    ~r/\bwho\s+am\s+i\s+waiting\s+on\b/u,
    ~r/\bwho\s+is\s+waiting\s+on\s+me\b/u,
    ~r/\bwho\s+owes\s+me\b/u,
    ~r/\bwhat\s+do\s+i\s+owe\b/u,
    ~r/\bwaiting\s+on\b/u
  ]

  @meeting_prep_patterns [
    ~r/\b(meeting\s+prep|prep\s+for|prepare\s+for)\b.*\b(meeting|call|conversation)\b/u,
    ~r/\bwhat\s+should\s+i\s+know\b.*\b(meeting|call|conversation|before)\b/u,
    ~r/\bwho\s+(am\s+i\s+meeting|is\s+on\s+my\s+calendar)\b/u
  ]

  @person_context_patterns [
    ~r/\bwho\s+(is|are)\s+(?!this|that|they|them|he|she|it|person)\p{L}/u,
    ~r/\b(tell|remind)\s+me\s+about\s+\p{L}/u,
    ~r/\bwhat\s+should\s+i\s+know\s+about\s+\p{L}/u,
    ~r/\blook\s+up\b.*\bcontact\s+named\s+\p{L}/u,
    ~r/\bwhat\s+notes?\b.*\b(contact|person)\b/u,
    ~r/\bwhat\s+do\s+i\s+owe\s+\p{L}/u,
    ~r/\bwhat\s+does\s+\p{L}.*\b(need|want|expect)\b/u,
    ~r/\bwhy\s+(am\s+i\s+meeting|do\s+i\s+know|are\s+we\s+meeting)\b.*\p{L}/u
  ]

  @connector_status_patterns [
    ~r/\b(which|what|show|list)\b.*\b(connections?|connectors?|integrations?|accounts?|sources?)\b.*\b(connected|active|enabled|working|status)\b/u,
    ~r/\b(connected|active|enabled|working)\b.*\b(connections?|connectors?|integrations?|accounts?|sources?)\b/u,
    ~r/\bwhat\s+(is|do\s+i\s+have)\s+connected\b/u,
    ~r/\bconnection\s+status\b/u,
    ~r/\bconnector\s+status\b/u
  ]

  @linked_item_context_patterns [
    ~r/\bwho\s+(is|are)\s+(this|that|they|them|he|she|it|person)\b/u,
    ~r/\bwho\s+am\s+i\s+(talking|replying|responding)\s+to\b/u,
    ~r/\bwhat\s+(is|was)\s+(this|that|it)\b/u,
    ~r/\bwhy\s+(am\s+i\s+seeing|did\s+you\s+send|is\s+this\s+here)\b/u,
    ~r/\bwhy\s+(does|do)\s+(this|that|it|they)\s+matter\b/u,
    ~r/\bwhat\s+do\s+i\s+(owe|need\s+to\s+do)\b/u,
    ~r/\bwhat\s+should\s+i\s+(do|say|reply)\b/u,
    ~r/\bcontext\b/u,
    ~r/\bmore\s+context\b/u,
    ~r/\bremind\s+me\b/u
  ]

  def profile_for(attrs) when is_map(attrs) do
    text = Map.get(attrs, :text) || Map.get(attrs, "text")
    tier = tier_for_text(text)
    request_focus = request_focus_for_attrs(attrs, text)
    task_class = task_class_for(tier, request_focus, text)
    route_reason = route_reason_for(tier, request_focus, text)
    model = model_for_tier(tier)
    reasoning_effort = reasoning_effort_for_tier(tier)

    %{
      tier: tier,
      request_focus: request_focus,
      task_class: task_class,
      route_reason: route_reason,
      model: model,
      reasoning_effort: reasoning_effort,
      max_tokens: max_tokens_for_tier(tier),
      llm_opts: llm_opts(tier, model, reasoning_effort, request_focus)
    }
  end

  def escalated_profile_for(profile) when is_map(profile) do
    request_focus = Map.get(profile, :request_focus) || Map.get(profile, "request_focus")
    task_class = Map.get(profile, :task_class) || Map.get(profile, "task_class") || :reasoning
    route_reason = Map.get(profile, :route_reason) || Map.get(profile, "route_reason") || "chat"
    model = model_for_tier(:reasoning)
    reasoning_effort = reasoning_effort_for_tier(:reasoning)

    %{
      tier: :reasoning,
      request_focus: request_focus,
      task_class: task_class,
      route_reason: "escalated_to_reasoning:#{route_label(route_reason)}",
      model: model,
      reasoning_effort: reasoning_effort,
      max_tokens: max_tokens_for_tier(:reasoning),
      llm_opts:
        :reasoning
        |> llm_opts(model, reasoning_effort, request_focus)
        |> Keyword.put(:max_wall_clock_ms, reasoning_wall_clock_ms())
        |> Keyword.put(:max_llm_turns, reasoning_llm_turns())
        |> Keyword.put(:max_tool_steps, reasoning_tool_steps())
        |> Keyword.put(:model_busy_max_retries, 35)
        |> Keyword.put(:model_retry_max_delay_ms, 2_000)
    }
  end

  def tier_for_text(text) when is_binary(text) do
    normalized = normalize_text(text)

    cond do
      Enum.any?(@quick_chat_patterns, &Regex.match?(&1, normalized)) ->
        :chat

      source_hint_person_question?(normalized) ->
        :chat

      Enum.any?(@person_context_patterns, &Regex.match?(&1, normalized)) ->
        :reasoning

      Enum.any?(@planning_patterns, &Regex.match?(&1, normalized)) ->
        :reasoning

      true ->
        :chat
    end
  end

  def tier_for_text(_text), do: :chat

  defp request_focus_for_attrs(attrs, text) do
    cond do
      explicit_request_focus(attrs) ->
        explicit_request_focus(attrs)

      linked_reply?(attrs) && linked_item_action_request?(text) ->
        :linked_item_context

      linked_reply?(attrs) && linked_item_context_request?(text) ->
        :linked_item_context

      true ->
        request_focus_for_text(text)
    end
  end

  defp explicit_request_focus(attrs) when is_map(attrs) do
    attrs
    |> Map.get(:request_focus, Map.get(attrs, "request_focus"))
    |> normalize_focus_value()
  end

  defp explicit_request_focus(_attrs), do: nil

  defp normalize_focus_value(value) when is_atom(value), do: value

  defp normalize_focus_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "connector_status" -> :connector_status
      "source_hint_identity" -> :source_hint_identity
      "linked_item_context" -> :linked_item_context
      "quick_chat" -> :quick_chat
      "today_mode" -> :today_mode
      "meeting_prep" -> :meeting_prep
      "waiting_on" -> :waiting_on
      "person_context" -> :person_context
      _other -> nil
    end
  end

  defp normalize_focus_value(_value), do: nil

  defp request_focus_for_text(text) when is_binary(text) do
    normalized = normalize_text(text)

    cond do
      source_hint_person_question?(normalized) ->
        :source_hint_identity

      Enum.any?(@connector_status_patterns, &Regex.match?(&1, normalized)) ->
        :connector_status

      Enum.any?(@today_mode_patterns, &Regex.match?(&1, normalized)) ->
        :today_mode

      Enum.any?(@meeting_prep_patterns, &Regex.match?(&1, normalized)) ->
        :meeting_prep

      Enum.any?(@waiting_on_patterns, &Regex.match?(&1, normalized)) ->
        :waiting_on

      Enum.any?(@person_context_patterns, &Regex.match?(&1, normalized)) ->
        :person_context

      Enum.any?(@quick_chat_patterns, &Regex.match?(&1, normalized)) ->
        :quick_chat

      true ->
        nil
    end
  end

  defp request_focus_for_text(_text), do: nil

  defp llm_opts(tier, model, reasoning_effort, request_focus) do
    []
    |> maybe_put(:chat_model, model)
    |> maybe_put(:reasoning_effort, reasoning_effort)
    |> maybe_put(:max_tokens, max_tokens_for_tier(tier))
    |> maybe_put_focus(request_focus)
  end

  defp maybe_put_focus(keyword, :connector_status) do
    keyword
    |> Keyword.put(:request_focus, :connector_status)
    |> Keyword.put(:context_scope, :connector_status)
    |> Keyword.put(:tool_scope, :connector_status)
    |> Keyword.put(:max_tokens, 700)
    |> Keyword.put(:max_wall_clock_ms, 15_000)
    |> Keyword.put(:max_llm_turns, 3)
    |> Keyword.put(:max_tool_steps, 3)
  end

  defp maybe_put_focus(keyword, :source_hint_identity) do
    keyword
    |> Keyword.put(:request_focus, :source_hint_identity)
    |> Keyword.put(:context_scope, :person_context)
    |> Keyword.put(:tool_scope, :person_context)
    |> Keyword.put(:max_tokens, 900)
    |> Keyword.put(:max_wall_clock_ms, 30_000)
    |> Keyword.put(:max_llm_turns, 4)
    |> Keyword.put(:max_tool_steps, 5)
  end

  defp maybe_put_focus(keyword, :linked_item_context) do
    keyword
    |> Keyword.put(:request_focus, :linked_item_context)
    |> Keyword.put(:context_scope, :linked_item_context)
    |> Keyword.put(:tool_scope, :linked_item_context)
    |> Keyword.put(:max_wall_clock_ms, 75_000)
    |> Keyword.put(:max_llm_turns, 5)
    |> Keyword.put(:max_tool_steps, 8)
    |> Keyword.put(:model_busy_max_retries, 20)
    |> Keyword.put(:model_retry_max_delay_ms, 1_500)
  end

  defp maybe_put_focus(keyword, :quick_chat) do
    keyword
    |> Keyword.put(:request_focus, :quick_chat)
    |> Keyword.put(:context_scope, :quick_chat)
    |> Keyword.put(:tool_scope, :quick_chat)
    |> Keyword.put(:max_tokens, 700)
    |> Keyword.put(:max_wall_clock_ms, 15_000)
    |> Keyword.put(:max_llm_turns, 3)
    |> Keyword.put(:max_tool_steps, 1)
  end

  defp maybe_put_focus(keyword, :today_mode) do
    keyword
    |> Keyword.put(:request_focus, :today_mode)
    |> Keyword.put(:context_scope, :today_mode)
    |> Keyword.put(:tool_scope, :today_mode)
    |> Keyword.put(:max_wall_clock_ms, 90_000)
    |> Keyword.put(:max_llm_turns, 6)
    |> Keyword.put(:max_tool_steps, 12)
    |> Keyword.put(:model_busy_max_retries, 24)
    |> Keyword.put(:model_retry_max_delay_ms, 1_500)
  end

  defp maybe_put_focus(keyword, :meeting_prep) do
    keyword
    |> Keyword.put(:request_focus, :meeting_prep)
    |> Keyword.put(:context_scope, :meeting_prep)
    |> Keyword.put(:tool_scope, :meeting_prep)
    |> Keyword.put(:max_wall_clock_ms, 90_000)
    |> Keyword.put(:max_llm_turns, 6)
    |> Keyword.put(:max_tool_steps, 12)
    |> Keyword.put(:model_busy_max_retries, 24)
    |> Keyword.put(:model_retry_max_delay_ms, 1_500)
  end

  defp maybe_put_focus(keyword, :waiting_on) do
    keyword
    |> Keyword.put(:request_focus, :waiting_on)
    |> Keyword.put(:context_scope, :waiting_on)
    |> Keyword.put(:tool_scope, :waiting_on)
    |> Keyword.put(:max_wall_clock_ms, 90_000)
    |> Keyword.put(:max_llm_turns, 6)
    |> Keyword.put(:max_tool_steps, 12)
    |> Keyword.put(:model_busy_max_retries, 24)
    |> Keyword.put(:model_retry_max_delay_ms, 1_500)
  end

  defp maybe_put_focus(keyword, :person_context) do
    keyword
    |> Keyword.put(:request_focus, :person_context)
    |> Keyword.put(:context_scope, :person_context)
    |> Keyword.put(:tool_scope, :person_context)
    |> Keyword.put(:max_wall_clock_ms, 90_000)
    |> Keyword.put(:max_llm_turns, 6)
    |> Keyword.put(:max_tool_steps, 10)
    |> Keyword.put(:model_busy_max_retries, 24)
    |> Keyword.put(:model_retry_max_delay_ms, 1_500)
  end

  defp maybe_put_focus(keyword, _focus), do: keyword

  defp linked_reply?(attrs) when is_map(attrs) do
    attrs
    |> Map.get(:reply_to_message_id, Map.get(attrs, "reply_to_message_id"))
    |> present?()
  end

  defp linked_reply?(_attrs), do: false

  defp linked_item_action_request?(text) when is_binary(text) do
    text
    |> normalize_text()
    |> then(fn normalized ->
      Regex.match?(
        ~r/\b(done|handled|complete|completed|close|closed|resolve|resolved|dismiss|delete|remove|irrelevant|no\s+longer\s+relevant|not\s+relevant|noise|change|update|edit|snooze|later|tomorrow|work|home|personal)\b/u,
        normalized
      )
    end)
  end

  defp linked_item_action_request?(_text), do: false

  defp linked_item_context_request?(text) when is_binary(text) do
    normalized = normalize_text(text)

    normalized != "" &&
      (String.length(normalized) <= 120 ||
         Regex.match?(~r/\b(this|that|it|person|context|remind|owe|reply)\b/u, normalized)) &&
      Enum.any?(@linked_item_context_patterns, &Regex.match?(&1, normalized))
  end

  defp linked_item_context_request?(_text), do: false

  defp source_hint_person_question?(text) when is_binary(text) do
    Regex.match?(
      ~r/\bwho\s+(is|are)\s+\p{L}.*\b(from|in|on)\s+(slack|gmail|email|calendar|crm|contacts?|google|connected\s+(app|source))\b/u,
      text
    )
  end

  defp source_hint_person_question?(_text), do: false

  defp task_class_for(_tier, :linked_item_context, _text), do: :linked_item_context
  defp task_class_for(_tier, :source_hint_identity, _text), do: :source_hint_identity
  defp task_class_for(_tier, :connector_status, _text), do: :connector_status
  defp task_class_for(_tier, :today_mode, _text), do: :today_mode
  defp task_class_for(_tier, :meeting_prep, _text), do: :meeting_prep
  defp task_class_for(_tier, :person_context, _text), do: :person_context
  defp task_class_for(_tier, :waiting_on, _text), do: :waiting_on
  defp task_class_for(_tier, :quick_chat, _text), do: :quick_chat

  defp task_class_for(:reasoning, _focus, text) when is_binary(text) do
    normalized = normalize_text(text)

    cond do
      Enum.any?(@planning_patterns, &Regex.match?(&1, normalized)) -> :planning
      true -> :reasoning
    end
  end

  defp task_class_for(:chat, _focus, text) when is_binary(text) do
    normalized = normalize_text(text)

    cond do
      source_hint_person_question?(normalized) -> :source_hint_identity
      normalized == "" -> :empty_chat
      Regex.scan(~r/\S+/u, normalized) |> length() <= 8 -> :simple_answer
      true -> :general_chat
    end
  end

  defp task_class_for(tier, _focus, _text), do: tier

  defp route_reason_for(_tier, :linked_item_context, _text), do: "reply_to_linked_item_context"

  defp route_reason_for(_tier, :source_hint_identity, _text),
    do: "bounded_source_hint_identity_chat"

  defp route_reason_for(_tier, :connector_status, _text), do: "connector_status_focus"
  defp route_reason_for(_tier, :today_mode, _text), do: "today_mode_or_attention_request"
  defp route_reason_for(_tier, :meeting_prep, _text), do: "meeting_prep_requires_context"
  defp route_reason_for(_tier, :person_context, _text), do: "person_or_contact_context"
  defp route_reason_for(_tier, :waiting_on, _text), do: "waiting_on_or_commitment_analysis"
  defp route_reason_for(_tier, :quick_chat, _text), do: "quick_wording_request"

  defp route_reason_for(:reasoning, _focus, text) when is_binary(text) do
    normalized = normalize_text(text)

    cond do
      Enum.any?(@planning_patterns, &Regex.match?(&1, normalized)) ->
        "planning_source_or_open_loop_analysis"

      true ->
        "reasoning_pattern"
    end
  end

  defp route_reason_for(:chat, _focus, text) when is_binary(text) do
    normalized = normalize_text(text)

    cond do
      source_hint_person_question?(normalized) -> "bounded_source_hint_identity_chat"
      true -> "default_fast_chat_tier"
    end
  end

  defp route_reason_for(tier, _focus, _text), do: "#{tier}_tier"

  defp route_label(value) when is_atom(value), do: Atom.to_string(value)
  defp route_label(value) when is_binary(value), do: value
  defp route_label(_value), do: "chat"

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

  defp reasoning_wall_clock_ms do
    config()
    |> Keyword.get(:reasoning_wall_clock_ms, @default_reasoning_wall_clock_ms)
    |> positive_integer(@default_reasoning_wall_clock_ms)
  end

  defp reasoning_llm_turns do
    config()
    |> Keyword.get(:reasoning_llm_turns, @default_reasoning_llm_turns)
    |> positive_integer(@default_reasoning_llm_turns)
  end

  defp reasoning_tool_steps do
    config()
    |> Keyword.get(:reasoning_tool_steps, @default_reasoning_tool_steps)
    |> positive_integer(@default_reasoning_tool_steps)
  end

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

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_integer(value), do: true
  defp present?(_value), do: false

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
