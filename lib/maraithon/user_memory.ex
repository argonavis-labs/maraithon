defmodule Maraithon.UserMemory do
  @moduledoc """
  Durable cross-agent user memory built from preferences, feedback, projects, and conversation history.
  """

  import Ecto.Query

  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.LLM
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory
  alias Maraithon.Projects
  alias Maraithon.Repo
  alias Maraithon.TelegramConversations.Turn
  alias Maraithon.UserMemory.Profile

  @profile_fields ~w(
    working_style
    communication_style
    decision_style
    current_focus
    important_context
  )
  @default_window_days 30
  @default_max_age_seconds 15 * 60
  @default_confidence 0.55
  @recent_feedback_limit 8
  @recent_turn_limit 16

  def prompt_context(user_id) when is_binary(user_id) do
    case Repo.get_by(Profile, user_id: user_id) do
      %Profile{} = profile ->
        serialize_profile(profile)

      nil ->
        fallback_prompt_context(user_id)
    end
  end

  def prompt_context(_user_id), do: empty_prompt_context()

  def refresh_if_stale(user_id, opts \\ [])

  def refresh_if_stale(user_id, opts) when is_binary(user_id) do
    max_age_seconds = Keyword.get(opts, :max_age_seconds, @default_max_age_seconds)
    force? = Keyword.get(opts, :force, false)
    profile = Repo.get_by(Profile, user_id: user_id)

    cond do
      force? ->
        refresh_profile(user_id, opts)

      is_nil(profile) ->
        refresh_profile(user_id, opts)

      stale_profile?(profile, max_age_seconds) ->
        refresh_profile(user_id, opts)

      true ->
        {:ok, serialize_profile(profile)}
    end
  end

  def refresh_if_stale(_user_id, _opts), do: {:error, :invalid_user}

  def refresh_profile(user_id, opts \\ [])

  def refresh_profile(user_id, opts) when is_binary(user_id) do
    llm_complete = Keyword.get(opts, :llm_complete) || configured_llm_complete()
    bundle = source_bundle(user_id)
    now = DateTime.utc_now()

    {summary, profile_map, confidence} =
      case summarize(bundle, llm_complete) do
        {:ok, result} ->
          normalize_profile_result(result, bundle)

        {:error, _reason} ->
          fallback_profile(bundle)
      end

    attrs = %{
      user_id: user_id,
      summary: summary,
      profile: profile_map,
      source_window_start: DateTime.add(now, -@default_window_days * 24 * 60 * 60, :second),
      source_window_end: now,
      confidence: confidence
    }

    case upsert_profile(attrs) do
      {:ok, %Profile{} = profile} -> {:ok, serialize_profile(profile)}
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_profile(_user_id, _opts), do: {:error, :invalid_user}

  defp summarize(bundle, llm_complete) when is_function(llm_complete, 1) do
    prompt = """
    You are summarizing confirmed long-term user memory for Maraithon.

    Return ONLY valid JSON:
    {
      "summary":"...",
      "profile":{
        "working_style":"...",
        "communication_style":"...",
        "decision_style":"...",
        "current_focus":"...",
        "important_context":"..."
      },
      "confidence":0.0
    }

    Source bundle JSON:
    #{Jason.encode!(bundle)}

    Rules:
    - Produce a reusable cross-agent memory profile that future agents should inherit.
    - Focus on confirmed long-term patterns, not one-off moments.
    - Capture how this user prefers to work, communicate, prioritize, and be interrupted.
    - Use the current projects to ground `current_focus` when they are relevant.
    - Keep every field concise, instruction-friendly, and safe to hand to another LLM.
    - Do not invent facts. If the signals are thin, state which preference has not been confirmed yet and use source-grounded defaults.
    - `summary` should be a compact paragraph that explains how packaged agents should adapt to this user.
    """

    with {:ok, response} <- llm_complete.(prompt),
         {:ok, decoded} <- decode_json(response) do
      {:ok, decoded}
    else
      _ -> {:error, :summary_unavailable}
    end
  end

  defp source_bundle(user_id) do
    %{
      preference_memory: PreferenceMemory.prompt_context(user_id),
      operator_summaries: OperatorMemory.summaries_for_prompt(user_id),
      recent_feedback: recent_feedback(user_id),
      recent_conversation_turns: recent_conversation_turns(user_id),
      projects: Projects.summarize_for_prompt(user_id, 8),
      connected_accounts: connected_accounts(user_id),
      active_agents: active_agents(user_id)
    }
  end

  defp recent_feedback(user_id) do
    Delivery
    |> join(:inner, [delivery], insight in assoc(delivery, :insight))
    |> where([delivery, _insight], delivery.user_id == ^user_id and not is_nil(delivery.feedback))
    |> order_by([delivery, _insight], desc: delivery.feedback_at, desc: delivery.updated_at)
    |> limit(^@recent_feedback_limit)
    |> select([delivery, insight], %{
      feedback: delivery.feedback,
      feedback_at: delivery.feedback_at,
      category: insight.category,
      source: insight.source,
      title: insight.title,
      summary: insight.summary,
      recommended_action: insight.recommended_action
    })
    |> Repo.all()
  end

  defp recent_conversation_turns(user_id) do
    Turn
    |> join(:inner, [turn], conversation in assoc(turn, :conversation))
    |> where([turn, conversation], conversation.user_id == ^user_id)
    |> order_by([turn, _conversation], desc: turn.inserted_at)
    |> limit(^@recent_turn_limit)
    |> Repo.all()
    |> Enum.map(fn turn ->
      %{
        role: turn.role,
        text: turn.text,
        intent: turn.intent,
        confidence: turn.confidence,
        inserted_at: turn.inserted_at
      }
    end)
  end

  defp connected_accounts(user_id) do
    ConnectedAccounts.list_for_user(user_id)
    |> Enum.map(fn account ->
      %{
        provider: public_provider(account.provider),
        status: account.status
      }
    end)
  end

  defp public_provider("google:" <> _), do: "google"
  defp public_provider("slack:" <> _), do: "slack"
  defp public_provider(provider) when is_binary(provider), do: provider
  defp public_provider(nil), do: nil
  defp public_provider(provider), do: to_string(provider)

  defp active_agents(user_id) do
    Agents.list_agents(user_id: user_id)
    |> Enum.map(fn agent ->
      %{
        id: agent.id,
        behavior: agent.behavior,
        status: agent.status,
        name: get_in(agent.config || %{}, ["name"]) || agent.behavior,
        project_id: agent.project_id
      }
    end)
  end

  defp normalize_profile_result(result, bundle) when is_map(result) do
    profile =
      result
      |> Map.get("profile", %{})
      |> normalize_profile_map()

    fallback_summary =
      [
        Map.get(profile, "current_focus"),
        Map.get(profile, "working_style"),
        Map.get(profile, "communication_style")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> case do
        "" -> fallback_profile(bundle) |> elem(0)
        value -> value
      end

    summary =
      result
      |> Map.get("summary")
      |> normalize_optional_text()
      |> case do
        nil -> fallback_summary
        value -> value
      end

    confidence =
      result
      |> Map.get("confidence")
      |> normalize_confidence()
      |> case do
        nil -> 0.84
        value -> value
      end

    {summary, merge_missing_profile_fields(profile, bundle), confidence}
  end

  defp normalize_profile_result(_result, bundle), do: fallback_profile(bundle)

  defp fallback_prompt_context(user_id) when is_binary(user_id) do
    {summary, profile, confidence} =
      user_id
      |> source_bundle()
      |> fallback_profile()

    %{
      summary: summary,
      profile: profile,
      confidence: confidence,
      source_window_start: nil,
      source_window_end: nil,
      updated_at: nil
    }
  end

  defp fallback_profile(bundle) do
    working_style =
      operator_summary(bundle, ["action_style", "interrupt_policy"]) ||
        "Use concise, source-grounded recommendations until stronger preferences are confirmed."

    communication_style =
      operator_summary(bundle, ["telegram_behavior", "content_preferences"]) ||
        preference_instruction(bundle, ["style_preference", "routing_preference"]) ||
        "Keep updates concise, specific, and grounded in the user's current obligations."

    decision_style =
      preference_instruction(bundle, ["action_preference", "urgency_boost"]) ||
        "Bias toward practical next steps, explicit tradeoffs, and concrete recommendations."

    current_focus =
      case Map.get(bundle, :projects, []) do
        [] ->
          "Prioritize source-backed obligations until a project focus is confirmed."

        projects ->
          project_names =
            projects
            |> Enum.map(&(Map.get(&1, :name) || Map.get(&1, "name")))
            |> Enum.reject(&blank?/1)
            |> Enum.take(4)

          "Current project focus: #{Enum.join(project_names, ", ")}."
      end

    important_context =
      [
        connected_account_summary(bundle),
        recent_feedback_summary(bundle)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> case do
        "" ->
          "Use connected-source evidence and confirmed preferences before assuming additional context."

        value ->
          value
      end

    profile = %{
      "working_style" => working_style,
      "communication_style" => communication_style,
      "decision_style" => decision_style,
      "current_focus" => current_focus,
      "important_context" => important_context
    }

    summary =
      [
        current_focus,
        working_style,
        communication_style
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")

    {summary, profile, @default_confidence}
  end

  defp operator_summary(bundle, summary_types) when is_map(bundle) and is_list(summary_types) do
    bundle
    |> Map.get(:operator_summaries, [])
    |> Enum.filter(&Enum.member?(summary_types, Map.get(&1, :type) || Map.get(&1, "type")))
    |> Enum.map(&(Map.get(&1, :content) || Map.get(&1, "content")))
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
    |> normalize_optional_text()
  end

  defp preference_instruction(bundle, kinds) when is_map(bundle) and is_list(kinds) do
    bundle
    |> get_in([:preference_memory, :rules]) ||
      []
      |> Enum.filter(&Enum.member?(kinds, Map.get(&1, "kind")))
      |> Enum.map(&Map.get(&1, "instruction"))
      |> Enum.reject(&blank?/1)
      |> Enum.take(3)
      |> Enum.join(" ")
      |> normalize_optional_text()
  end

  defp connected_account_summary(bundle) do
    bundle
    |> Map.get(:connected_accounts, [])
    |> Enum.filter(fn account -> Map.get(account, :status) == "connected" end)
    |> Enum.map(&(Map.get(&1, :provider) || Map.get(&1, "provider")))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      providers -> "Connected systems in regular use: #{Enum.join(providers, ", ")}."
    end
  end

  defp recent_feedback_summary(bundle) do
    bundle
    |> Map.get(:recent_feedback, [])
    |> Enum.take(3)
    |> Enum.map(fn feedback ->
      title = Map.get(feedback, :title) || Map.get(feedback, "title")
      feedback_value = Map.get(feedback, :feedback) || Map.get(feedback, "feedback")

      case {normalize_optional_text(title), normalize_optional_text(feedback_value)} do
        {nil, _} -> nil
        {_, nil} -> nil
        {title, feedback_value} -> "#{feedback_value} on #{title}"
      end
    end)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      entries -> "Recent feedback signals: #{Enum.join(entries, "; ")}."
    end
  end

  defp merge_missing_profile_fields(profile, bundle) do
    {_summary, fallback_profile, _confidence} = fallback_profile(bundle)

    Enum.reduce(@profile_fields, profile, fn field, acc ->
      case normalize_optional_text(Map.get(acc, field)) do
        nil -> Map.put(acc, field, Map.get(fallback_profile, field))
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp normalize_profile_map(value) when is_map(value) do
    Enum.reduce(@profile_fields, %{}, fn field, acc ->
      case Map.get(value, field) || profile_field_value(value, field) do
        text when is_binary(text) ->
          case normalize_optional_text(text) do
            nil -> acc
            normalized -> Map.put(acc, field, normalized)
          end

        _ ->
          acc
      end
    end)
  end

  defp normalize_profile_map(_value), do: %{}

  defp profile_field_value(value, "working_style"), do: Map.get(value, :working_style)
  defp profile_field_value(value, "communication_style"), do: Map.get(value, :communication_style)
  defp profile_field_value(value, "decision_style"), do: Map.get(value, :decision_style)
  defp profile_field_value(value, "current_focus"), do: Map.get(value, :current_focus)
  defp profile_field_value(value, "important_context"), do: Map.get(value, :important_context)
  defp profile_field_value(_value, _field), do: nil

  defp upsert_profile(attrs) do
    case Repo.get_by(Profile, user_id: Map.fetch!(attrs, :user_id)) do
      nil ->
        %Profile{}
        |> Profile.changeset(attrs)
        |> Repo.insert()

      %Profile{} = profile ->
        profile
        |> Profile.changeset(attrs)
        |> Repo.update()
    end
  end

  defp serialize_profile(%Profile{} = profile) do
    %{
      summary: profile.summary,
      profile: normalize_profile_map(profile.profile || %{}),
      confidence: profile.confidence || 0.0,
      source_window_start: profile.source_window_start,
      source_window_end: profile.source_window_end,
      updated_at: profile.updated_at
    }
  end

  defp stale_profile?(%Profile{} = profile, max_age_seconds) do
    reference_time = profile.updated_at || profile.inserted_at || DateTime.utc_now()
    DateTime.diff(DateTime.utc_now(), reference_time, :second) >= max_age_seconds
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
      {:ok, %{} = parsed} -> {:ok, parsed}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_json(_), do: {:error, :invalid_json}

  defp configured_llm_complete do
    config = Application.get_env(:maraithon, :user_memory, [])

    case Keyword.get(config, :llm_complete) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        &default_llm_complete/1
    end
  end

  defp default_llm_complete(prompt) when is_binary(prompt) do
    params = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => 1_200,
      "temperature" => 0.2,
      "reasoning_effort" => "medium"
    }

    with {:ok, response} <- LLM.complete(params) do
      {:ok, response.content}
    end
  end

  defp normalize_confidence(value) when is_float(value), do: min(max(value, 0.0), 1.0)
  defp normalize_confidence(value) when is_integer(value), do: normalize_confidence(value / 1)

  defp normalize_confidence(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> normalize_confidence(parsed)
      _ -> nil
    end
  end

  defp normalize_confidence(_value), do: nil

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_text(_value), do: nil

  defp blank?(value), do: is_nil(normalize_optional_text(value))

  defp empty_prompt_context do
    %{
      summary: "No confirmed long-term user profile yet.",
      profile: %{},
      confidence: 0.0,
      source_window_start: nil,
      source_window_end: nil,
      updated_at: nil
    }
  end
end
