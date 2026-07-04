defmodule Maraithon.ChiefOfStaff.Skills.LocalPatternReview do
  @moduledoc """
  Model relevance gate for heuristic proactive-nudge candidates.

  SPEC 04 R5: `Maraithon.Proactive.LocalPatterns`' six detectors (cold
  thread, dropped commitment, untranscribed memo, note follow-up, calendar
  conflict, file mention) are keyword/token-overlap heuristics, not a model
  decision — they record `status: "candidate"` insights instead of
  directly-deliverable ones (GOALS Principle 3: the app must not rely on
  keyword heuristics for relevance). SPEC 03 adds a second candidate
  producer to the same wakeup: `Maraithon.Crm.RelationshipDrift` turns the
  CRM's overdue-cadence / gone-quiet reconnect signals into
  relationship-drift observations. This skill is the only path that turns
  any candidate into a user-facing insight: on every Chief of Staff wakeup
  it runs both gatherers, looks for pending candidates and, only when there
  are any, asks the model which are worth surfacing right now. Approved
  candidates are promoted to `"new"` (and flow through the existing
  Insight -> InsightNotifications -> PushBroker/Telegram pipeline
  unchanged); the rest are dismissed.

  A quiet cycle with no pending candidates costs nothing (no model call).
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.Crm.RelationshipDrift
  alias Maraithon.Insights
  alias Maraithon.Insights.Insight
  alias Maraithon.Proactive.LocalPatterns
  alias Maraithon.Tracing

  require Logger

  @default_candidate_limit 10
  @default_llm_max_tokens 1_000
  @default_llm_reasoning_effort "low"

  @impl true
  def id, do: "local_pattern_review"

  @impl true
  def label, do: "Local pattern review"

  @impl true
  def description do
    "Reviews heuristic pattern candidates (cold threads, dropped commitments, relationship drift, ...) and decides which are worth surfacing."
  end

  @impl true
  def default_config do
    %{
      "assistant_behavior" => "ai_chief_of_staff",
      "candidate_limit" => @default_candidate_limit,
      "llm_max_tokens" => @default_llm_max_tokens,
      "llm_reasoning_effort" => @default_llm_reasoning_effort
    }
  end

  @impl true
  def requirements, do: []

  @impl true
  def subscriptions(_config, _user_id), do: []

  @impl true
  def interested_in?(_config, context) do
    case get_in(context, [:trigger, :type]) do
      :message -> false
      :pubsub_event -> false
      _ -> true
    end
  end

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      candidate_limit: integer_in_range(config["candidate_limit"], @default_candidate_limit, 1, 50),
      llm_model: normalize_string(config["llm_model"]),
      llm_max_tokens:
        integer_in_range(config["llm_max_tokens"], @default_llm_max_tokens, 256, 4_000),
      llm_reasoning_effort:
        normalize_reasoning_effort(config["llm_reasoning_effort"], @default_llm_reasoning_effort),
      pending_candidates: []
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    state = %{state | user_id: user_id}
    now = context[:timestamp] || DateTime.utc_now()

    cond do
      is_nil(user_id) ->
        {:idle, state}

      true ->
        # Gather this cycle's candidates (cheap pattern matching, no model
        # spend) as part of the same CoS wakeup that reviews them — R6
        # (SPEC 04): LocalPatterns has no separate detection cadence anymore.
        _ = local_patterns_module().run_for_user(user_id, now: now)
        # SPEC 03 R7: relationship-drift candidates ride the same batched
        # review — list_candidates_for_user/2 picks up every "candidate"
        # insight regardless of producer, so no second model call is needed.
        _ = relationship_drift_module().run_for_user(user_id, now: now)

        candidates = Insights.list_candidates_for_user(user_id, limit: state.candidate_limit)

        if candidates == [] do
          # Nothing to review — no model spend on a quiet cycle.
          {:idle, state}
        else
          pending_state = %{state | pending_candidates: candidates}

          case llm_params(candidates, state, context) do
            {:ok, params} ->
              {:effect, {:llm_call, params}, pending_state}

            {:error, reason} ->
              handle_effect_result(
                {:llm_call, %{content: "", error: inspect(reason), finish_reason: "error"}},
                pending_state,
                context
              )
          end
        end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    Tracing.with_span(
      "chief_of_staff.local_pattern_review",
      %{skill: "local_pattern_review", user_id: context[:user_id] || state.user_id},
      fn -> apply_review(response, state, context) end
    )
  end

  def handle_effect_result(_effect_result, state, _context),
    do: {:idle, %{state | pending_candidates: []}}

  @impl true
  def handle_effect_error(:llm_call, reason, state, context) do
    handle_effect_result(
      {:llm_call, %{content: "", error: inspect(reason), finish_reason: "error"}},
      state,
      context
    )
  end

  def handle_effect_error(_effect_type, _reason, state, _context),
    do: {:idle, %{state | pending_candidates: []}}

  @impl true
  def next_wakeup(_state), do: :none

  # ==========================================================================
  # Model call + review
  # ==========================================================================

  defp llm_params(candidates, state, context) do
    with {:ok, input_json} <- Jason.encode(candidates_for_prompt(candidates)) do
      params =
        %{
          "messages" => [%{"role" => "user", "content" => review_prompt(input_json, context)}],
          "max_tokens" => state.llm_max_tokens,
          "temperature" => 0.1,
          "reasoning_effort" => state.llm_reasoning_effort
        }
        |> maybe_put("model", state.llm_model)

      {:ok, params}
    end
  end

  defp candidates_for_prompt(candidates) do
    Enum.map(candidates, fn %Insight{} = insight ->
      %{
        "id" => insight.id,
        "detector" => get_in(insight.metadata || %{}, ["detector"]),
        "title" => insight.title,
        "summary" => insight.summary,
        "recommended_action" => insight.recommended_action,
        "category" => insight.category,
        "priority" => insight.priority
      }
    end)
  end

  defp review_prompt(input_json, context) do
    """
    You are the operator's chief of staff. Heuristic detectors flagged the
    candidate signals below (cold threads, dropped commitments,
    untranscribed memos, note follow-ups, calendar conflicts, file mentions,
    and relationship-drift observations — important relationships whose
    usual contact cadence has lapsed or that are going quiet). Detectors are
    dumb pattern matches, not judgment — decide which candidates are
    actually worth interrupting the operator about right now, and which are
    noise, stale, or not worth a Telegram nudge.

    #{previous_cycle_memo_section(context)}#{previous_decision_ledger_section(context)}Return ONLY valid JSON with this exact shape:
    {
      "decisions": [
        {"id": "<candidate id>", "decision": "keep" | "discard", "reason": "short reason"}
      ]
    }

    Include a decision for every candidate id in the input. Candidates:
    #{input_json}
    """
  end

  defp apply_review(response, state, _context) do
    candidates = state.pending_candidates
    cleared_state = %{state | pending_candidates: []}

    case parse_decisions(response) do
      {:ok, decisions} ->
        {approved_count, categories, ledger_entries} =
          apply_decisions(state.user_id, candidates, decisions)

        # R7 (SPEC 07): discard decisions are the reference producer for the
        # cross-cycle decision ledger — the model's own reason string would
        # otherwise be thrown away the moment Insights.dismiss/2 returns.
        # "keep" decisions need no entry: promotion to a durable Insight row
        # is stronger state than the ledger. Emit whenever there is anything
        # to carry (an approval or a ledger entry).
        if approved_count > 0 or ledger_entries != [] do
          payload =
            %{count: approved_count, user_id: state.user_id, categories: categories}
            |> maybe_put_ledger_entries(ledger_entries)

          {:emit, {:insights_recorded, payload}, cleared_state}
        else
          {:idle, cleared_state}
        end

      {:error, reason} ->
        _ = Tracing.record_error("local_pattern_review: " <> String.slice(reason, 0, 200))
        Logger.warning("Local pattern review model synthesis failed", reason: reason)
        # Leave candidates as-is; the next cycle will retry the review.
        {:idle, cleared_state}
    end
  end

  defp apply_decisions(user_id, candidates, decisions) do
    Enum.reduce(candidates, {0, [], []}, fn %Insight{} = insight,
                                            {count, categories, ledger_entries} ->
      case decision_for(decisions, insight.id) do
        "keep" ->
          case Insights.approve_candidate(user_id, insight.id) do
            {:ok, _updated} -> {count + 1, [insight.category | categories], ledger_entries}
            {:error, _reason} -> {count, categories, ledger_entries}
          end

        _discard_or_missing ->
          _ = Insights.dismiss(user_id, insight.id)

          entry = %{
            "item_id" => to_string(insight.id),
            "item_type" => "insight",
            "decision" => "suppressed",
            "reason" => discard_reason(decisions, insight.id)
          }

          {count, categories, [entry | ledger_entries]}
      end
    end)
    |> then(fn {count, categories, ledger_entries} ->
      {count, Enum.uniq(categories), Enum.reverse(ledger_entries)}
    end)
  end

  defp decision_for(decisions, insight_id) do
    Enum.find_value(decisions, fn decision ->
      if to_string(Map.get(decision, "id")) == to_string(insight_id) do
        Map.get(decision, "decision")
      end
    end)
  end

  defp discard_reason(decisions, insight_id) do
    reason =
      Enum.find_value(decisions, fn decision ->
        if to_string(Map.get(decision, "id")) == to_string(insight_id) do
          Map.get(decision, "reason")
        end
      end)

    case reason do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> "discarded"
          trimmed -> trimmed
        end

      _ ->
        "discarded"
    end
  end

  defp maybe_put_ledger_entries(payload, []), do: payload

  defp maybe_put_ledger_entries(payload, ledger_entries),
    do: Map.put(payload, "ledger_entries", ledger_entries)

  defp parse_decisions(response) do
    error =
      case response do
        %{error: error} -> error
        %{"error" => error} -> error
        _ -> nil
      end

    content =
      case response do
        %{content: content} when is_binary(content) -> content
        %{"content" => content} when is_binary(content) -> content
        content when is_binary(content) -> content
        _ -> nil
      end

    cond do
      error ->
        {:error, to_string(error)}

      is_binary(content) and content != "" ->
        case decode_json(content) do
          {:ok, %{"decisions" => decisions}} when is_list(decisions) ->
            {:ok, decisions}

          _ ->
            {:error, "model_response_invalid_or_missing_decisions"}
        end

      true ->
        {:error, "model_response_empty"}
    end
  end

  defp decode_json(content) when is_binary(content) do
    trimmed = String.trim(content)

    candidates =
      [trimmed, strip_markdown_json_fence(trimmed)]
      |> Enum.uniq()

    Enum.reduce_while(candidates, {:error, :no_json_candidate}, fn candidate, _error ->
      case Jason.decode(candidate) do
        {:ok, decoded} -> {:halt, {:ok, decoded}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp strip_markdown_json_fence(content) when is_binary(content) do
    case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, content, capture: :all_but_first) do
      [json] -> String.trim(json)
      _ -> content
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  # R3 (SPEC 04): render the model's own cross-cycle memo (persisted in
  # behavior_state, injected via skill_context/4) as a clearly-labeled prompt
  # section so keep/discard decisions reason over what the last cycle already
  # decided instead of the memo only existing to seed the next memo.
  defp previous_cycle_memo_section(context) do
    memo = context[:previous_cycle_memo]

    if is_binary(memo) and String.trim(memo) != "" do
      """
      PREVIOUS CYCLE MEMO#{memo_meta_suffix(context)}:
      #{String.trim(memo)}

      """
    else
      ""
    end
  end

  # R8 (SPEC 07): render prior cross-cycle ledger decisions on insights so
  # the model sees "discarded 2 cycles ago as noise" before re-deciding a
  # recurring detector hit. Mirrors previous_cycle_memo_section/1.
  defp previous_decision_ledger_section(context) do
    entries =
      context[:previous_decision_ledger]
      |> List.wrap()
      |> Enum.filter(fn entry ->
        is_map(entry) and Map.get(entry, "item_type") == "insight"
      end)

    if entries == [] do
      ""
    else
      lines =
        Enum.map(entries, fn entry ->
          decision = Map.get(entry, "decision") || "held"
          reason = Map.get(entry, "reason") || ""
          suffix = ledger_entry_suffix(entry)
          "- #{decision}#{suffix}: #{reason}"
        end)

      """
      PREVIOUS DECISIONS ON PATTERN CANDIDATES (cross-cycle decision ledger):
      #{Enum.join(lines, "\n")}

      """
    end
  end

  defp ledger_entry_suffix(entry) do
    case normalize_string(Map.get(entry, "updated_at")) do
      nil -> ""
      updated_at -> " (as of #{updated_at})"
    end
  end

  defp memo_meta_suffix(context) do
    parts =
      [{"cycle", context[:previous_cycle_memo_cycle_id]},
       {"at", context[:previous_cycle_memo_updated_at]}]
      |> Enum.reject(fn {_label, value} -> normalize_string(value) == nil end)
      |> Enum.map(fn {label, value} -> "#{label} #{value}" end)

    case parts do
      [] -> ""
      parts -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end

  defp normalize_reasoning_effort(value, default) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in ~w(low medium high xhigh), do: normalized, else: default
  end

  defp normalize_reasoning_effort(_value, default), do: default

  defp integer_in_range(value, default, min, max) do
    parsed =
      cond do
        is_integer(value) -> value
        is_binary(value) -> parse_integer(value, default)
        true -> default
      end

    parsed |> max(min) |> min(max)
  end

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp local_patterns_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:local_patterns_module, LocalPatterns)
  end

  defp relationship_drift_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:relationship_drift_module, RelationshipDrift)
  end
end
