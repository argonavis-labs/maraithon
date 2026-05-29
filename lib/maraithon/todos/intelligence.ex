defmodule Maraithon.Todos.Intelligence do
  @moduledoc """
  Model-backed ingestion for durable work item candidates.

  This module is the write boundary for assistant-created work items. It gives the
  model both candidate work and existing saved work, then applies only explicit
  create/update/skip decisions returned by the model.
  """

  alias Maraithon.{Crm, LLM, Memory}
  alias Maraithon.Todos
  alias Maraithon.Todos.{SurfaceQuality, UserFacingCopy}
  alias Maraithon.Todos.Todo

  @sentinel "TODO_INTELLIGENCE_JSON_V1"
  @persist_actions ~w(create update)
  @valid_actions ["create", "update", "skip"]
  @required_todo_fields ~w(source title summary next_action dedupe_key)
  @default_max_tokens 64_000
  @default_timeout_ms 1_200_000

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

    with {:ok, existing_json} <- Jason.encode(normalize_json_value(payload["existing_todos"])),
         {:ok, candidates_json} <- Jason.encode(normalize_json_value(candidates)),
         {:ok, todo_relevance_memories_json} <-
           Jason.encode(normalize_json_value(payload["todo_relevance_memories"])),
         {:ok, payload_json} <- Jason.encode(normalize_json_value(payload)) do
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
       - For school, classroom, child, camp, or family logistics, identify the
         child/person from People or memory when possible and write the next_action
         as the concrete thing the user needs to do.
       - Work item title, summary, next_action, notes, and action_plan are user-facing
         in Telegram and should read like Kent's human chief of staff wrote them.
         Use `you` or `Kent`, never `the user`. Do not include labels like
         `From:`, `Source:`, `Priority:`, `Open:`, `Status:`, or internal source
         names in these fields.
       - Use product language for user-facing fields: say `work item`, `open work`,
         `People`, or `relationship context`; do not write `todo` or `CRM` in
         title, summary, next_action, notes, or action_plan unless quoting source text.
       - Never write generic copy such as "User committed to follow-up" or
         "confirm artifact status" without the subject. Every person-linked work item
         must say follow up about what, why the person is involved, and what
         concrete reply/draft/action Maraithon can help prepare.
       - Every person-linked work item needs enough context for Kent to remember why it
         matters: company/organization when known, relationship, why the person is
         in the thread, what they want, and what they are waiting on. Put structured
         values in metadata (`company`, `organization`, `relationship_context`,
         `relationship_strength`, `why_it_matters`, `life_domain`, `source_tags`).
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
               "action_draft": {},
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

       FULL_PAYLOAD_JSON:
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

      true ->
        normalize_persist_decision(
          decision,
          candidate_index,
          action,
          existing_todo_id,
          existing_by_id,
          reasoning,
          summary,
          opts
        )
    end
  end

  defp normalize_decision(_decision, _candidates, _existing_by_id, _summary, _opts) do
    {:error, :todo_intelligence_invalid_decision}
  end

  defp normalize_persist_decision(
         decision,
         candidate_index,
         action,
         existing_todo_id,
         existing_by_id,
         reasoning,
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

    cond do
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
      "summary" => todo.summary,
      "next_action" => todo.next_action,
      "due_at" => normalize_json_value(todo.due_at),
      "notes" => todo.notes,
      "action_plan" => todo.action_plan,
      "owner_user_id" => todo.owner_user_id,
      "owner_label" => todo.owner_label,
      "priority" => todo.priority,
      "source_item_id" => todo.source_item_id,
      "source_occurred_at" => normalize_json_value(todo.source_occurred_at),
      "dedupe_key" => todo.dedupe_key,
      "metadata" => todo.metadata || %{},
      "updated_at" => normalize_json_value(todo.updated_at)
    }
    |> compact_map()
  end

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
