defmodule Maraithon.Todos.Intelligence do
  @moduledoc """
  Model-backed ingestion for durable work item candidates.

  This module is the write boundary for assistant-created work items. It gives the
  model both candidate work and existing saved work, then applies only explicit
  create/update/skip decisions returned by the model.
  """

  alias Maraithon.{Crm, LLM, Memory}
  alias Maraithon.Todos
  alias Maraithon.Todos.{SignalGate, SurfaceQuality, UserFacingCopy}
  alias Maraithon.Todos.Todo

  @sentinel "TODO_INTELLIGENCE_JSON_V1"
  @persist_actions ~w(create update)
  @valid_actions ["create", "update", "skip"]
  @required_todo_fields ~w(source title summary next_action dedupe_key)
  @default_max_tokens 64_000
  @default_timeout_ms 1_200_000
  @family_guard_policies ~w(family_logistics_only quiet_relationship_support)
  @family_opt_in_policies ~w(opt_in_rhythm)
  @family_relationship_phrases [
    "check in with",
    "catch up with",
    "reach out to",
    "touch base",
    "reconnect with",
    "send a note to",
    "no recent contact",
    "not heard from",
    "haven't heard from",
    "has been quiet",
    "went quiet",
    "gone quiet",
    "relationship drift",
    "relationship maintenance"
  ]
  @family_logistics_terms ~w(
    appointment book calendar cancel carpool deadline dentist doctor dropoff due flight form
    medication medicine pack paperwork pay permission pickup practice registration reschedule
    return rsvp sign submit teacher travel tuition worksheet
  )
  @family_logistics_phrases [
    "drop off",
    "pick up",
    "permission form",
    "school form",
    "parent teacher",
    "parent-teacher",
    "proxy pickup",
    "pickup change",
    "direct ask",
    "asked you",
    "can you",
    "could you",
    "please"
  ]
  @family_user_requested_phrases [
    "remind me",
    "i want to",
    "help me remember",
    "set a reminder"
  ]

  def sentinel, do: @sentinel

  def ingest_many(user_id, candidates, opts \\ [])

  def ingest_many(user_id, candidates, opts)
      when is_binary(user_id) and is_list(candidates) and is_list(opts) do
    candidates =
      candidates
      |> Enum.filter(&is_map/1)
      |> Enum.map(&stringify_top_level_keys/1)

    if candidates == [] do
      {:ok, %{todos: [], skipped: [], skipped_count: 0, decisions: [], summary: nil}}
    else
      existing =
        Todos.list_recent_for_user(user_id, limit: Keyword.get(opts, :existing_limit, 80))

      with {:ok, prompt} <- build_prompt(user_id, candidates, existing, opts),
           llm_complete when is_function(llm_complete, 1) <- llm_complete(opts),
           {:ok, response} <- llm_complete.(prompt),
           {:ok, decoded} <- decode_response(response),
           {:ok, decisions, summary} <- normalize_response(decoded, candidates, existing, opts),
           {:ok, result} <- apply_decisions(user_id, decisions, summary) do
        {:ok, Map.put(result, :usage, response_usage(response))}
      else
        {:error, reason} -> {:error, reason}
        _other -> {:error, :todo_intelligence_failed}
      end
    end
  end

  def ingest_many(_user_id, _candidates, _opts), do: {:error, :invalid_todo_candidates}

  defp build_prompt(user_id, candidates, existing, opts) do
    source = Keyword.get(opts, :source, "todo_intelligence")
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> normalize_json_value()

    payload = %{
      "user_id" => user_id,
      "source" => source,
      "generated_at" => now,
      "existing_todos" => Enum.map(existing, &existing_todo_for_prompt/1),
      "existing_people" =>
        Crm.summarize_for_prompt(user_id, Keyword.get(opts, :people_limit, 24)),
      "memory_context" => safe_memory_context(user_id, candidates, opts),
      "todo_relevance_memories" => todo_relevance_memories(user_id, opts),
      "candidate_todos" => candidates
    }

    # existing_todos, relevance memories, and candidates get their own
    # sections below — re-encoding them inside the shared context doubled
    # the prompt size for no information gain.
    shared_context =
      Map.drop(payload, ["existing_todos", "todo_relevance_memories", "candidate_todos"])

    with {:ok, existing_json} <- Jason.encode(normalize_json_value(payload["existing_todos"])),
         {:ok, candidates_json} <- Jason.encode(normalize_json_value(candidates)),
         {:ok, todo_relevance_memories_json} <-
           Jason.encode(normalize_json_value(payload["todo_relevance_memories"])),
         {:ok, payload_json} <- Jason.encode(normalize_json_value(shared_context)) do
      {:ok,
       """
       #{@sentinel}

       You are Maraithon's built-in work-item intelligence layer.

       The caller is proposing durable work item candidates for one user. Use model-level
       judgment to decide whether each candidate should create a new work item, update an
       existing saved work item, or be skipped because it is already captured or not real work.
       Do not use exact-string matching or rigid source/id rules as the basis for
       deduplication. Compare meaning, source evidence, owner, account, timing, and
       next action.

       Requirements:
       - Return one decision for every candidate_todos item. `candidate_todos`,
         `existing_todo_id`, and the `todo` response object are internal JSON contract names.
       - Executive bar: if a busy operator would reasonably feel their time was
         wasted by seeing this as a separate work item, return action "skip".
         Favor fewer, sharper items over broad capture.
       - Use action "update" with existing_todo_id when the candidate is the same
         underlying work as an existing saved work item and should refresh it.
       - Use action "skip" only when no write should happen.
       - For create/update, provide a complete work item object in the `todo` field
         with source, title, summary, next_action, and dedupe_key.
       - Preserve useful source metadata such as Slack channel/thread, Gmail
         message/thread/account, calendar account/event, or Chief-of-Staff skill.
       - Include People enrichment whenever source evidence identifies people:
         put `crm_people` in todo.metadata as an array of people to upsert, with
         contact details, relationship, preferred communication method,
         communication frequency, notes, confidence, and relationship_note.
       - Include durable relationship memories whenever source evidence teaches
         something useful: put `relationship_memories` in todo.metadata as an
         array of memory objects with kind, title, content, tags, importance,
         confidence, and dedupe_key.
       - Learn from recurring human contacts and relationship proxies. If a
         person's parent, spouse, teacher, assistant, teammate, investor, or
         customer contact repeatedly sends source items, use People/memory context
         and the current source body to decide whether to enrich the relationship.
       - Default ownership is the main user unless the candidate clearly names
         another owner.
       - Use source bodies and metadata when available. Do not infer finance, tax,
         urgency, or relationship context from an ambiguous subject token alone.
       - For Gmail and content-sourced candidates, distinguish actual work from
         informational or educational content. Skip newsletters, articles,
         podcasts, videos, market commentary, and learning material unless the
         source body shows a direct ask, operator promise, deadline/deliverable,
         specific decision, human counterparty waiting, or concrete
         personal/business consequence if ignored.
       - Skip passive status notifications and FYI-only system updates unless
         the source requires a concrete operator action such as fix, approve,
         submit, decide, reply, pay, schedule, or unblock. "Acknowledge",
         "monitor", "keep an eye on it", or "step in if it changes" is not a
         durable work item by itself.
       - Relationship-maintenance nudges, cold/quiet-thread detectors, and raw
         calendar conflict detections are not durable work by default. Keep them
         out unless the source evidence shows a direct ask, real waiting person,
         concrete decision, deadline, or material consequence.
       - For school, classroom, child, camp, or family logistics, identify the
       child/person from People or memory when possible and write the next_action
       as the concrete thing the user needs to do.
       - Family relationship policy is an admission rule, not a ranking signal.
       If metadata says `todo_policy: "family_logistics_only"`, create or update
       only source-backed logistics, deadlines, direct requests, forms, appointments,
       pickup/dropoff, school/camp actions, travel, or user-requested reminders.
       If metadata says `todo_policy: "quiet_relationship_support"`, do not
       create standalone check-in/reach-out work items. Only an explicit
       `opt_in_rhythm` policy or user-requested reminder should create family
       relationship-rhythm work.
       - Work item title, summary, next_action, notes, and action_plan are user-facing
       in Telegram and should read like the operator's human chief of staff wrote them.
         Address the operator as `you`, never as `the user` or by their own name.
         Counterparties SHOULD be named. Do not include labels like
         `From:`, `Source:`, `Priority:`, `Open:`, `Status:`, or internal source
         names in these fields.
       - Distinguish the person the WORK is about from the person whose THREAD
         surfaced it. A relative texting about Monika's contract does not make
         the work about the relative: the title and next_action center the work
         itself ("Send Monika the Ambassador contract"), and the thread sender
         appears only as context or evidence. Bind a person to the work only
         when the source shows they are the requester, the recipient, or the
         one waiting.
       - Every create/update todo must include action_draft.text before it is saved.
         If a reply, email, Slack message, iMessage, or other sent message makes sense,
         make it a concise first-person draft or a conversational suggested wording in
         the operator's style, using memory_context and source evidence. State the
         draft's recipient explicitly when it could be ambiguous, and address it to
         the work's counterparty — not automatically to the thread sender. If a full
         draft does not make sense, still write a clear next-step sentence the operator
         can act on, for example: `You should message the requester and say:
         "Thanks, yes that would be great."`
       - Set due_at only when the source states an explicit deadline or date.
         Never infer a due_at from vague phrasing like "soon" or "next week";
         put that nuance in summary or why_it_matters instead.
       - Use product language for user-facing fields: say `work item`, `open work`,
         `People`, or `relationship context`; do not write `todo` or `CRM` in
         title, summary, next_action, notes, or action_plan unless quoting source text.
       - Never write generic copy such as "User committed to follow-up" or
         "confirm artifact status" without the subject. Every person-linked work item
         must say follow up about what, why the person is involved, and what
         concrete reply/draft/action Maraithon can help prepare.
       - Every person-linked work item needs enough context for the operator to remember why it
         matters: company/organization when known, relationship, why the person is
         in the thread, what they want, and what they are waiting on. Put structured
         values in metadata (`company`, `organization`, `relationship_context`,
         `relationship_strength`, `why_it_matters`, `life_domain`, `source_tags`).
         Include `relationship_strength` only when People/CRM context provides it;
         never invent a number — it directly drives ranking.
       - Rank candidate importance using this attention stack: personal/family
         commitments first; strongest relationships who need something; people
         actively waiting on a business objective, project, or deliverable; intro
         requests; meeting requests; routine backlog last.
       - If an old open item appears repeatedly and the operator has not acted, do not
         inflate it as urgent unless the evidence shows personal/family impact,
         a close relationship, or an active project/customer wait.
       - Apply `todo_relevance_memories` as durable work-relevance steering. These
         memories are negative "see less like this" examples written from
         explicit human feedback.
       - Decide semantically whether a candidate matches a negative work-relevance memory.
         Do not rely on exact keywords, sender, thread id, account, or source
         type alone. Compare the source evidence, ask/no-ask, owner, urgency,
         relationship, life domain, and whether someone is actually waiting.
       - If a candidate matches negative work-relevance memory and no exception
         signal applies, return action "skip" and explain the matching memory in
         reasoning.
       - For chief_of_staff_commitment_tracker candidates, metadata.completion_check
         is mandatory evidence that the work is still open. If completion_check.status
         is missing, unclear, or completed_or_closed, return action "skip". When you
         create/update one of these candidates, preserve metadata.completion_check
         exactly enough to show the later evidence checked and why the loop still
         needs action.
       - If a candidate partly matches negative feedback but may be worth keeping
         for later, create/update it as `attention_mode: "monitor"` with lower
         priority instead of putting it in act-now.
       - Negative work-relevance memories are not global blocks. Stronger fresh evidence,
         personal/family impact, a direct deadline, close relationship, customer
         wait, or user/customer impact can override them.
       - Write next_action as a sentence the operator can act on directly. Avoid
         ticket/report language such as "covering current state" when a human
         version like "ask if it is fixed, who owns it, and whether customers
         were affected" is clearer.
       - Priority is internal ranking only. Never encode numeric priority in
         title, summary, next_action, notes, or action_plan.
       - Return ONLY valid JSON. No markdown.

       Return JSON shaped like:
       {
         "summary": "short summary of the decisions",
         "decisions": [
           {
             "candidate_index": 0,
             "action": "create | update | skip",
             "existing_todo_id": null,
             "dedupe_key": "stable semantic key for create/update",
             "reasoning": "short explanation",
             "todo": {
               "source": "slack | gmail | calendar | telegram | chief_of_staff_morning_briefing | ...",
               "kind": "general | gmail_triage",
               "attention_mode": "act_now | monitor",
               "title": "short title",
               "summary": "actual work item",
               "next_action": "suggested next action",
               "due_at": "ISO-8601 datetime or omitted",
               "notes": "notes and metadata context",
               "action_plan": "draft or plan of the next action",
               "action_draft": {
                 "text": "ready suggested wording or a conversational next step"
               },
               "owner_user_id": "#{user_id}",
               "owner_label": null,
               "source_account_id": null,
               "source_account_label": null,
               "priority": 50,
               "status": "open",
               "source_item_id": null,
               "source_occurred_at": null,
               "dedupe_key": "same stable semantic key",
               "metadata": {
                 "crm_people": [],
                 "relationship_memories": []
               }
             }
           }
         ]
       }

       SHARED_CONTEXT_JSON (user, people, memory context — work items and
       candidates are in their own sections below):
       #{payload_json}

       EXISTING_TODOS_JSON:
       #{existing_json}

       TODO_RELEVANCE_MEMORIES_JSON:
       #{todo_relevance_memories_json}

       CANDIDATE_TODOS_JSON:
       #{candidates_json}
       """}
    end
  end

  defp safe_memory_context(user_id, candidates, opts) do
    query =
      Keyword.get(opts, :memory_query) ||
        candidates
        |> Enum.flat_map(fn candidate ->
          [
            read_string(candidate, "title", nil),
            read_string(candidate, "summary", nil),
            read_string(candidate, "notes", nil),
            candidate |> read_map("metadata") |> read_string("body_excerpt", nil)
          ]
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(12)
        |> Enum.join(" ")

    Memory.prompt_context(user_id, query: query, limit: Keyword.get(opts, :memory_limit, 8))
  rescue
    _error -> %{}
  catch
    _kind, _reason -> %{}
  end

  defp todo_relevance_memories(user_id, opts) do
    limit = Keyword.get(opts, :todo_relevance_memory_limit, 12)

    Memory.list_items(user_id,
      kind: "relevance_feedback",
      tag: "todo_relevance",
      status: "active",
      limit: limit
    )
    |> Enum.filter(&(&1.polarity == "negative"))
    |> Enum.map(&Memory.serialize_item/1)
    |> Enum.map(&todo_relevance_memory_for_prompt/1)
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp todo_relevance_memory_for_prompt(%{} = memory) do
    %{
      "id" => Map.get(memory, :id) || Map.get(memory, "id"),
      "title" => Map.get(memory, :title) || Map.get(memory, "title"),
      "summary" => Map.get(memory, :summary) || Map.get(memory, "summary"),
      "content" => Map.get(memory, :content) || Map.get(memory, "content"),
      "polarity" => Map.get(memory, :polarity) || Map.get(memory, "polarity"),
      "confidence" => Map.get(memory, :confidence) || Map.get(memory, "confidence"),
      "tags" => Map.get(memory, :tags) || Map.get(memory, "tags") || [],
      "metadata" =>
        (Map.get(memory, :metadata) || Map.get(memory, "metadata") || %{})
        |> Map.take([
          "pattern_key",
          "categories",
          "negative_signals",
          "exceptions",
          "reasoning",
          "feedback_source"
        ])
    }
    |> compact_map()
  end

  defp llm_complete(opts) do
    Keyword.get(opts, :llm_complete) || configured_llm_complete(opts)
  end

  defp configured_llm_complete(opts) do
    config = Application.get_env(:maraithon, :todos, [])

    case Keyword.get(config, :llm_complete) do
      fun when is_function(fun, 1) -> fun
      _other -> &default_llm_complete(&1, opts)
    end
  end

  defp default_llm_complete(prompt, opts) when is_binary(prompt) do
    config = Application.get_env(:maraithon, :todos, [])

    params = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" =>
        Keyword.get(opts, :max_tokens, Keyword.get(config, :max_tokens, @default_max_tokens)),
      "temperature" => 0.1,
      "reasoning_effort" =>
        Keyword.get(
          opts,
          :reasoning_effort,
          Keyword.get(config, :reasoning_effort, LLM.intelligence())
        ),
      "timeout_ms" =>
        Keyword.get(opts, :timeout_ms, Keyword.get(config, :timeout_ms, @default_timeout_ms))
    }

    case LLM.complete(params) do
      {:error, {:llm_provider_not_configured, _message}} = error ->
        if mock_when_unconfigured?() do
          Maraithon.LLM.MockProvider.complete(params)
        else
          error
        end

      result ->
        result
    end
  end

  defp mock_when_unconfigured? do
    :maraithon
    |> Application.get_env(:todos, [])
    |> Keyword.get(:mock_llm_when_unconfigured, false)
  end

  defp decode_response(response) do
    content =
      case response do
        %{"content" => content} -> content
        %{content: content} -> content
        content when is_binary(content) -> content
        _other -> nil
      end

    with content when is_binary(content) and content != "" <- content,
         {:ok, %{} = decoded} <- Jason.decode(content) do
      {:ok, decoded}
    else
      _other -> {:error, :todo_intelligence_invalid_json}
    end
  end

  defp response_usage(%{usage: usage}) when is_map(usage), do: normalize_json_value(usage)
  defp response_usage(%{"usage" => usage}) when is_map(usage), do: normalize_json_value(usage)
  defp response_usage(_response), do: %{}

  defp normalize_response(decoded, candidates, existing, opts) when is_map(decoded) do
    summary = read_string(decoded, "summary", nil)
    decisions = fetch_attr(decoded, "decisions")
    existing_by_id = Map.new(existing, &{&1.id, &1})

    with true <- is_list(decisions),
         true <- length(decisions) == length(candidates),
         {:ok, normalized} <-
           normalize_decisions(decisions, candidates, existing_by_id, summary, opts) do
      {:ok, normalized, summary}
    else
      _other -> {:error, :todo_intelligence_invalid_decisions}
    end
  end

  defp normalize_response(_decoded, _candidates, _existing, _opts) do
    {:error, :todo_intelligence_invalid_json}
  end

  defp normalize_decisions(decisions, candidates, existing_by_id, summary, opts) do
    decisions
    |> Enum.reduce_while({:ok, []}, fn decision, {:ok, acc} ->
      case normalize_decision(decision, candidates, existing_by_id, summary, opts) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_decision(decision, candidates, existing_by_id, summary, opts)
       when is_map(decision) do
    candidate_index = read_integer(decision, "candidate_index", nil)
    action = read_string(decision, "action", nil)
    candidate = if is_integer(candidate_index), do: Enum.at(candidates, candidate_index)
    reasoning = read_string(decision, "reasoning", nil)
    existing_todo_id = read_string(decision, "existing_todo_id", nil)
    proposed_todo_attrs = proposed_todo_attrs(decision)

    family_policy_skip_reason =
      if is_map(candidate) and is_map(proposed_todo_attrs) do
        family_policy_skip_reason(candidate, proposed_todo_attrs)
      end

    signal_gate_skip_reason =
      if is_map(candidate) and is_map(proposed_todo_attrs) do
        SignalGate.skip_reason(candidate, proposed_todo_attrs)
      end

    cond do
      not is_integer(candidate_index) or is_nil(candidate) ->
        {:error, :todo_intelligence_invalid_candidate_index}

      action not in @valid_actions ->
        {:error, :todo_intelligence_invalid_action}

      action == "skip" ->
        {:ok,
         %{
           action: action,
           candidate_index: candidate_index,
           existing_todo_id: existing_todo_id,
           reasoning: reasoning,
           todo_attrs: nil
         }}

      is_binary(family_policy_skip_reason) ->
        {:ok,
         %{
           action: "skip",
           candidate_index: candidate_index,
           existing_todo_id: nil,
           reasoning: family_policy_skip_reason,
           todo_attrs: nil
         }}

      is_binary(signal_gate_skip_reason) ->
        {:ok,
         %{
           action: "skip",
           candidate_index: candidate_index,
           existing_todo_id: nil,
           reasoning: signal_gate_skip_reason,
           todo_attrs: nil
         }}

      true ->
        normalize_persist_decision(
          decision,
          candidate_index,
          action,
          existing_todo_id,
          existing_by_id,
          reasoning,
          candidate,
          summary,
          opts
        )
    end
  end

  defp normalize_decision(_decision, _candidates, _existing_by_id, _summary, _opts) do
    {:error, :todo_intelligence_invalid_decision}
  end

  defp proposed_todo_attrs(decision) do
    decision
    |> fetch_attr("todo")
    |> case do
      attrs when is_map(attrs) -> stringify_top_level_keys(attrs)
      _other -> %{}
    end
  end

  defp family_policy_skip_reason(candidate, proposed_todo_attrs) do
    maps = nested_maps([candidate, proposed_todo_attrs])
    text = text_for_family_policy(candidate, proposed_todo_attrs)
    policy = family_todo_policy(maps)

    cond do
      policy in @family_opt_in_policies ->
        nil

      policy not in @family_guard_policies ->
        nil

      not family_context?(maps) ->
        nil

      user_requested_family_rhythm?(maps, text) ->
        nil

      family_logistics_evidence?(maps, text) ->
        nil

      generic_family_relationship_work?(text) ->
        family_policy_reason(policy)

      true ->
        nil
    end
  end

  defp family_policy_reason("family_logistics_only") do
    "Skipped by family logistics-only policy: this looks like relationship maintenance, not source-backed family logistics or an explicit reminder."
  end

  defp family_policy_reason("quiet_relationship_support") do
    "Skipped by quiet family support policy: standalone check-in work items require an explicit opt-in rhythm or reminder."
  end

  defp family_policy_reason(_policy), do: "Skipped by family relationship policy."

  defp family_todo_policy(maps) do
    Enum.find_value(maps, fn map ->
      map
      |> read_string("todo_policy", nil)
      |> normalize_family_policy()
    end)
  end

  defp normalize_family_policy(policy) when is_binary(policy) do
    policy =
      policy
      |> String.downcase()
      |> String.replace("-", "_")
      |> String.trim()

    if policy in @family_guard_policies or policy in @family_opt_in_policies do
      policy
    end
  end

  defp normalize_family_policy(_policy), do: nil

  defp family_context?(maps) do
    Enum.any?(maps, fn map ->
      read_string(map, "relationship_domain", nil) == "family" or
        read_string(map, "family_role", nil) not in [nil, ""] or
        read_string(map, "sensitivity", nil) in ["child_family", "family"] or
        truthy?(fetch_attr(map, "family_member")) or
        truthy?(fetch_attr(map, "dependent_context"))
    end)
  end

  defp user_requested_family_rhythm?(maps, text) do
    Enum.any?(maps, fn map ->
      truthy?(fetch_attr(map, "user_requested")) or
        truthy?(fetch_attr(map, "explicit_reminder")) or
        truthy?(fetch_attr(map, "opt_in_rhythm"))
    end) or contains_any_phrase?(text, @family_user_requested_phrases)
  end

  defp family_logistics_evidence?(maps, text) do
    Enum.any?(maps, fn map ->
      truthy?(fetch_attr(map, "direct_ask")) or
        truthy?(fetch_attr(map, "family_logistics"))
    end) or
      contains_any_phrase?(text, @family_logistics_phrases) or
      contains_any_word?(text, @family_logistics_terms)
  end

  defp generic_family_relationship_work?(text) do
    contains_any_phrase?(text, @family_relationship_phrases)
  end

  defp text_for_family_policy(candidate, proposed_todo_attrs) do
    [candidate, proposed_todo_attrs]
    |> Enum.flat_map(&collect_text/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp collect_text(%_struct{}), do: []

  defp collect_text(value) when is_map(value) do
    value
    |> stringify_top_level_keys()
    |> Enum.flat_map(fn
      {key, nested} when key in ["title", "summary", "next_action", "notes", "action_plan"] ->
        collect_text(nested)

      {key, nested}
      when key in [
             "metadata",
             "record",
             "person_context",
             "crm_people",
             "people",
             "relationship_memories"
           ] ->
        collect_text(nested)

      _other ->
        []
    end)
  end

  defp collect_text(value) when is_list(value), do: Enum.flat_map(value, &collect_text/1)

  defp collect_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: [], else: [value]
  end

  defp collect_text(_value), do: []

  defp nested_maps(value) when is_list(value), do: Enum.flat_map(value, &nested_maps/1)

  defp nested_maps(%_struct{}), do: []

  defp nested_maps(value) when is_map(value) do
    map = stringify_top_level_keys(value)

    [map | map |> Map.values() |> Enum.flat_map(&nested_maps/1)]
  end

  defp nested_maps(_value), do: []

  defp contains_any_phrase?(text, phrases) when is_binary(text) do
    Enum.any?(phrases, &String.contains?(text, &1))
  end

  defp contains_any_phrase?(_text, _phrases), do: false

  defp contains_any_word?(text, words) when is_binary(text) do
    Enum.any?(words, fn word ->
      Regex.match?(~r/(^|[^a-z0-9_])#{Regex.escape(word)}($|[^a-z0-9_])/, text)
    end)
  end

  defp contains_any_word?(_text, _words), do: false

  defp truthy?(value) when value in [true, 1], do: true

  defp truthy?(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> then(&(&1 in ["true", "yes", "1"]))
  end

  defp truthy?(_value), do: false

  defp normalize_persist_decision(
         decision,
         candidate_index,
         action,
         existing_todo_id,
         existing_by_id,
         reasoning,
         candidate,
         summary,
         opts
       ) do
    todo_attrs =
      decision
      |> fetch_attr("todo")
      |> case do
        attrs when is_map(attrs) -> stringify_top_level_keys(attrs)
        _other -> %{}
      end

    existing_todo =
      if action == "update" do
        Map.get(existing_by_id, existing_todo_id)
      end

    dedupe_key =
      read_string(todo_attrs, "dedupe_key", read_string(decision, "dedupe_key", nil)) ||
        if(existing_todo, do: existing_todo.dedupe_key)

    todo_attrs =
      todo_attrs
      |> Map.put("dedupe_key", dedupe_key)
      |> preserve_candidate_completion_check(candidate)
      |> preserve_candidate_source_identifiers(candidate)
      |> preserve_candidate_source_context(candidate)
      |> put_intelligence_metadata(
        action,
        candidate_index,
        existing_todo_id,
        reasoning,
        summary,
        opts
      )
      |> UserFacingCopy.polish_attrs()
      |> SurfaceQuality.annotate_attrs()

    signal_gate_skip_reason = SignalGate.skip_reason(candidate, todo_attrs)

    cond do
      is_binary(signal_gate_skip_reason) ->
        {:ok,
         %{
           action: "skip",
           candidate_index: candidate_index,
           existing_todo_id: nil,
           reasoning: signal_gate_skip_reason,
           todo_attrs: nil
         }}

      action == "update" and is_nil(existing_todo) ->
        {:error, :todo_intelligence_existing_todo_not_found}

      missing_required_fields(todo_attrs) != [] ->
        {:error, {:todo_intelligence_missing_todo_fields, missing_required_fields(todo_attrs)}}

      not valid_optional_maps?(todo_attrs) ->
        {:error, :todo_intelligence_invalid_todo_maps}

      true ->
        {:ok,
         %{
           action: action,
           candidate_index: candidate_index,
           existing_todo_id: existing_todo_id,
           reasoning: reasoning,
           todo_attrs: todo_attrs
         }}
    end
  end

  defp preserve_candidate_completion_check(todo_attrs, candidate) do
    todo_metadata = read_map(todo_attrs, "metadata")
    candidate_metadata = read_map(candidate || %{}, "metadata")
    candidate_completion_check = read_map(candidate_metadata, "completion_check")

    cond do
      read_map(todo_metadata, "completion_check") != %{} ->
        todo_attrs

      candidate_completion_check != %{} ->
        Map.put(
          todo_attrs,
          "metadata",
          Map.put(todo_metadata, "completion_check", candidate_completion_check)
        )

      true ->
        todo_attrs
    end
  end

  defp apply_decisions(user_id, decisions, summary) do
    attrs_list =
      decisions
      |> Enum.filter(&(&1.action in @persist_actions))
      |> Enum.map(& &1.todo_attrs)

    persisted_result =
      case attrs_list do
        [] -> {:ok, []}
        attrs -> Todos.upsert_many(user_id, attrs)
      end

    with {:ok, persisted} <- persisted_result do
      persisted_by_dedupe_key = Map.new(persisted, &{&1.dedupe_key, &1})
      persisted_by_id = Map.new(persisted, &{&1.id, &1})

      decision_summaries =
        Enum.map(decisions, fn decision ->
          summarize_decision(decision, persisted_by_dedupe_key, persisted_by_id)
        end)

      skipped =
        decision_summaries
        |> Enum.filter(&(&1.action == "skip"))

      {:ok,
       %{
         todos: persisted,
         skipped: skipped,
         skipped_count: length(skipped),
         decisions: decision_summaries,
         summary: summary
       }}
    end
  end

  defp summarize_decision(decision, persisted_by_dedupe_key, persisted_by_id) do
    persisted =
      case decision.todo_attrs do
        %{"dedupe_key" => dedupe_key} -> Map.get(persisted_by_dedupe_key, dedupe_key)
        _other -> nil
      end

    persisted = persisted || Map.get(persisted_by_id, decision.existing_todo_id)

    %{
      action: decision.action,
      candidate_index: decision.candidate_index,
      existing_todo_id: decision.existing_todo_id,
      persisted_todo_id: persisted && persisted.id,
      reasoning: decision.reasoning
    }
    |> compact_map()
  end

  # Deep links and completion sweeps need the raw source identifiers; the model
  # often rewrites metadata, so carry these over mechanically instead of
  # trusting the response to copy them.
  @source_identifier_keys ~w(
    channel_id channel_name chat_display_name chat_key event_link gmail_message_id
    gmail_thread_id html_link message_id permalink person_slack_user_id phone
    sender_handle sender_phone source_message_id source_thread_id source_url
    team_id thread_id thread_ts url wa_phone
  )

  @source_context_metadata_keys ~w(
    body_excerpt checked_evidence context context_brief conversation_context direct_ask
    evidence evidence_summary excerpt explicit_user_commitment false_positive_risk family_member
    family_role fyi_class importance importance_hint life_domain missing_followthrough_evidence
    obligation_type organization people person project project_name quote record
    relationship_context relationship_domain reply_obligation sensitivity source_body
    source_evidence source_excerpt source_ref source_refs source_subject subject thread_subject
    todo_policy user_requested why_it_matters why_now work_item_admission
  )

  defp preserve_candidate_source_identifiers(todo_attrs, candidate) do
    candidate_metadata = read_map(candidate || %{}, "metadata")

    if candidate_metadata == %{} do
      todo_attrs
    else
      todo_metadata = todo_metadata_for_preservation(todo_attrs)

      preserved =
        Enum.reduce(@source_identifier_keys, todo_metadata, fn key, acc ->
          value = read_string(candidate_metadata, key, nil)

          if is_binary(value) and not Map.has_key?(acc, key) do
            Map.put(acc, key, value)
          else
            acc
          end
        end)

      Map.put(todo_attrs, "metadata", preserved)
    end
  end

  defp preserve_candidate_source_context(todo_attrs, candidate) do
    candidate_metadata = read_map(candidate || %{}, "metadata")

    if candidate_metadata == %{} do
      todo_attrs
    else
      preserved =
        Enum.reduce(
          @source_context_metadata_keys,
          todo_metadata_for_preservation(todo_attrs),
          fn key, acc ->
            value = fetch_attr(candidate_metadata, key)

            cond do
              Map.has_key?(acc, key) ->
                acc

              preservable_metadata_value?(value) ->
                Map.put(acc, key, normalize_json_value(value))

              true ->
                acc
            end
          end
        )

      Map.put(todo_attrs, "metadata", preserved)
    end
  end

  defp todo_metadata_for_preservation(todo_attrs) do
    case fetch_attr(todo_attrs, "metadata") do
      value when is_map(value) -> stringify_top_level_keys(value)
      _other -> %{}
    end
  end

  defp preservable_metadata_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp preservable_metadata_value?(value) when is_list(value), do: value != []
  defp preservable_metadata_value?(value) when is_map(value), do: map_size(value) > 0
  defp preservable_metadata_value?(value) when is_number(value), do: true
  defp preservable_metadata_value?(true), do: true
  defp preservable_metadata_value?(_value), do: false

  defp put_intelligence_metadata(
         todo_attrs,
         action,
         candidate_index,
         existing_todo_id,
         reasoning,
         summary,
         opts
       ) do
    metadata =
      case fetch_attr(todo_attrs, "metadata") do
        value when is_map(value) -> stringify_top_level_keys(value)
        nil -> %{}
        _other -> %{}
      end

    intelligence =
      %{
        "action" => action,
        "candidate_index" => candidate_index,
        "existing_todo_id" => existing_todo_id,
        "reasoning" => reasoning,
        "summary" => summary,
        "source" => Keyword.get(opts, :source, "todo_intelligence"),
        "decided_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
      |> compact_map()

    Map.put(todo_attrs, "metadata", Map.put(metadata, "todo_intelligence", intelligence))
  end

  defp missing_required_fields(attrs) do
    Enum.filter(@required_todo_fields, fn field ->
      is_nil(read_string(attrs, field, nil))
    end)
  end

  defp valid_optional_maps?(attrs) do
    Enum.all?(["metadata", "action_draft"], fn field ->
      case fetch_attr(attrs, field) do
        nil -> true
        value when is_map(value) -> true
        _other -> false
      end
    end)
  end

  # Metadata keys that matter for same-work recognition. Existing items are
  # dedup reference, not regeneration input — embedding their full metadata
  # maps (intelligence trails, surface-quality annotations, CRM blobs) was
  # the largest single source of prompt bloat.
  @existing_prompt_metadata_keys ~w(
    channel_id channel_name chat_display_name chat_key commitment_direction company
    completion_check detector gmail_message_id gmail_thread_id life_domain message_id
    obligation_type organization person reminder_title team_id thread_id thread_ts
    why_it_matters
  )

  @existing_prompt_text_limit 400

  defp existing_todo_for_prompt(%Todo{} = todo) do
    %{
      "id" => todo.id,
      "source" => todo.source,
      "source_account_id" => todo.source_account_id,
      "source_account_label" => todo.source_account_label,
      "kind" => todo.kind,
      "attention_mode" => todo.attention_mode,
      "status" => todo.status,
      "title" => todo.title,
      "summary" => clip_prompt_text(todo.summary),
      "next_action" => clip_prompt_text(todo.next_action),
      "due_at" => normalize_json_value(todo.due_at),
      "notes" => clip_prompt_text(todo.notes),
      "action_plan" => clip_prompt_text(todo.action_plan),
      "owner_user_id" => todo.owner_user_id,
      "owner_label" => todo.owner_label,
      "priority" => todo.priority,
      "source_item_id" => todo.source_item_id,
      "source_occurred_at" => normalize_json_value(todo.source_occurred_at),
      "dedupe_key" => todo.dedupe_key,
      "metadata" => existing_metadata_for_prompt(todo.metadata),
      "updated_at" => normalize_json_value(todo.updated_at)
    }
    |> compact_map()
  end

  defp existing_metadata_for_prompt(metadata) when is_map(metadata) do
    Enum.reduce(@existing_prompt_metadata_keys, %{}, fn key, acc ->
      case Map.get(metadata, key) do
        nil ->
          acc

        value when is_binary(value) ->
          Map.put(acc, key, clip_prompt_text(value))

        value when is_map(value) or is_number(value) or is_boolean(value) ->
          Map.put(acc, key, value)

        _other ->
          acc
      end
    end)
  end

  defp existing_metadata_for_prompt(_metadata), do: %{}

  defp clip_prompt_text(value) when is_binary(value) do
    if String.length(value) <= @existing_prompt_text_limit do
      value
    else
      String.slice(value, 0, @existing_prompt_text_limit - 1) <> "…"
    end
  end

  defp clip_prompt_text(value), do: value

  defp read_string(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _other ->
        default
    end
  end

  defp read_map(attrs, key) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_map(value) -> stringify_top_level_keys(value)
      _other -> %{}
    end
  end

  defp read_integer(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _other -> default
        end

      _other ->
        default
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        case existing_atom_key(key) do
          atom_key when is_atom(atom_key) -> Map.get(attrs, atom_key)
          _other -> nil
        end
    end
  end

  defp stringify_top_level_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_json_value(%Time{} = value), do: Time.to_iso8601(value)

  defp normalize_json_value(value) when is_list(value),
    do: Enum.map(value, &normalize_json_value/1)

  defp normalize_json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_json_value(nested)} end)
  end

  defp normalize_json_value(value), do: value

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
