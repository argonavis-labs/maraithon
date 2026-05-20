defmodule Maraithon.Memory do
  @moduledoc """
  Deep durable memory for users and system agents.

  This is the general-purpose memory layer. PreferenceMemory and UserMemory keep
  specialized summaries and policy rules; this module stores addressable memory
  items that tools, MCP clients, runtime agents, and model prompts can write and
  recall directly.
  """

  import Ecto.Query

  alias Maraithon.Memory.{Event, Intelligence, Item, Recall}
  alias Maraithon.Repo

  @default_limit 12
  @candidate_limit 80
  @prompt_limit 8
  @memory_tool_names ~w(write_memory recall_memory list_memories forget_memory record_memory_feedback update_memory_confidence)
  @read_key_atoms %{
    "author_type" => :author_type,
    "confidence" => :confidence,
    "content" => :content,
    "decay_at" => :decay_at,
    "dedupe_key" => :dedupe_key,
    "feedback" => :feedback,
    "id" => :id,
    "importance" => :importance,
    "memory_id" => :memory_id,
    "metadata" => :metadata,
    "polarity" => :polarity,
    "reason" => :reason,
    "resource_id" => :resource_id,
    "resource_type" => :resource_type,
    "source" => :source,
    "source_ref_id" => :source_ref_id,
    "source_ref_type" => :source_ref_type,
    "subject" => :subject,
    "superseded_by_id" => :superseded_by_id,
    "supersedes_id" => :supersedes_id,
    "title" => :title,
    "type" => :type
  }

  def list_items(user_id, opts \\ [])

  def list_items(user_id, opts) when is_binary(user_id) do
    query_text = Keyword.get(opts, :query)
    limit = result_limit(opts, @default_limit)
    fetch_limit = overfetch_limit(query_text, limit)

    Item
    |> where([item], item.user_id == ^user_id)
    |> maybe_filter_status(Keyword.get(opts, :status, "active"))
    |> maybe_filter_kind(Keyword.get(opts, :kind))
    |> maybe_filter_scope(Keyword.get(opts, :scope))
    |> maybe_filter_tag(Keyword.get(opts, :tag))
    |> maybe_filter_source_ref(
      Keyword.get(opts, :source_ref_type),
      Keyword.get(opts, :source_ref_id)
    )
    |> where_not_expired()
    |> order_by([item], desc: item.importance, desc: item.updated_at, desc: item.inserted_at)
    |> limit(^fetch_limit)
    |> Repo.all()
    |> filter_items_by_text(query_text)
    |> Enum.take(limit)
  end

  def list_items(_user_id, _opts), do: []

  def get_item_for_user(user_id, memory_id) when is_binary(user_id) and is_binary(memory_id) do
    Repo.get_by(Item, id: memory_id, user_id: user_id)
  end

  def get_item_for_user(_user_id, _memory_id), do: nil

  def write(user_id, attrs, opts \\ [])

  def write(user_id, attrs, opts) when is_binary(user_id) and is_map(attrs) do
    attrs =
      attrs
      |> memory_attrs()
      |> Map.put("user_id", user_id)

    source = read_string(attrs, "source", Keyword.get(opts, :source, "tool"))
    supersedes_id = read_string(attrs, "supersedes_id", nil)

    if supersedes_id do
      supersede(user_id, attrs, supersedes_id, source: source)
    else
      Repo.transaction(fn ->
        {item, event_type} =
          case resolve_write_target(user_id, attrs) do
            %Item{} = existing ->
              item =
                existing
                |> Item.changeset(Map.put(attrs, "source", source))
                |> repo_write_or_rollback()

              {item, "updated"}

            nil ->
              item =
                %Item{user_id: user_id}
                |> Item.changeset(Map.put(attrs, "source", source))
                |> repo_insert_or_rollback()

              {item, "written"}
          end

        log_event!(user_id, item.id, event_type, source, %{
          "memory" => serialize_item(item),
          "source" => source
        })

        item
      end)
    end
  end

  def write(_user_id, _attrs, _opts), do: {:error, :invalid_memory_attrs}

  def supersede(user_id, attrs, supersedes_id, opts \\ [])

  def supersede(user_id, attrs, supersedes_id, opts)
      when is_binary(user_id) and is_map(attrs) and is_binary(supersedes_id) do
    attrs =
      attrs
      |> memory_attrs()
      |> Map.put("supersedes_id", supersedes_id)

    source = read_string(attrs, "source", Keyword.get(opts, :source, "tool"))
    new_id = Ecto.UUID.generate()

    Repo.transaction(fn ->
      case Repo.get_by(Item, id: supersedes_id, user_id: user_id) do
        %Item{status: "active"} = previous ->
          superseded =
            previous
            |> Item.changeset(%{"status" => "superseded"})
            |> repo_write_or_rollback()

          item =
            %Item{id: new_id, user_id: user_id}
            |> Item.changeset(Map.put(attrs, "source", source))
            |> repo_insert_or_rollback()

          _previous =
            superseded
            |> Item.changeset(%{"superseded_by_id" => item.id})
            |> repo_write_or_rollback()

          log_event!(user_id, previous.id, "superseded", source, %{
            "superseded_by_id" => item.id,
            "memory" => serialize_item(previous)
          })

          log_event!(user_id, item.id, "written", source, %{
            "supersedes_id" => previous.id,
            "memory" => serialize_item(item),
            "source" => source
          })

          item

        %Item{} = previous ->
          Repo.rollback({:memory_not_active, previous.status})

        nil ->
          Repo.rollback(:memory_not_found)
      end
    end)
  end

  def supersede(_user_id, _attrs, _supersedes_id, _opts), do: {:error, :invalid_memory_attrs}

  def update_confidence(user_id, memory_id, confidence, opts \\ [])

  def update_confidence(user_id, memory_id, confidence, opts)
      when is_binary(user_id) and is_binary(memory_id) do
    source = Keyword.get(opts, :source, "tool")
    reason = Keyword.get(opts, :reason)

    with %Item{} = item <- get_item_for_user(user_id, memory_id),
         {:ok, updated} <- item |> Item.changeset(%{"confidence" => confidence}) |> Repo.update() do
      log_event(user_id, updated.id, "confidence_updated", source, %{
        "previous_confidence" => item.confidence,
        "confidence" => updated.confidence,
        "reason" => reason
      })

      {:ok, updated}
    else
      nil -> {:error, :memory_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_confidence(_user_id, _memory_id, _confidence, _opts),
    do: {:error, :invalid_memory_id}

  def record_relevance_feedback(user_id, attrs, opts \\ [])

  def record_relevance_feedback(user_id, attrs, opts) when is_binary(user_id) and is_map(attrs) do
    feedback =
      attrs
      |> read_string("feedback", attrs |> read_string("polarity", "relevant"))
      |> normalize_feedback()

    subject =
      read_string(attrs, "subject", nil) ||
        read_string(attrs, "content", nil) ||
        read_string(attrs, "title", "an item")

    reason = read_string(attrs, "reason", nil)
    resource_type = read_string(attrs, "resource_type", nil)
    resource_id = read_string(attrs, "resource_id", nil)
    source = read_string(attrs, "source", Keyword.get(opts, :source, "tool"))

    content =
      [
        "The user marked #{subject} as #{feedback}.",
        if(reason, do: "Reason: #{reason}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    polarity = if feedback == "not_relevant", do: "negative", else: "positive"

    memory_attrs =
      attrs
      |> Map.merge(%{
        "kind" => "relevance_feedback",
        "title" => "Relevance feedback: #{String.slice(subject, 0, 120)}",
        "content" => content,
        "summary" => content,
        "source" => source,
        "source_ref_type" => resource_type,
        "source_ref_id" => resource_id,
        "author_type" => read_string(attrs, "author_type", "user"),
        "polarity" => polarity,
        "importance" => read_integer(attrs, "importance", 75),
        "confidence" => read_float(attrs, "confidence", 0.9),
        "tags" => normalize_tags(Map.get(attrs, "tags")) ++ ["relevance", feedback],
        "metadata" =>
          attrs
          |> read_map("metadata", %{})
          |> Map.merge(%{
            "feedback" => feedback,
            "subject" => subject,
            "reason" => reason
          })
      })
      |> maybe_put_dedupe_key(
        "relevance_feedback:#{feedback}:#{resource_type}:#{resource_id}:#{subject}"
      )

    case write(user_id, memory_attrs, source: source) do
      {:ok, %Item{} = item} ->
        log_event(user_id, item.id, "feedback_recorded", source, %{
          "feedback" => feedback,
          "subject" => subject,
          "resource_type" => resource_type,
          "resource_id" => resource_id
        })

        {:ok, item}

      other ->
        other
    end
  end

  def record_relevance_feedback(_user_id, _attrs, _opts), do: {:error, :invalid_feedback_attrs}

  def recall(user_id, query, opts \\ [])

  def recall(user_id, query, opts) when is_binary(user_id) do
    query = normalize_optional_text(query) || ""

    recall_opts =
      opts
      |> Keyword.put(:query, query)
      |> Keyword.put_new(:candidate_limit, @candidate_limit)

    {:ok, candidates, recall_metadata} = Recall.recall(user_id, recall_opts)
    serialized_candidates = Enum.map(candidates, &serialize_item/1)

    case Intelligence.select_relevant(user_id, query, serialized_candidates, opts) do
      {:ok, %{items: recalled} = model_result} ->
        touch(user_id, recalled)

        {:ok,
         %{
           query: query,
           count: length(recalled),
           summary: Map.get(model_result, :summary) || recall_summary(query, recalled),
           memories: recalled,
           recall: recall_metadata,
           selection_source: "memory_intelligence"
         }}

      {:error, reason} ->
        {:error, {:memory_intelligence_failed, reason}}
    end
  end

  def recall(_user_id, _query, _opts), do: {:error, :invalid_user}

  def forget(user_id, memory_id_or_query, opts \\ [])

  def forget(user_id, memory_id_or_query, opts)
      when is_binary(user_id) and is_binary(memory_id_or_query) do
    with %Item{} = item <- resolve_item(user_id, memory_id_or_query) do
      source = Keyword.get(opts, :source, "tool")
      status = Keyword.get(opts, :status, "archived")

      case item |> Item.changeset(%{status: status}) |> Repo.update() do
        {:ok, updated} ->
          log_event(user_id, updated.id, status_event_type(status), source, %{
            "previous_status" => item.status,
            "status" => status
          })

          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :memory_not_found}
    end
  end

  def forget(_user_id, _memory_id_or_query, _opts), do: {:error, :invalid_memory_id}

  def prompt_context(user_id, opts \\ [])

  def prompt_context(user_id, opts) when is_binary(user_id) do
    query = Keyword.get(opts, :query) |> normalize_optional_text()
    limit = result_limit(opts, @prompt_limit)

    {memories, recall_error} =
      case Recall.recall(user_id, Keyword.merge(opts, query: query || "", limit: limit)) do
        {:ok, items, _metadata} ->
          touch(user_id, items)
          {Enum.map(items, &serialize_item/1), nil}

        {:error, reason} ->
          {[], inspect(reason)}
      end

    %{
      summary: memory_summary(memories, recall_error),
      memories: memories,
      count: length(memories),
      error: recall_error
    }
  end

  def prompt_context(_user_id, _opts), do: empty_prompt_context()

  def enrich_context(context) when is_map(context) do
    user_id = Map.get(context, :user_id) || Map.get(context, "user_id")

    if is_binary(user_id) and String.trim(user_id) != "" do
      query = context_query(context)

      context
      |> Map.put(:deep_memory, prompt_context(user_id, query: query, limit: @prompt_limit))
      |> Map.put_new(:memory_tools, @memory_tool_names)
    else
      context
    end
  end

  def enrich_context(context), do: context

  def render_prompt_section(user_id, opts \\ [])

  def render_prompt_section(user_id, opts) when is_binary(user_id) do
    context = prompt_context(user_id, opts)
    memories = Map.get(context, :memories, [])

    if memories == [] do
      ""
    else
      rendered =
        memories
        |> Enum.take(@prompt_limit)
        |> Enum.map_join("\n", fn memory ->
          "- [#{memory.kind}/#{memory.polarity}] #{memory.title}: #{memory.summary || memory.content}"
        end)

      """
      ## Relevant memories
      These are durable user/system memories. Treat them as steering context, not as one-off chat history.
      Use memory tools when you need more recall, when the user corrects relevance, or when a durable fact should be written.

      #{rendered}
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
      |> normalize_optional_text()

    if section do
      Map.update(params, "messages", [%{"role" => "user", "content" => section}], fn messages ->
        inject_memory_message(messages, section)
      end)
    else
      params
    end
  end

  def inject_llm_params(params, _user_id, _opts), do: params

  def serialize_item(%Item{} = item) do
    %{
      id: item.id,
      status: item.status,
      kind: item.kind,
      scope: item.scope,
      title: item.title,
      content: item.content,
      summary: item.summary || item.content,
      source: item.source,
      source_ref_type: item.source_ref_type,
      source_ref_id: item.source_ref_id,
      author_type: item.author_type,
      author_id: item.author_id,
      tags: item.tags || [],
      importance: item.importance || 0,
      confidence: item.confidence || 0.0,
      polarity: item.polarity,
      metadata: item.metadata || %{},
      last_used_at: item.last_used_at,
      use_count: item.use_count || 0,
      expires_at: item.expires_at,
      decay_at: item.decay_at,
      superseded_by_id: item.superseded_by_id,
      supersedes_id: item.supersedes_id,
      inserted_at: item.inserted_at,
      updated_at: item.updated_at
    }
  end

  def serialize_item(%{} = item) do
    %{
      id: Map.get(item, :id) || Map.get(item, "id"),
      status: Map.get(item, :status) || Map.get(item, "status"),
      kind: Map.get(item, :kind) || Map.get(item, "kind"),
      scope: Map.get(item, :scope) || Map.get(item, "scope"),
      title: Map.get(item, :title) || Map.get(item, "title"),
      content: Map.get(item, :content) || Map.get(item, "content"),
      summary:
        Map.get(item, :summary) || Map.get(item, "summary") || Map.get(item, :content) ||
          Map.get(item, "content"),
      source: Map.get(item, :source) || Map.get(item, "source"),
      source_ref_type: Map.get(item, :source_ref_type) || Map.get(item, "source_ref_type"),
      source_ref_id: Map.get(item, :source_ref_id) || Map.get(item, "source_ref_id"),
      author_type: Map.get(item, :author_type) || Map.get(item, "author_type"),
      author_id: Map.get(item, :author_id) || Map.get(item, "author_id"),
      tags: Map.get(item, :tags) || Map.get(item, "tags") || [],
      importance: Map.get(item, :importance) || Map.get(item, "importance") || 0,
      confidence: Map.get(item, :confidence) || Map.get(item, "confidence") || 0.0,
      polarity: Map.get(item, :polarity) || Map.get(item, "polarity") || "neutral",
      metadata: Map.get(item, :metadata) || Map.get(item, "metadata") || %{},
      last_used_at: Map.get(item, :last_used_at) || Map.get(item, "last_used_at"),
      use_count: Map.get(item, :use_count) || Map.get(item, "use_count") || 0,
      expires_at: Map.get(item, :expires_at) || Map.get(item, "expires_at"),
      decay_at: Map.get(item, :decay_at) || Map.get(item, "decay_at"),
      superseded_by_id: Map.get(item, :superseded_by_id) || Map.get(item, "superseded_by_id"),
      supersedes_id: Map.get(item, :supersedes_id) || Map.get(item, "supersedes_id"),
      inserted_at: Map.get(item, :inserted_at) || Map.get(item, "inserted_at"),
      updated_at: Map.get(item, :updated_at) || Map.get(item, "updated_at")
    }
  end

  def serialize_item(_item), do: %{}

  defp resolve_write_target(user_id, attrs) do
    memory_id = read_string(attrs, "memory_id", nil) || read_string(attrs, "id", nil)
    dedupe_key = read_string(attrs, "dedupe_key", nil)

    cond do
      memory_id ->
        get_item_for_user(user_id, memory_id)

      dedupe_key ->
        Repo.get_by(Item, user_id: user_id, dedupe_key: dedupe_key, status: "active")

      true ->
        nil
    end
  end

  defp memory_attrs(attrs) do
    source_ref =
      case Map.get(attrs, "source_ref") || Map.get(attrs, :source_ref) do
        value when is_map(value) -> value
        _other -> %{}
      end

    attrs
    |> stringify_keys()
    |> Map.merge(%{
      "source_ref_type" =>
        read_string(attrs, "source_ref_type", nil) || read_string(source_ref, "type", nil),
      "source_ref_id" =>
        read_string(attrs, "source_ref_id", nil) || read_string(source_ref, "id", nil),
      "metadata" => read_map(attrs, "metadata", %{}),
      "tags" => normalize_tags(Map.get(attrs, "tags") || Map.get(attrs, :tags))
    })
    |> Map.put_new("status", "active")
    |> Map.put_new("kind", "fact")
    |> Map.put_new("scope", "user")
    |> Map.put_new("source", "tool")
    |> Map.put_new("author_type", "user")
    |> Map.put_new("polarity", "neutral")
    |> Map.put_new("importance", 50)
    |> Map.put_new("confidence", 0.75)
  end

  def touch(user_id, memories) when is_binary(user_id) and is_list(memories) do
    now = DateTime.utc_now()

    memory_ids =
      memories
      |> Enum.map(&(Map.get(&1, :id) || Map.get(&1, "id")))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if memory_ids != [] do
      Item
      |> where([item], item.user_id == ^user_id and item.id in ^memory_ids)
      |> Repo.update_all(
        inc: [use_count: 1],
        set: [last_used_at: now, updated_at: now]
      )

      events =
        Enum.map(memory_ids, fn memory_id ->
          %{
            id: Ecto.UUID.generate(),
            user_id: user_id,
            memory_id: memory_id,
            event_type: "recalled",
            source: "runtime",
            payload: %{},
            inserted_at: now,
            updated_at: now
          }
        end)

      Repo.insert_all(Event, events)
      :ok
    else
      :ok
    end
  end

  def touch(_user_id, _memories), do: :ok

  defp resolve_item(user_id, memory_id_or_query) do
    get_item_for_user(user_id, memory_id_or_query) ||
      Item
      |> where([item], item.user_id == ^user_id and item.status == "active")
      |> where_not_expired()
      |> order_by([item], desc: item.importance, desc: item.updated_at)
      |> limit(200)
      |> Repo.all()
      |> filter_items_by_text(memory_id_or_query)
      |> List.first()
  end

  defp log_event(user_id, memory_id, event_type, source, payload) do
    %Event{}
    |> Event.changeset(%{
      user_id: user_id,
      memory_id: memory_id,
      event_type: event_type,
      source: source || "system",
      payload: payload || %{}
    })
    |> Repo.insert()
    |> case do
      {:ok, _event} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp log_event!(user_id, memory_id, event_type, source, payload) do
    %Event{}
    |> Event.changeset(%{
      user_id: user_id,
      memory_id: memory_id,
      event_type: event_type,
      source: source || "system",
      payload: payload || %{}
    })
    |> Repo.insert!()
  end

  defp repo_insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, item} -> item
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp repo_write_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, item} -> item
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, "all"), do: query
  defp maybe_filter_status(query, status), do: where(query, [item], item.status == ^status)

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, ""), do: query
  defp maybe_filter_kind(query, kind), do: where(query, [item], item.kind == ^kind)

  defp maybe_filter_scope(query, nil), do: query
  defp maybe_filter_scope(query, ""), do: query
  defp maybe_filter_scope(query, scope), do: where(query, [item], item.scope == ^scope)

  defp maybe_filter_tag(query, nil), do: query
  defp maybe_filter_tag(query, ""), do: query
  defp maybe_filter_tag(query, tag), do: where(query, [item], ^tag in item.tags)

  defp maybe_filter_source_ref(query, nil, _source_ref_id), do: query
  defp maybe_filter_source_ref(query, "", _source_ref_id), do: query
  defp maybe_filter_source_ref(query, _source_ref_type, nil), do: query
  defp maybe_filter_source_ref(query, _source_ref_type, ""), do: query

  defp maybe_filter_source_ref(query, source_ref_type, source_ref_id) do
    where(
      query,
      [item],
      item.source_ref_type == ^source_ref_type and item.source_ref_id == ^source_ref_id
    )
  end

  defp filter_items_by_text(items, nil), do: items
  defp filter_items_by_text(items, ""), do: items

  defp filter_items_by_text(items, text) when is_binary(text) do
    needle = String.downcase(text)

    Enum.filter(items, fn item ->
      item
      |> searchable_text()
      |> String.downcase()
      |> String.contains?(needle)
    end)
  end

  defp searchable_text(%Item{} = item) do
    [
      item.title,
      item.content,
      item.summary,
      item.source,
      item.source_ref_type,
      item.source_ref_id,
      Jason.encode!(item.metadata || %{}),
      Enum.join(item.tags || [], " ")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp overfetch_limit(query_text, limit) do
    if normalize_optional_text(query_text) do
      limit
      |> Kernel.*(10)
      |> max(100)
      |> min(500)
    else
      limit
    end
  end

  defp where_not_expired(query) do
    now = DateTime.utc_now()
    where(query, [item], is_nil(item.expires_at) or item.expires_at > ^now)
  end

  defp inject_memory_message(messages, section) when is_list(messages) do
    case messages do
      [%{"role" => "system", "content" => content} = system | rest] when is_binary(content) ->
        [%{system | "content" => content <> "\n\n" <> section} | rest]

      [%{role: "system", content: content} = system | rest] when is_binary(content) ->
        [%{system | content: content <> "\n\n" <> section} | rest]

      other ->
        [%{"role" => "user", "content" => section} | other]
    end
  end

  defp inject_memory_message(_messages, section), do: [%{"role" => "user", "content" => section}]

  defp context_query(context) do
    [
      Map.get(context, :last_message),
      Map.get(context, "last_message"),
      Map.get(context, :message),
      Map.get(context, "message"),
      get_in(context, [:trigger, :message]),
      get_in(context, ["trigger", "message"])
    ]
    |> Enum.find_value(&normalize_optional_text/1)
  end

  defp memory_summary(memories, nil), do: memory_summary(memories)

  defp memory_summary(_memories, error) when is_binary(error) do
    "Deep memory recall could not run model-level relevance selection: #{error}"
  end

  defp memory_summary([]), do: "No deep durable memories matched this context."

  defp memory_summary(memories) do
    memories
    |> Enum.take(4)
    |> Enum.map_join(" ", fn memory ->
      "#{Map.get(memory, :title)}: #{Map.get(memory, :summary) || Map.get(memory, :content)}"
    end)
  end

  defp recall_summary("", memories), do: memory_summary(memories)

  defp recall_summary(query, memories),
    do: "Memory recall for #{query}: #{memory_summary(memories)}"

  defp empty_prompt_context,
    do: %{summary: "No deep durable memories yet.", memories: [], count: 0}

  defp result_limit(opts, default) do
    opts
    |> Keyword.get(:limit, default)
    |> case do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _other -> default
    end
    |> max(1)
    |> min(100)
  end

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> default
    end
  end

  defp read_string(map, key, default) when is_map(map) and is_binary(key) do
    case read_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      _other ->
        default
    end
  end

  defp read_integer(map, key, default) when is_map(map) do
    case read_value(map, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _other -> default
    end
  end

  defp read_float(map, key, default) when is_map(map) do
    case read_value(map, key) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      value when is_binary(value) -> parse_float(value, default)
      _other -> default
    end
  end

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> default
    end
  end

  defp read_map(map, key, default) when is_map(map) do
    case read_value(map, key) do
      value when is_map(value) -> value
      _other -> default
    end
  end

  defp read_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(@read_key_atoms, key) do
          {:ok, atom_key} -> Map.get(map, atom_key)
          :error -> nil
        end
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(fn
      tag when is_binary(tag) ->
        tag
        |> String.trim()
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9:_-]+/u, "_")
        |> String.trim("_")

      tag ->
        tag |> to_string() |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",", trim: true)
    |> normalize_tags()
  end

  defp normalize_tags(_tags), do: []

  defp normalize_feedback(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() |> String.replace("-", "_") do
      "not_relevant" -> "not_relevant"
      "irrelevant" -> "not_relevant"
      "not helpful" -> "not_relevant"
      "not_helpful" -> "not_relevant"
      "relevant" -> "relevant"
      "helpful" -> "relevant"
      _other -> "relevant"
    end
  end

  defp normalize_feedback(_value), do: "relevant"

  defp maybe_put_dedupe_key(attrs, fallback) do
    if read_string(attrs, "dedupe_key", nil) do
      attrs
    else
      Map.put(attrs, "dedupe_key", fallback)
    end
  end

  defp status_event_type("archived"), do: "archived"
  defp status_event_type("superseded"), do: "superseded"
  defp status_event_type("rejected"), do: "rejected"
  defp status_event_type(_status), do: "updated"

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_text(_value), do: nil
end
