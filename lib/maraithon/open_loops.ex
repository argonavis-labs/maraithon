defmodule Maraithon.OpenLoops do
  @moduledoc """
  Durable open-loop operating layer.

  This context combines model-deduped todos, CRM relationships, and deep memory
  into a compact user-scoped state snapshot for agents and tools.
  """

  alias Maraithon.Crm
  alias Maraithon.Crm.{Person, PersonLink}
  alias Maraithon.Memory
  alias Maraithon.Memory.Item
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  @default_limit 12
  @max_limit 50
  @prompt_limit 8
  @open_statuses ~w(open snoozed)
  @open_loop_tool_names ~w(get_open_loops list_todos upsert_todos resolve_todo list_people get_relationship_context learn_relationship_context recall_memory write_memory record_memory_feedback)
  @read_key_atoms %{
    "contact_details" => :contact_details,
    "contacts" => :contacts,
    "crm_people" => :crm_people,
    "crm_person" => :crm_person,
    "dedupe_key" => :dedupe_key,
    "display_name" => :display_name,
    "email" => :email,
    "emails" => :emails,
    "first_name" => :first_name,
    "id" => :id,
    "last_name" => :last_name,
    "memories" => :memories,
    "memory" => :memory,
    "relationship_memories" => :relationship_memories,
    "relationship_memory" => :relationship_memory,
    "metadata" => :metadata,
    "people" => :people,
    "person" => :person,
    "person_id" => :person_id,
    "phone" => :phone,
    "phone_number" => :phone_number,
    "phones" => :phones,
    "preferred_communication_method" => :preferred_communication_method,
    "preferred_method" => :preferred_method,
    "preferred_method_of_communication" => :preferred_method_of_communication,
    "relationship" => :relationship,
    "relationship_note" => :relationship_note,
    "slack_id" => :slack_id,
    "slack_ids" => :slack_ids,
    "telegram_id" => :telegram_id,
    "telegram_ids" => :telegram_ids,
    "todo_relationship_note" => :todo_relationship_note
  }
  @person_identity_fields ~w(person_id id first_name last_name display_name contact_details contacts email emails phone phone_number phones slack_id slack_ids telegram_id telegram_ids preferred_communication_method preferred_method preferred_method_of_communication relationship)

  def snapshot(user_id, opts \\ [])

  def snapshot(user_id, opts) when is_binary(user_id) do
    opts = normalize_opts(opts)
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit(1, @max_limit)
    now = normalize_now(Keyword.get(opts, :now))
    query = opts |> Keyword.get(:query) |> normalize_text()

    todos =
      Todos.list_for_user(user_id,
        statuses: @open_statuses,
        open_due_only: false,
        limit: limit * 4
      )

    bucketed = bucket_todos(todos, now)
    people = relationship_snapshots(user_id, query, limit)

    memory =
      if include_memory?(opts) do
        memory_context(user_id, query, limit)
      else
        empty_memory_context()
      end

    %{
      source: "maraithon_open_loops",
      generated_at: DateTime.to_iso8601(now),
      query: query,
      totals: totals(bucketed, people, memory),
      buckets: trim_buckets(bucketed, limit),
      people: people,
      memory: memory
    }
  end

  def snapshot(_user_id, _opts), do: empty_snapshot()

  def ingest_todos(user_id, candidates, opts \\ [])

  def ingest_todos(user_id, candidates, opts)
      when is_binary(user_id) and is_list(candidates) and is_list(opts) do
    normalized_candidates =
      candidates
      |> Enum.filter(&is_map/1)
      |> Enum.map(&stringify_top_level_keys/1)

    case Todos.ingest_many(user_id, normalized_candidates, opts) do
      {:ok, result} ->
        enrichment = enrich_persisted_todos(user_id, normalized_candidates, result, opts)
        {:ok, Map.put(result, :enrichment, enrichment)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def ingest_todos(_user_id, _candidates, _opts), do: {:error, :invalid_todo_candidates}

  def enrich_existing_todos(user_id, todos, candidates, opts \\ [])

  def enrich_existing_todos(user_id, todos, candidates, opts)
      when is_binary(user_id) and is_list(todos) and is_list(candidates) and is_list(opts) do
    todos = Enum.filter(todos, &match?(%Todo{}, &1))
    normalized_candidates = Enum.map(candidates, &stringify_top_level_keys/1)

    decisions =
      todos
      |> Enum.with_index()
      |> Enum.map(fn {todo, index} ->
        %{persisted_todo_id: todo.id, candidate_index: index}
      end)

    result = %{todos: todos, decisions: decisions}
    enrich_persisted_todos(user_id, normalized_candidates, result, opts)
  end

  def enrich_existing_todos(_user_id, _todos, _candidates, _opts) do
    %{person_links: [], memories: [], errors: []}
  end

  def enrich_context(context) when is_map(context) do
    user_id = Map.get(context, :user_id) || Map.get(context, "user_id")

    if is_binary(user_id) and String.trim(user_id) != "" do
      query = context_query(context)

      context
      |> Map.put_new(
        :open_loops,
        snapshot(user_id, query: query, limit: @prompt_limit, include_memory?: false)
      )
      |> Map.put_new(:open_loop_tools, @open_loop_tool_names)
    else
      context
    end
  end

  def enrich_context(context), do: context

  def render_prompt_section(user_id, opts \\ [])

  def render_prompt_section(user_id, opts) when is_binary(user_id) do
    snapshot = snapshot(user_id, opts)
    totals = Map.get(snapshot, :totals, %{})

    if Map.get(totals, :open_todos, 0) == 0 and Map.get(totals, :people_with_open_todos, 0) == 0 do
      ""
    else
      """
      ## Open Loops
      These are durable todos and relationship-linked commitments. Use the open-loop tools when work may need to be created, refreshed, resolved, linked to a person, or recalled.

      #{format_buckets(Map.get(snapshot, :buckets, %{}))}

      #{format_people(Map.get(snapshot, :people, []))}
      """
      |> String.trim()
    end
  end

  def render_prompt_section(_user_id, _opts), do: ""

  def inject_llm_params(params, user_id, opts \\ [])

  def inject_llm_params(params, user_id, opts) when is_map(params) and is_binary(user_id) do
    section =
      user_id
      |> render_prompt_section(opts)
      |> normalize_text()

    if section do
      Map.update(params, "messages", [%{"role" => "user", "content" => section}], fn messages ->
        inject_open_loop_message(messages, section)
      end)
    else
      params
    end
  end

  def inject_llm_params(params, _user_id, _opts), do: params

  defp enrich_persisted_todos(user_id, candidates, result, opts) do
    todos_by_id = Map.new(result.todos || [], &{&1.id, &1})
    source = Keyword.get(opts, :source, "open_loops")

    base = %{
      person_links: [],
      memories: [],
      errors: []
    }

    result.decisions
    |> Enum.reduce(base, fn decision, acc ->
      todo_id = Map.get(decision, :persisted_todo_id) || Map.get(decision, "persisted_todo_id")

      candidate_index =
        Map.get(decision, :candidate_index) || Map.get(decision, "candidate_index")

      todo = todo_id && Map.get(todos_by_id, todo_id)
      candidate = if is_integer(candidate_index), do: Enum.at(candidates, candidate_index)

      case {todo, candidate} do
        {%Todo{} = todo, candidate} when is_map(candidate) ->
          acc
          |> enrich_people(user_id, todo, candidate, candidate_index)
          |> enrich_memories(user_id, todo, candidate, candidate_index, source)

        _other ->
          acc
      end
    end)
    |> reverse_enrichment()
  end

  defp enrich_people(acc, user_id, %Todo{} = todo, candidate, candidate_index) do
    candidate
    |> explicit_people(todo)
    |> Enum.reduce(acc, fn person_attrs, acc ->
      case resolve_or_upsert_person(user_id, person_attrs) do
        {:ok, %Person{} = person} ->
          attach_person_to_todo(acc, user_id, person, todo, person_attrs, candidate_index)

        {:error, reason} ->
          add_enrichment_error(acc, candidate_index, "person", reason)
      end
    end)
  end

  defp enrich_memories(acc, user_id, %Todo{} = todo, candidate, candidate_index, source) do
    candidate
    |> explicit_memories(todo)
    |> Enum.reduce(acc, fn memory_attrs, acc ->
      memory_attrs = memory_attrs_for_todo(memory_attrs, todo, candidate_index, source)

      case Memory.write(user_id, memory_attrs, source: source) do
        {:ok, %Item{} = item} ->
          update_in(
            acc.memories,
            &[
              %{
                todo_id: todo.id,
                memory_id: item.id,
                candidate_index: candidate_index,
                title: item.title
              }
              | &1
            ]
          )

        {:error, reason} ->
          add_enrichment_error(acc, candidate_index, "memory", reason)
      end
    end)
  end

  defp attach_person_to_todo(
         acc,
         user_id,
         %Person{} = person,
         %Todo{} = todo,
         person_attrs,
         index
       ) do
    attrs = %{
      "resource_type" => "todo",
      "resource_id" => todo.id,
      "resource_source" => todo.source,
      "title" => todo.title,
      "summary" => todo.summary,
      "relationship_note" => relationship_note(person_attrs),
      "metadata" =>
        %{
          "source" => "open_loop_enrichment",
          "candidate_index" => index,
          "todo_source" => todo.source
        }
        |> compact_map()
    }

    case Crm.attach_resource(user_id, person.id, attrs) do
      {:ok, %PersonLink{} = link} ->
        update_in(
          acc.person_links,
          &[
            %{
              todo_id: todo.id,
              person_id: person.id,
              person_name: person.display_name,
              link_id: link.id,
              candidate_index: index
            }
            | &1
          ]
        )

      {:error, reason} ->
        add_enrichment_error(acc, index, "person_link", reason)
    end
  end

  defp resolve_or_upsert_person(user_id, attrs) do
    attrs = stringify_top_level_keys(attrs)
    person_id = read_string(attrs, "person_id", nil) || read_string(attrs, "id", nil)

    cond do
      is_binary(person_id) ->
        case Crm.get_person_for_user(user_id, person_id) do
          %Person{} = person -> {:ok, person}
          nil -> {:error, :person_not_found}
        end

      structured_person_attrs?(attrs) ->
        Crm.upsert_person(user_id, attrs)

      true ->
        {:error, :missing_person_identity}
    end
  end

  defp explicit_people(candidate) do
    metadata = read_map(candidate, "metadata")

    [
      fetch_attr(candidate, "person"),
      fetch_attr(candidate, "people"),
      fetch_attr(candidate, "crm_person"),
      fetch_attr(candidate, "crm_people"),
      fetch_attr(metadata, "person"),
      fetch_attr(metadata, "people"),
      fetch_attr(metadata, "crm_person"),
      fetch_attr(metadata, "crm_people")
    ]
    |> Enum.flat_map(&listify/1)
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_top_level_keys/1)
  end

  defp explicit_people(candidate, %Todo{} = todo) do
    [candidate, %{"metadata" => todo.metadata || %{}}]
    |> Enum.flat_map(&explicit_people/1)
    |> Enum.uniq_by(&inspect/1)
  end

  defp explicit_memories(candidate) do
    metadata = read_map(candidate, "metadata")

    [
      fetch_attr(candidate, "memory"),
      fetch_attr(candidate, "memories"),
      fetch_attr(candidate, "relationship_memory"),
      fetch_attr(candidate, "relationship_memories"),
      fetch_attr(metadata, "memory"),
      fetch_attr(metadata, "memories"),
      fetch_attr(metadata, "relationship_memory"),
      fetch_attr(metadata, "relationship_memories")
    ]
    |> Enum.flat_map(&listify/1)
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_top_level_keys/1)
  end

  defp explicit_memories(candidate, %Todo{} = todo) do
    [candidate, %{"metadata" => todo.metadata || %{}}]
    |> Enum.flat_map(&explicit_memories/1)
    |> Enum.uniq_by(&inspect/1)
  end

  defp memory_attrs_for_todo(attrs, %Todo{} = todo, candidate_index, source) do
    metadata =
      attrs
      |> read_map("metadata")
      |> Map.merge(%{
        "source" => "open_loop_enrichment",
        "candidate_index" => candidate_index,
        "todo_id" => todo.id,
        "todo_title" => todo.title
      })
      |> compact_map()

    attrs
    |> Map.put_new("source", source)
    |> Map.put_new("source_ref_type", "todo")
    |> Map.put_new("source_ref_id", todo.id)
    |> Map.put_new("author_type", "model")
    |> Map.put("metadata", metadata)
  end

  defp structured_person_attrs?(attrs) do
    Enum.any?(@person_identity_fields, fn field ->
      present?(fetch_attr(attrs, field))
    end)
  end

  defp relationship_snapshots(user_id, query, limit) do
    focused_people =
      if query do
        Crm.list_people(user_id, query: query, limit: limit)
      else
        []
      end

    focused_ids = MapSet.new(focused_people, & &1.id)

    people =
      (focused_people ++ Crm.list_people(user_id, limit: max(limit * 3, 25)))
      |> Enum.uniq_by(& &1.id)

    user_id
    |> Crm.relationship_contexts(people, link_limit: 12)
    |> Enum.filter(fn context ->
      context.open_todo_count > 0 or MapSet.member?(focused_ids, context.person.id)
    end)
    |> Enum.map(&serialize_relationship_context/1)
    |> Enum.take(limit)
  end

  defp memory_context(user_id, query, limit) do
    recall_query =
      query ||
        "open loops todos commitments people relationships relevance feedback preferences"

    try do
      Memory.prompt_context(user_id, query: recall_query, limit: min(limit, @prompt_limit))
    rescue
      _error -> empty_memory_context()
    catch
      _kind, _reason -> empty_memory_context()
    end
  end

  defp bucket_todos(todos, now) do
    base = %{
      overdue: [],
      today: [],
      upcoming: [],
      no_due_date: [],
      monitor: [],
      snoozed: []
    }

    Enum.reduce(todos, base, fn todo, acc ->
      bucket = todo_bucket(todo, now)
      Map.update!(acc, bucket, &[serialize_todo(todo) | &1])
    end)
    |> Map.new(fn {bucket, todos} -> {bucket, Enum.reverse(todos)} end)
  end

  defp todo_bucket(%Todo{status: "snoozed", snoozed_until: %DateTime{} = snoozed_until}, now) do
    if DateTime.compare(snoozed_until, now) == :gt, do: :snoozed, else: :upcoming
  end

  defp todo_bucket(%Todo{attention_mode: "monitor"}, _now), do: :monitor
  defp todo_bucket(%Todo{due_at: nil}, _now), do: :no_due_date

  defp todo_bucket(%Todo{due_at: %DateTime{} = due_at}, now) do
    today = DateTime.to_date(now)

    case Date.compare(DateTime.to_date(due_at), today) do
      :lt -> :overdue
      :eq -> :today
      :gt -> :upcoming
    end
  end

  defp todo_bucket(_todo, _now), do: :no_due_date

  defp trim_buckets(bucketed, limit) do
    Map.new(bucketed, fn {bucket, todos} -> {bucket, Enum.take(todos, limit)} end)
  end

  defp totals(bucketed, people, memory) do
    %{
      open_todos: Enum.reduce(bucketed, 0, fn {_bucket, todos}, acc -> acc + length(todos) end),
      overdue: bucketed |> Map.get(:overdue, []) |> length(),
      due_today: bucketed |> Map.get(:today, []) |> length(),
      upcoming: bucketed |> Map.get(:upcoming, []) |> length(),
      no_due_date: bucketed |> Map.get(:no_due_date, []) |> length(),
      monitor: bucketed |> Map.get(:monitor, []) |> length(),
      snoozed: bucketed |> Map.get(:snoozed, []) |> length(),
      people_with_open_todos:
        Enum.count(people, fn person -> Map.get(person, :open_todo_count, 0) > 0 end),
      recalled_memories: Map.get(memory, :count, 0)
    }
  end

  defp serialize_relationship_context(%{
         person: %Person{} = person,
         links: links,
         todos: todos,
         open_todo_count: open_todo_count
       }) do
    %{
      person: serialize_person(person),
      open_todo_count: open_todo_count,
      link_count: length(links),
      todos:
        todos
        |> Enum.filter(&(&1.status in @open_statuses))
        |> Enum.map(&serialize_todo/1)
    }
  end

  defp serialize_person(%Person{} = person) do
    %{
      id: person.id,
      first_name: person.first_name,
      last_name: person.last_name,
      display_name: person.display_name,
      contact_details: person.contact_details || %{},
      preferred_communication_method: person.preferred_communication_method,
      relationship: person.relationship,
      communication_frequency: person.communication_frequency,
      interaction_count: person.interaction_count,
      relationship_strength: person.relationship_strength,
      affinity_score: person.affinity_score,
      last_interaction_at: person.last_interaction_at,
      notes: person.notes,
      metadata: person.metadata || %{},
      updated_at: person.updated_at
    }
  end

  defp serialize_todo(%Todo{} = todo) do
    %{
      id: todo.id,
      source: todo.source,
      source_account_id: todo.source_account_id,
      source_account_label: todo.source_account_label,
      kind: todo.kind,
      attention_mode: todo.attention_mode,
      status: todo.status,
      title: todo.title,
      summary: todo.summary,
      next_action: todo.next_action,
      due_at: todo.due_at,
      snoozed_until: todo.snoozed_until,
      notes: todo.notes,
      action_plan: todo.action_plan,
      action_draft: todo.action_draft || %{},
      owner_user_id: todo.owner_user_id,
      owner_label: todo.owner_label,
      priority: todo.priority,
      source_item_id: todo.source_item_id,
      source_occurred_at: todo.source_occurred_at,
      metadata: todo.metadata || %{},
      updated_at: todo.updated_at
    }
  end

  defp format_buckets(buckets) do
    [
      format_bucket("Overdue", Map.get(buckets, :overdue, [])),
      format_bucket("Due Today", Map.get(buckets, :today, [])),
      format_bucket("Upcoming", Map.get(buckets, :upcoming, [])),
      format_bucket("No Due Date", Map.get(buckets, :no_due_date, [])),
      format_bucket("Monitor", Map.get(buckets, :monitor, [])),
      format_bucket("Snoozed", Map.get(buckets, :snoozed, []))
    ]
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "No open todos."
      sections -> Enum.join(sections, "\n")
    end
  end

  defp format_bucket(_label, []), do: ""

  defp format_bucket(label, todos) do
    rendered =
      todos
      |> Enum.take(@prompt_limit)
      |> Enum.map_join("\n", fn todo ->
        due = if todo.due_at, do: " due #{DateTime.to_iso8601(todo.due_at)}", else: ""
        "- #{todo.title}#{due}: #{todo.next_action}"
      end)

    "#{label}:\n#{rendered}"
  end

  defp format_people([]), do: "No relationship-linked open todos."

  defp format_people(people) do
    rendered =
      people
      |> Enum.take(@prompt_limit)
      |> Enum.map_join("\n", fn person_context ->
        person = person_context.person
        name = person.display_name || person.first_name || person.id
        "- #{name}: #{person_context.open_todo_count} open linked todo(s)"
      end)

    "People:\n#{rendered}"
  end

  defp inject_open_loop_message(messages, section) when is_list(messages) do
    memory_message = %{"role" => "system", "content" => section}

    case messages do
      [%{"role" => "system", "content" => content} = system | rest] when is_binary(content) ->
        [Map.put(system, "content", content <> "\n\n" <> section) | rest]

      _other ->
        [memory_message | messages]
    end
  end

  defp inject_open_loop_message(_messages, section),
    do: [%{"role" => "system", "content" => section}]

  defp read_map(attrs, key) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_map(value) -> stringify_top_level_keys(value)
      _other -> %{}
    end
  end

  defp read_string(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
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
        case Map.get(@read_key_atoms, key) do
          atom_key when is_atom(atom_key) -> Map.get(attrs, atom_key)
          _other -> nil
        end
    end
  end

  defp listify(nil), do: []
  defp listify(value) when is_list(value), do: value
  defp listify(value), do: [value]

  defp stringify_top_level_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp compact_map(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, "", [], %{}] end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(value) when is_map(value), do: value != %{}
  defp present?(_value), do: false

  defp relationship_note(attrs) do
    read_string(attrs, "relationship_note", nil) ||
      read_string(attrs, "todo_relationship_note", nil)
  end

  defp add_enrichment_error(acc, candidate_index, type, reason) do
    update_in(
      acc.errors,
      &[
        %{
          candidate_index: candidate_index,
          type: type,
          reason: inspect(reason)
        }
        | &1
      ]
    )
  end

  defp reverse_enrichment(enrichment) do
    %{
      person_links: Enum.reverse(enrichment.person_links),
      memories: Enum.reverse(enrichment.memories),
      errors: Enum.reverse(enrichment.errors)
    }
  end

  defp context_query(context) do
    [
      Map.get(context, :message),
      Map.get(context, "message"),
      Map.get(context, :last_message),
      Map.get(context, "last_message"),
      Map.get(context, :current_message),
      Map.get(context, "current_message")
    ]
    |> Enum.find_value(&normalize_text/1)
  end

  defp normalize_opts(opts) when is_list(opts), do: opts

  defp normalize_opts(opts) when is_map(opts) do
    Enum.reduce(opts, [], fn {key, value}, acc ->
      key =
        case key do
          key when is_atom(key) -> key
          "include_memory" -> :include_memory?
          "include_memory?" -> :include_memory?
          "limit" -> :limit
          "query" -> :query
          "now" -> :now
          _other -> nil
        end

      if is_nil(key), do: acc, else: Keyword.put(acc, key, value)
    end)
  end

  defp normalize_opts(_opts), do: []

  defp include_memory?(opts),
    do: Keyword.get(opts, :include_memory?, true) not in [false, "false", 0, "0"]

  defp normalize_now(%DateTime{} = now), do: now

  defp normalize_now(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, now, _offset} -> now
      _other -> DateTime.utc_now()
    end
  end

  defp normalize_now(_value), do: DateTime.utc_now()

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_value), do: nil

  defp clamp_limit(value, min_value, max_value) when is_integer(value) do
    value |> max(min_value) |> min(max_value)
  end

  defp clamp_limit(value, min_value, max_value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> clamp_limit(parsed, min_value, max_value)
      _other -> min_value
    end
  end

  defp clamp_limit(_value, min_value, _max_value), do: min_value

  defp empty_snapshot do
    %{
      source: "maraithon_open_loops",
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      query: nil,
      totals: %{
        open_todos: 0,
        overdue: 0,
        due_today: 0,
        upcoming: 0,
        no_due_date: 0,
        monitor: 0,
        snoozed: 0,
        people_with_open_todos: 0,
        recalled_memories: 0
      },
      buckets: %{overdue: [], today: [], upcoming: [], no_due_date: [], monitor: [], snoozed: []},
      people: [],
      memory: empty_memory_context()
    }
  end

  defp empty_memory_context, do: %{summary: nil, memories: [], count: 0}
end
