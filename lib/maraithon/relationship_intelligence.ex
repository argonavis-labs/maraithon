defmodule Maraithon.RelationshipIntelligence do
  @moduledoc """
  Model-backed relationship learning for source observations.

  This module is the durable learning boundary for people. Source scanners pass
  recent observations here; the model decides which people, relationships, and
  memories are worth storing. Runtime code only validates and persists the
  structured result.
  """

  alias Maraithon.Crm
  alias Maraithon.Crm.{Person, PersonLink}
  alias Maraithon.LLM
  alias Maraithon.Memory
  alias Maraithon.Memory.Item

  @sentinel "RELATIONSHIP_INTELLIGENCE_JSON_V1"
  @max_observations 16
  @max_people 8
  @max_memories 6
  @max_links 12
  @default_max_tokens 6_000
  @default_reasoning_effort "none"
  @default_people_limit 16
  @prompt_long_string_chars 1_200
  @prompt_string_chars 700
  @valid_resource_types ~w(todo gmail_thread gmail_message calendar_event slack_thread slack_message telegram_message whatsapp_message source_observation)

  def sentinel, do: @sentinel

  def llm_params(user_id, observations, opts \\ [])

  def llm_params(user_id, observations, opts)
      when is_binary(user_id) and is_list(observations) and is_list(opts) do
    normalized_observations = normalize_observations(observations)

    if normalized_observations == [] do
      {:error, :no_relationship_observations}
    else
      prompt = build_prompt(user_id, normalized_observations, opts)

      {:ok,
       %{
         "messages" => [%{"role" => "user", "content" => prompt}],
         "max_tokens" => Keyword.get(opts, :max_tokens, @default_max_tokens),
         "temperature" => Keyword.get(opts, :temperature, 0.1),
         "reasoning_effort" => Keyword.get(opts, :reasoning_effort, @default_reasoning_effort)
       }}
      |> maybe_put_model(Keyword.get(opts, :model, LLM.chat_model()))
    end
  end

  def llm_params(_user_id, _observations, _opts), do: {:error, :invalid_relationship_observations}

  def learn_from_observations(user_id, observations, opts \\ [])

  def learn_from_observations(user_id, observations, opts)
      when is_binary(user_id) and is_list(observations) and is_list(opts) do
    with {:ok, params} <- llm_params(user_id, observations, opts),
         {:ok, response} <- complete(params, opts),
         {:ok, content} <- response_content(response),
         {:ok, result} <- persist_from_response(user_id, content, opts) do
      {:ok, result}
    end
  end

  def learn_from_observations(_user_id, _observations, _opts),
    do: {:error, :invalid_relationship_observations}

  def persist_from_response(user_id, content, opts \\ [])

  def persist_from_response(user_id, content, opts)
      when is_binary(user_id) and is_binary(content) and is_list(opts) do
    with {:ok, decoded} <- decode_response(content) do
      persist_decisions(user_id, decoded, opts)
    end
  end

  def persist_from_response(_user_id, _content, _opts),
    do: {:error, :invalid_relationship_response}

  defp build_prompt(user_id, observations, opts) do
    source = Keyword.get(opts, :source, "relationship_intelligence")
    now = Keyword.get(opts, :now, DateTime.utc_now())

    existing_people =
      user_id
      |> Crm.summarize_for_prompt(Keyword.get(opts, :people_limit, @default_people_limit))
      |> Enum.map(&compact_prompt_value/1)

    memory_context = safe_memory_context(user_id, observations, opts)

    payload = %{
      "user_id" => user_id,
      "user_identity" => Maraithon.UserIdentity.prompt_block(user_id),
      "source" => source,
      "generated_at" => normalize_json_value(now),
      "existing_people" => existing_people,
      "memory_context" => compact_prompt_value(memory_context),
      "observations" => Enum.map(observations, &compact_prompt_value/1)
    }

    """
    #{@sentinel}

    You are Maraithon's relationship intelligence layer.

    The app is building a durable CRM and memory system for one busy user. Use
    model-level judgment over source observations, existing CRM records, and
    durable memory to decide what should be learned about people and
    relationships. Do not use keyword heuristics as decision rules. Frequency,
    channel, source body, relationship language, roles, asks, and user history
    are evidence for you to reason over.

    `user_identity` states who the user is, including their own phone
    numbers and emails. Never create or enrich a person record for the
    user's own handles, and never read the user's own messages (including
    in group conversations) as someone asking the user for something.

    Goals:
    - Keep a useful CRM of every real human the user interacts with, then let
      repeated interactions, source evidence, and user discussion grow the
      relationship strength over time.
    - Learn rich context for important people without requiring the user to
      manually correct every source item.
    - Treat each real incoming or outgoing human communication as relationship
      evidence, even when it does not create a todo. The CRM is the contact
      ledger, not only the task ledger.
    - If a parent, spouse, assistant, teacher, teammate, investor, customer, or
      other proxy repeatedly communicates about a person, learn the proxy and
      the person/context when the evidence supports it.
    - For school, child, camp, health, home, family, and work logistics, identify
      who the item concerns from source bodies, existing CRM, and memory.
    - Prefer a cautious but useful relationship note over a brittle exact label.
      Example: "Likely school contact for Emma" is better than pretending to
      know a last name or role not in evidence.

    Hard rules:
    - Do not invent facts. Store inferred relationships only when evidence is
      visible in observations, existing_people, or memory_context.
    - Do not write a person for automated senders, newsletters, receipts, or
      machine-only systems unless a real human participant, owner, sender,
      attendee, signer, asker, or discussed person is clearly attached.
    - When a real person is visible in a human communication, create or update
      the CRM record even if the relationship label is still provisional.
    - Do not classify ambiguous tokens like "4M" as finance, work, or family
      context without source-body evidence.
    - If the same person already exists, update that CRM record instead of
      creating a duplicate. Use emails/phones/slack ids/telegram ids when
      available.
    - Write memories only for durable facts or durable relationship guidance that
      will improve future decisions.
    - Link learned people to relevant source observations or todos when a
      resource id is available.
    - Return ONLY valid JSON. No markdown.

    Output budget:
    - Return at most #{@max_people} people, #{@max_memories} memories, and #{@max_links} links.
    - If more observations qualify, choose the highest-confidence durable facts
      and skip borderline or duplicate items.
    - Keep every string field to one short sentence. Keep notes, memory content,
      link summaries, and metadata reasoning concise.
    - Prefer empty arrays over verbose low-confidence output.

    Return JSON shaped like:
    {
      "summary": "short summary",
      "people": [
        {
          "person_ref": "stable local reference used by links",
          "first_name": null,
          "last_name": null,
          "display_name": "Full or best known name",
          "contact_details": {"emails": [], "phones": [], "slack_ids": [], "telegram_ids": []},
          "preferred_communication_method": "gmail | slack | telegram | phone | ...",
          "relationship": "concise relationship to the user",
          "communication_frequency": "model estimate from evidence",
          "interaction_count_delta": 1,
          "relationship_strength": 0,
          "affinity_score": 0,
          "last_interaction_at": "ISO-8601 datetime when the interaction occurred",
          "notes": "rich context that helps future triage",
          "importance": 0,
          "confidence": 0.0,
          "metadata": {"reasoning": "why this should be remembered"}
        }
      ],
      "memories": [
        {
          "kind": "relationship | preference | fact | correction",
          "title": "short title",
          "content": "durable memory",
          "summary": "short summary",
          "tags": [],
          "importance": 0,
          "confidence": 0.0,
          "dedupe_key": "stable key",
          "metadata": {}
        }
      ],
      "links": [
        {
          "person_ref": "person_ref, display_name, or contact value",
          "resource_type": "todo | gmail_thread | gmail_message | calendar_event | slack_thread | telegram_message | whatsapp_message | source_observation",
          "resource_id": "source id",
          "resource_source": "gmail | calendar | slack | telegram | whatsapp | ...",
          "title": "short source title",
          "summary": "why this source is attached to the person",
          "relationship_note": "how this item relates to the person",
          "metadata": {}
        }
      ]
    }

    FULL_PAYLOAD_JSON:
    #{Jason.encode!(normalize_json_value(payload))}
    """
  end

  defp safe_memory_context(user_id, observations, opts) do
    query =
      Keyword.get(opts, :query) ||
        observations
        |> Enum.flat_map(fn observation ->
          [
            Map.get(observation, "title"),
            Map.get(observation, "summary"),
            Map.get(observation, "from"),
            Map.get(observation, "to")
          ]
        end)
        |> Enum.reject(&blank?/1)
        |> Enum.take(12)
        |> Enum.join(" ")

    Memory.prompt_context(user_id, query: query, limit: Keyword.get(opts, :memory_limit, 8))
  rescue
    _error -> %{}
  catch
    _kind, _reason -> %{}
  end

  defp complete(params, opts) do
    cond do
      is_function(Keyword.get(opts, :llm_complete), 1) ->
        Keyword.fetch!(opts, :llm_complete).(params)

      is_function(configured_llm_complete(), 1) ->
        configured_llm_complete().(params)

      true ->
        LLM.complete(params)
    end
  end

  defp configured_llm_complete do
    :maraithon
    |> Application.get_env(:relationship_intelligence, [])
    |> Keyword.get(:llm_complete)
  end

  defp response_content(%{content: content}) when is_binary(content), do: {:ok, content}
  defp response_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp response_content(content) when is_binary(content), do: {:ok, content}
  defp response_content(_response), do: {:error, :relationship_intelligence_missing_content}

  defp decode_response(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, :relationship_intelligence_invalid_json}
    end
  end

  defp persist_decisions(user_id, decoded, opts) do
    people_decisions =
      decoded
      |> read_list("people")
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_people)

    memory_decisions =
      decoded
      |> read_list("memories")
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_memories)

    link_decisions =
      decoded
      |> read_list("links")
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_links)

    {people, people_errors} =
      Enum.reduce(people_decisions, {[], []}, fn attrs, {people, errors} ->
        case persist_person(user_id, attrs, opts) do
          {:ok, %Person{} = person} -> {[person | people], errors}
          {:error, reason} -> {people, [error("person", attrs, reason) | errors]}
        end
      end)

    people = Enum.reverse(people)
    person_index = person_index(people, people_decisions)

    {memories, memory_errors} =
      Enum.reduce(memory_decisions, {[], []}, fn attrs, {memories, errors} ->
        case persist_memory(user_id, attrs, opts) do
          {:ok, %Item{} = item} -> {[item | memories], errors}
          {:error, reason} -> {memories, [error("memory", attrs, reason) | errors]}
        end
      end)

    {links, link_errors} =
      Enum.reduce(link_decisions, {[], []}, fn attrs, {links, errors} ->
        case persist_link(user_id, attrs, person_index) do
          {:ok, %PersonLink{} = link} -> {[link | links], errors}
          {:skip, reason} -> {links, [error("link", attrs, reason) | errors]}
          {:error, reason} -> {links, [error("link", attrs, reason) | errors]}
        end
      end)

    {:ok,
     %{
       source: "maraithon_relationship_intelligence",
       summary: read_string(decoded, "summary", nil),
       people_count: length(people),
       memory_count: length(memories),
       link_count: length(links),
       people: Enum.map(people, &serialize_person/1),
       memories: Enum.map(Enum.reverse(memories), &serialize_memory/1),
       links: Enum.map(Enum.reverse(links), &serialize_link/1),
       errors: Enum.reverse(people_errors ++ memory_errors ++ link_errors)
     }}
  end

  defp persist_person(user_id, attrs, opts) do
    attrs = stringify_top_level_keys(attrs)
    confidence = read_float(attrs, "confidence", 0.75)

    if confidence < Keyword.get(opts, :min_person_confidence, 0.55) do
      {:error, :low_confidence_person}
    else
      person_attrs =
        attrs
        |> Map.drop(["person_ref", "importance", "confidence"])
        |> Map.put_new("interaction_count_delta", 1)
        |> Map.put_new(
          "last_interaction_at",
          Keyword.get(opts, :now, DateTime.utc_now()) |> normalize_json_value()
        )
        |> Map.update("metadata", %{}, fn metadata ->
          metadata
          |> normalize_map()
          |> Map.merge(%{
            "relationship_intelligence" =>
              compact_map(%{
                "source" => Keyword.get(opts, :source, "relationship_intelligence"),
                "importance" => read_integer(attrs, "importance", nil),
                "confidence" => confidence,
                "learned_at" =>
                  Keyword.get(opts, :now, DateTime.utc_now())
                  |> normalize_json_value()
              })
          })
        end)

      Crm.upsert_person(user_id, person_attrs)
    end
  end

  defp persist_memory(user_id, attrs, opts) do
    attrs = stringify_top_level_keys(attrs)
    confidence = read_float(attrs, "confidence", 0.75)

    if confidence < Keyword.get(opts, :min_memory_confidence, 0.6) do
      {:error, :low_confidence_memory}
    else
      memory_attrs =
        attrs
        |> Map.put_new("kind", "relationship")
        |> Map.put_new("scope", "user")
        |> Map.put_new("author_type", "model")
        |> Map.put_new("source", Keyword.get(opts, :source, "relationship_intelligence"))
        |> Map.put_new("importance", 70)
        |> Map.put_new("confidence", confidence)
        |> Map.update("metadata", %{}, fn metadata ->
          metadata
          |> normalize_map()
          |> Map.put("relationship_intelligence", true)
        end)

      Memory.write(user_id, memory_attrs,
        source: Keyword.get(opts, :source, "relationship_intelligence")
      )
    end
  end

  defp persist_link(user_id, attrs, person_index) do
    attrs = stringify_top_level_keys(attrs)

    with %Person{} = person <- resolve_link_person(attrs, person_index),
         {:ok, resource_type} <- normalize_resource_type(attrs),
         {:ok, resource_id} <- required_string(attrs, "resource_id") do
      link_attrs =
        attrs
        |> Map.take(["resource_source", "title", "summary", "relationship_note", "metadata"])
        |> Map.put("resource_type", resource_type)
        |> Map.put("resource_id", resource_id)
        |> Map.update("metadata", %{}, &normalize_map/1)

      Crm.attach_resource(user_id, person.id, link_attrs)
    else
      nil -> {:skip, :person_not_found}
      {:error, reason} -> {:skip, reason}
    end
  end

  defp normalize_resource_type(attrs) do
    resource_type =
      attrs
      |> read_string("resource_type", "source_observation")
      |> String.trim()

    if resource_type in @valid_resource_types do
      {:ok, resource_type}
    else
      {:ok, "source_observation"}
    end
  end

  defp resolve_link_person(attrs, person_index) do
    [
      read_string(attrs, "person_ref", nil),
      read_string(attrs, "person_id", nil),
      read_string(attrs, "display_name", nil),
      read_string(attrs, "email", nil)
    ]
    |> Enum.find_value(fn value -> value && Map.get(person_index, normalize_lookup(value)) end)
  end

  defp person_index(people, decisions) do
    Enum.zip(people, decisions)
    |> Enum.reduce(%{}, fn {%Person{} = person, decision}, acc ->
      refs =
        [
          person.id,
          person.display_name,
          person.first_name,
          read_string(decision, "person_ref", nil)
        ] ++ contact_values(person.contact_details || %{})

      refs
      |> Enum.reject(&blank?/1)
      |> Enum.reduce(acc, fn ref, acc -> Map.put(acc, normalize_lookup(ref), person) end)
    end)
  end

  defp contact_values(contact_details) when is_map(contact_details) do
    [
      Map.get(contact_details, "emails"),
      Map.get(contact_details, "phones"),
      Map.get(contact_details, "slack_ids"),
      Map.get(contact_details, "telegram_ids")
    ]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.filter(&is_binary/1)
  end

  defp contact_values(_contact_details), do: []

  defp normalize_observations(observations) do
    observations
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_observation/1)
    |> Enum.reject(&(&1 == %{}))
    |> Enum.uniq_by(fn observation ->
      {Map.get(observation, "resource_type"), Map.get(observation, "resource_id"),
       Map.get(observation, "summary")}
    end)
    |> Enum.take(@max_observations)
  end

  defp normalize_observation(observation) do
    observation
    |> normalize_json_value()
    |> normalize_map()
    |> compact_prompt_value()
    |> compact_map()
  end

  defp maybe_put_model({:ok, params}, nil), do: {:ok, params}
  defp maybe_put_model({:ok, params}, ""), do: {:ok, params}
  defp maybe_put_model({:ok, params}, model), do: {:ok, Map.put(params, "model", model)}

  defp compact_prompt_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp compact_prompt_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp compact_prompt_value(%Date{} = value), do: Date.to_iso8601(value)
  defp compact_prompt_value(%Time{} = value), do: Time.to_iso8601(value)
  defp compact_prompt_value(%{__struct__: _struct} = value), do: inspect(value)

  defp compact_prompt_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} ->
      key = to_string(key)
      {key, compact_prompt_value(key, nested)}
    end)
    |> Map.new()
    |> compact_map()
  end

  defp compact_prompt_value(value) when is_list(value),
    do: Enum.map(value, &compact_prompt_value/1)

  defp compact_prompt_value(value), do: normalize_json_value(value)

  defp compact_prompt_value(key, value) when is_binary(value) do
    value
    |> String.trim()
    |> truncate_string(prompt_string_limit(key))
  end

  defp compact_prompt_value(_key, value), do: compact_prompt_value(value)

  defp prompt_string_limit(key)
       when key in [
              "body",
              "body_excerpt",
              "content",
              "description",
              "excerpt",
              "notes",
              "summary",
              "text_body"
            ],
       do: @prompt_long_string_chars

  defp prompt_string_limit(_key), do: @prompt_string_chars

  defp truncate_string(value, limit) when is_binary(value) and is_integer(limit) do
    if String.length(value) > limit do
      String.slice(value, 0, limit) <> " [truncated]"
    else
      value
    end
  end

  defp serialize_person(%Person{} = person) do
    %{
      id: person.id,
      display_name: person.display_name,
      first_name: person.first_name,
      last_name: person.last_name,
      contact_details: person.contact_details || %{},
      preferred_communication_method: person.preferred_communication_method,
      relationship: person.relationship,
      communication_frequency: person.communication_frequency,
      interaction_count: person.interaction_count,
      relationship_strength: person.relationship_strength,
      affinity_score: person.affinity_score,
      last_interaction_at: person.last_interaction_at,
      notes: person.notes
    }
    |> compact_map()
  end

  defp serialize_memory(%Item{} = item) do
    %{
      id: item.id,
      kind: item.kind,
      title: item.title,
      summary: item.summary,
      tags: item.tags,
      importance: item.importance,
      confidence: item.confidence
    }
    |> compact_map()
  end

  defp serialize_link(%PersonLink{} = link) do
    %{
      id: link.id,
      person_id: link.person_id,
      resource_type: link.resource_type,
      resource_id: link.resource_id,
      title: link.title
    }
    |> compact_map()
  end

  defp error(type, attrs, reason) do
    %{
      type: type,
      target:
        read_string(attrs, "display_name", nil) ||
          read_string(attrs, "title", nil) ||
          read_string(attrs, "resource_id", nil),
      reason: inspect(reason)
    }
    |> compact_map()
  end

  defp required_string(attrs, key) do
    case read_string(attrs, key, nil) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :"missing_#{key}"}
    end
  end

  defp read_string(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      value when is_integer(value) ->
        Integer.to_string(value)

      _other ->
        default
    end
  end

  defp read_integer(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_float(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value / 1

      value when is_binary(value) ->
        case Float.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_list(attrs, key) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_list(value) -> value
      nil -> []
      value -> [value]
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(attrs, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _other ->
            nil
        end)
    end
  end

  defp normalize_lookup(value) when is_binary(value),
    do: value |> String.downcase() |> String.trim()

  defp normalize_lookup(value), do: value |> to_string() |> normalize_lookup()

  defp normalize_map(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), nested} end)
  end

  defp normalize_map(_value), do: %{}

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
    Map.reject(map, fn {_key, value} -> value in [nil, "", [], %{}] end)
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false
end
