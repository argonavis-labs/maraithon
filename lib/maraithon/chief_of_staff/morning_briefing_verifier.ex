defmodule Maraithon.ChiefOfStaff.MorningBriefingVerifier do
  @moduledoc """
  Production-safe diagnostics for the morning briefing generation loop.

  This does not call an LLM. It checks the currently configured Chief of Staff
  agents, their effective morning briefing LLM budget, and recent persisted
  morning brief failures so a rate-limit screenshot can be tied back to code
  and database state without guessing.
  """

  import Ecto.Query

  alias Maraithon.Agents.Agent
  alias Maraithon.Briefs.Brief
  alias Maraithon.ChiefOfStaff.Skills.MorningBriefing
  alias Maraithon.Effects.Effect
  alias Maraithon.LLM
  alias Maraithon.Repo
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  @default_recent_limit 5
  @effect_recent_limit 10
  @effect_recent_window_hours 2
  @safe_max_tokens 16_000
  @chief_behaviors ["ai_chief_of_staff", "manifest_agent"]
  @shared_config_keys [
    "source_policy",
    "source_scope",
    "timezone_offset_hours",
    "morning_brief_hour_local",
    "morning_brief_minute_local"
  ]

  @doc """
  Returns a JSON-friendly report for current morning briefing readiness.
  """
  def verify(opts \\ []) when is_list(opts) do
    recent_limit = positive_integer(Keyword.get(opts, :recent_limit), @default_recent_limit)
    runtime = runtime_report()

    agent_records = list_agents(opts)

    agents =
      agent_records
      |> Enum.map(&agent_report(&1, recent_limit))

    effect_queue = effect_queue_report(agent_records)

    issues =
      runtime_issues(runtime) ++
        effect_queue["issues"] ++
        Enum.flat_map(agents, & &1["issues"])

    %{
      "status" => if(issues == [], do: "ok", else: "attention_required"),
      "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "runtime" => runtime,
      "effect_queue" => effect_queue,
      "agents" => agents,
      "issues" => issues
    }
  end

  defp list_agents(opts) do
    Agent
    |> where([a], a.behavior in ^@chief_behaviors)
    |> where([a], a.status in ["running", "degraded"])
    |> maybe_filter(:id, Keyword.get(opts, :agent_id))
    |> maybe_filter(:user_id, Keyword.get(opts, :user_id))
    |> order_by([a], asc: a.inserted_at)
    |> Repo.all()
  end

  defp effect_queue_report([]) do
    %{
      "llm_rate_limiter" => LLMRateLimiter.status(),
      "active_status_counts" => %{},
      "recent_noncompleted_llm_effects" => [],
      "issues" => []
    }
  end

  defp effect_queue_report(agents) do
    agent_ids = Enum.map(agents, & &1.id)
    cutoff = DateTime.add(DateTime.utc_now(), -@effect_recent_window_hours, :hour)
    active_counts = active_llm_effect_counts(agent_ids)

    recent_noncompleted =
      Effect
      |> where([e], e.agent_id in ^agent_ids)
      |> where([e], e.effect_type == "llm_call")
      |> where([e], e.inserted_at >= ^cutoff)
      |> where([e], e.status not in ["completed", "cancelled"])
      |> order_by([e], desc: e.updated_at)
      |> limit(^@effect_recent_limit)
      |> Repo.all()

    issues = effect_queue_issues(active_counts, recent_noncompleted)

    %{
      "llm_rate_limiter" => LLMRateLimiter.status(),
      "active_status_counts" => active_counts,
      "recent_noncompleted_llm_effects" => Enum.map(recent_noncompleted, &effect_summary/1),
      "issues" => issues
    }
  end

  defp active_llm_effect_counts(agent_ids) do
    Effect
    |> where([e], e.agent_id in ^agent_ids)
    |> where([e], e.effect_type == "llm_call")
    |> where([e], e.status in ["pending", "claimed", "failed"])
    |> group_by([e], e.status)
    |> select([e], {e.status, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp effect_queue_issues(active_counts, recent_noncompleted) do
    active_total =
      active_counts
      |> Map.take(["pending", "claimed"])
      |> Map.values()
      |> Enum.sum()

    recent_rate_limits? =
      Enum.any?(recent_noncompleted, fn effect ->
        effect.error && String.contains?(effect.error, "rate_limited")
      end)

    []
    |> maybe_add_issue(active_total > 10, %{
      "code" => "llm_effect_queue_backlog",
      "severity" => "high",
      "message" => "#{active_total} active LLM effect(s) are pending or claimed."
    })
    |> maybe_add_issue(recent_rate_limits?, %{
      "code" => "recent_llm_rate_limits",
      "severity" => "high",
      "message" => "Recent non-completed Chief of Staff LLM effects include provider rate limits."
    })
  end

  defp effect_summary(%Effect{} = effect) do
    %{
      "id" => effect.id,
      "agent_id" => effect.agent_id,
      "status" => effect.status,
      "attempts" => effect.attempts,
      "max_attempts" => effect.max_attempts,
      "inserted_at" => effect.inserted_at && DateTime.to_iso8601(effect.inserted_at),
      "updated_at" => effect.updated_at && DateTime.to_iso8601(effect.updated_at),
      "retry_after" => effect.retry_after && DateTime.to_iso8601(effect.retry_after),
      "error" => effect.error
    }
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, :id, id), do: where(query, [a], a.id == ^id)
  defp maybe_filter(query, :user_id, user_id), do: where(query, [a], a.user_id == ^user_id)

  defp agent_report(%Agent{} = agent, recent_limit) do
    config = agent.config || %{}
    skill_config = get_in(config, ["skill_configs", "morning_briefing"]) || %{}
    effective_config = effective_skill_config(agent, config, skill_config)
    state = MorningBriefing.init(effective_config)
    recent_briefs = recent_morning_briefs(agent.id, recent_limit)

    config_issues = config_issues(agent, skill_config, state)
    failure_issues = failure_issues(agent, recent_briefs)
    issues = config_issues ++ failure_issues

    %{
      "agent_id" => agent.id,
      "user_id" => agent.user_id,
      "behavior" => agent.behavior,
      "source_behavior" => Map.get(config, "source_behavior"),
      "status" => agent.status,
      "raw_morning_briefing_config" => %{
        "llm_model" => Map.get(skill_config, "llm_model"),
        "llm_max_tokens" => Map.get(skill_config, "llm_max_tokens"),
        "llm_reasoning_effort" => Map.get(skill_config, "llm_reasoning_effort")
      },
      "effective_request" => %{
        "llm_model" => state.llm_model || LLM.model() || "unknown",
        "llm_max_tokens" => state.llm_max_tokens,
        "llm_reasoning_effort" => state.llm_reasoning_effort,
        "llm_timeout_ms" => state.llm_timeout_ms
      },
      "recent_morning_briefs" => Enum.map(recent_briefs, &brief_summary/1),
      "issues" => issues
    }
  end

  defp effective_skill_config(agent, config, skill_config) do
    MorningBriefing.default_config()
    |> Map.merge(Map.take(config, @shared_config_keys))
    |> Map.merge(skill_config)
    |> Map.put("user_id", agent.user_id || Map.get(config, "user_id"))
  end

  defp config_issues(agent, skill_config, state) do
    []
    |> maybe_add_issue(oversized_raw_budget?(skill_config), %{
      "code" => "morning_briefing_oversized_raw_budget",
      "severity" => "high",
      "agent_id" => agent.id,
      "message" => "Nested morning_briefing llm_max_tokens is above #{@safe_max_tokens}."
    })
    |> maybe_add_issue(raw_xhigh_reasoning?(skill_config), %{
      "code" => "morning_briefing_xhigh_raw_reasoning",
      "severity" => "high",
      "agent_id" => agent.id,
      "message" => "Nested morning_briefing llm_reasoning_effort is xhigh."
    })
    |> maybe_add_issue(state.llm_reasoning_effort == "xhigh", %{
      "code" => "morning_briefing_xhigh_effective_reasoning",
      "severity" => "critical",
      "agent_id" => agent.id,
      "message" => "Effective morning brief request would use xhigh reasoning."
    })
  end

  defp oversized_raw_budget?(skill_config) do
    case integer_value(Map.get(skill_config, "llm_max_tokens")) do
      value when is_integer(value) -> value > @safe_max_tokens
      _other -> false
    end
  end

  defp raw_xhigh_reasoning?(skill_config) do
    case Map.get(skill_config, "llm_reasoning_effort") do
      value when is_binary(value) -> String.downcase(String.trim(value)) == "xhigh"
      _other -> false
    end
  end

  defp failure_issues(agent, briefs) do
    failures = Enum.filter(briefs, &generation_failure?/1)

    case failures do
      [] ->
        []

      failures ->
        [
          %{
            "code" => "recent_morning_briefing_generation_failures",
            "severity" => "high",
            "agent_id" => agent.id,
            "message" => "#{length(failures)} recent morning brief generation failure(s) found.",
            "latest_failure_at" =>
              failures
              |> List.first()
              |> brief_time()
          }
        ]
    end
  end

  defp generation_failure?(%Brief{} = brief) do
    brief.title == "Morning briefing generation failed" or
      get_in(brief.metadata || %{}, ["generation_mode"]) == "error"
  end

  defp runtime_report do
    model = LLM.model()
    chat_model = LLM.chat_model()
    routing_model = LLM.routing_model()
    model_fallbacks = configured_model_fallbacks()

    %{
      "provider" => LLM.provider_name(),
      "model" => model,
      "chat_model" => chat_model,
      "routing_model" => routing_model,
      "model_fallbacks" => model_fallbacks,
      "openai_reasoning_effort" => LLM.openai_reasoning_effort()
    }
  end

  defp runtime_issues(%{"provider" => provider}) when provider in ["mock", "unconfigured"], do: []

  defp runtime_issues(%{"model" => model, "chat_model" => chat_model, "routing_model" => routing}) do
    fallback_available? =
      [chat_model, routing | configured_model_fallbacks()]
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.any?(&(&1 != normalize_string(model)))

    maybe_add_issue([], not fallback_available?, %{
      "code" => "llm_no_distinct_fallback_model",
      "severity" => "medium",
      "message" => "No distinct LLM fallback model is configured."
    })
  end

  defp recent_morning_briefs(agent_id, limit) do
    Brief
    |> where([b], b.agent_id == ^agent_id and b.cadence == "morning")
    |> order_by([b], desc: b.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp brief_summary(%Brief{} = brief) do
    %{
      "id" => brief.id,
      "status" => brief.status,
      "title" => brief.title,
      "inserted_at" => brief.inserted_at && DateTime.to_iso8601(brief.inserted_at),
      "scheduled_for" => brief.scheduled_for && DateTime.to_iso8601(brief.scheduled_for),
      "generation_mode" => get_in(brief.metadata || %{}, ["generation_mode"]),
      "llm_finish_reason" => get_in(brief.metadata || %{}, ["llm_finish_reason"]),
      "error_message" => brief.error_message || get_in(brief.metadata || %{}, ["error_message"])
    }
  end

  defp brief_time(nil), do: nil
  defp brief_time(%Brief{inserted_at: nil}), do: nil
  defp brief_time(%Brief{inserted_at: inserted_at}), do: DateTime.to_iso8601(inserted_at)

  defp configured_model_fallbacks do
    :maraithon
    |> Application.get_env(Maraithon.Runtime, [])
    |> Keyword.get(:llm_model_fallbacks, [])
    |> normalize_string_list()
  end

  defp maybe_add_issue(issues, true, issue), do: [issue | issues]
  defp maybe_add_issue(issues, false, _issue), do: issues

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_string_list()
  end

  defp normalize_string_list(_value), do: []

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil
end
