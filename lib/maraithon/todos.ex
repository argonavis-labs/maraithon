defmodule Maraithon.Todos do
  @moduledoc """
  Context for user-scoped todo items managed by conversational operators.
  """

  import Ecto.Query

  alias Maraithon.Insights.Insight
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.Todos.Todo

  @open_statuses ~w(open snoozed)
  @feedback_values ~w(helpful not_helpful)

  def get_for_user(user_id, todo_id)
      when is_binary(user_id) and is_binary(todo_id) do
    Repo.get_by(Todo, id: todo_id, user_id: user_id)
  end

  def get_for_user(_user_id, _todo_id), do: nil

  def list_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 20)
    source = Keyword.get(opts, :source)
    kind = Keyword.get(opts, :kind)
    attention_mode = Keyword.get(opts, :attention_mode)
    statuses = normalize_status_filters(Keyword.get(opts, :statuses))
    query_text = normalize_query_text(Keyword.get(opts, :query))
    open_due_only? = Keyword.get(opts, :open_due_only, false)

    Todo
    |> where([todo], todo.user_id == ^user_id)
    |> maybe_filter_statuses(statuses)
    |> maybe_filter_open_due_only(open_due_only?)
    |> maybe_filter_source(source)
    |> maybe_filter_kind(kind)
    |> maybe_filter_attention_mode(attention_mode)
    |> maybe_filter_query(query_text)
    |> order_by(
      [
        todo
      ],
      asc:
        fragment(
          "CASE WHEN ? = 'act_now' THEN 0 WHEN ? = 'monitor' THEN 1 ELSE 2 END",
          todo.attention_mode,
          todo.attention_mode
        ),
      desc: todo.priority,
      desc: todo.updated_at,
      desc: todo.inserted_at
    )
    |> limit(^limit)
    |> Repo.all()
  end

  def list_open_for_user(user_id, opts \\ []) when is_binary(user_id) do
    opts =
      opts
      |> Keyword.put_new(:statuses, @open_statuses)
      |> Keyword.put(:open_due_only, true)

    list_for_user(user_id, opts)
  end

  def list_recent_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 40)

    Todo
    |> where([todo], todo.user_id == ^user_id)
    |> order_by([todo], desc: todo.updated_at, desc: todo.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def sync_many_from_insights(insights) when is_list(insights) do
    insights
    |> Enum.reduce({:ok, []}, fn
      %Insight{} = insight, {:ok, acc} ->
        case sync_from_insight(insight) do
          {:ok, todo} -> {:ok, [todo | acc]}
          {:error, reason} -> {:error, reason}
        end

      _other, {:ok, acc} ->
        {:ok, acc}
    end)
    |> case do
      {:ok, todos} -> {:ok, Enum.reverse(todos)}
      {:error, reason} -> {:error, reason}
    end
  end

  def sync_many_from_insights(_insights), do: {:error, :invalid_insights}

  def sync_from_insight(%Insight{} = insight) do
    upsert_synced_insight_todo(insight)
  end

  def sync_from_insight(_insight), do: {:error, :invalid_insight}

  def upsert_many(user_id, attrs_list) when is_binary(user_id) and is_list(attrs_list) do
    attrs_list
    |> Enum.reduce({:ok, []}, fn attrs, {:ok, acc} ->
      case upsert_one(user_id, attrs) do
        {:ok, todo} -> {:ok, [todo | acc]}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> case do
      {:ok, todos} -> {:ok, Enum.reverse(todos)}
      {:error, reason} -> {:error, reason}
    end
  end

  def upsert_many(_user_id, _attrs_list), do: {:error, :invalid_todo_attrs}

  def mark_done(user_id, todo_id, opts \\ [])

  def mark_done(user_id, todo_id, opts) when is_binary(user_id) and is_binary(todo_id) do
    note = Keyword.get(opts, :note)
    update_status(user_id, todo_id, "done", note)
  end

  def mark_done(_user_id, _todo_id, _opts), do: {:error, :not_found}

  def dismiss(user_id, todo_id, opts \\ [])

  def dismiss(user_id, todo_id, opts) when is_binary(user_id) and is_binary(todo_id) do
    note = Keyword.get(opts, :note)
    update_status(user_id, todo_id, "dismissed", note)
  end

  def dismiss(_user_id, _todo_id, _opts), do: {:error, :not_found}

  def snooze(user_id, todo_id, until_datetime, opts \\ [])

  def snooze(user_id, todo_id, until_datetime, opts)
      when is_binary(user_id) and is_binary(todo_id) and is_struct(until_datetime, DateTime) do
    note = Keyword.get(opts, :note)

    Repo.transaction(fn ->
      with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
           {:ok, updated} <-
             todo
             |> Todo.changeset(%{
               status: "snoozed",
               snoozed_until: until_datetime,
               closed_at: nil,
               metadata: put_resolution_note(todo.metadata || %{}, note)
             })
             |> Repo.update(),
           {:ok, _insight} <- sync_linked_insight(updated) do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} -> {:ok, todo}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def snooze(_user_id, _todo_id, _until_datetime, _opts), do: {:error, :not_found}

  def record_feedback(user_id, todo_id, feedback, opts \\ [])

  def record_feedback(user_id, todo_id, feedback, opts)
      when is_binary(user_id) and is_binary(todo_id) and feedback in @feedback_values do
    source = Keyword.get(opts, :source)

    Repo.transaction(fn ->
      with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
           {:ok, updated} <-
             todo
             |> Todo.changeset(%{
               metadata: put_feedback(todo.metadata || %{}, feedback, source)
             })
             |> Repo.update() do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} ->
        _ = maybe_learn_from_feedback(todo, feedback)
        {:ok, todo}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def record_feedback(_user_id, _todo_id, _feedback, _opts), do: {:error, :not_found}

  def annotate_scope(user_id, todo_id, attrs \\ [])

  def annotate_scope(user_id, todo_id, attrs)
      when is_binary(user_id) and is_binary(todo_id) and is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    Repo.transaction(fn ->
      with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
           {:ok, updated} <-
             todo
             |> Todo.changeset(%{metadata: put_scope_metadata(todo.metadata || %{}, attrs)})
             |> Repo.update() do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} -> {:ok, todo}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def annotate_scope(_user_id, _todo_id, _attrs), do: {:error, :not_found}

  def align_scope_for_project(user_id, project_id, attrs \\ %{})

  def align_scope_for_project(user_id, project_id, attrs)
      when is_binary(user_id) and is_binary(project_id) and is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("project_id", project_id)

    Todo
    |> where([todo], todo.user_id == ^user_id)
    |> where([todo], todo.status in ^@open_statuses)
    |> where(
      [todo],
      fragment("coalesce(?->>'suggested_project_id', '') = ?", todo.metadata, ^project_id)
    )
    |> Repo.all()
    |> Enum.reduce({:ok, []}, fn %Todo{} = todo, {:ok, acc} ->
      case annotate_scope(user_id, todo.id, attrs) do
        {:ok, updated} -> {:ok, [updated | acc]}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> case do
      {:ok, todos} -> {:ok, Enum.reverse(todos)}
      {:error, reason} -> {:error, reason}
    end
  end

  def align_scope_for_project(_user_id, _project_id, _attrs), do: {:error, :not_found}

  def summarize_for_prompt(user_id, limit \\ 8)

  def summarize_for_prompt(user_id, limit) when is_binary(user_id) do
    list_open_for_user(user_id, limit: limit)
    |> Enum.map(&serialize_for_prompt/1)
  end

  def summarize_for_prompt(_user_id, _limit), do: []

  def serialize_for_prompt(%Todo{} = todo) do
    %{
      id: todo.id,
      source: todo.source,
      kind: todo.kind,
      attention_mode: todo.attention_mode,
      status: todo.status,
      title: todo.title,
      summary: todo.summary,
      next_action: todo.next_action,
      priority: todo.priority,
      source_item_id: todo.source_item_id,
      source_occurred_at: todo.source_occurred_at,
      metadata: summarize_metadata(todo.metadata || %{})
    }
  end

  defp upsert_one(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    normalized_attrs = normalize_attrs(user_id, attrs)

    case Repo.get_by(Todo, user_id: user_id, dedupe_key: normalized_attrs["dedupe_key"]) do
      %Todo{} = todo ->
        todo
        |> Todo.changeset(merge_upsert_attrs(todo, normalized_attrs))
        |> Repo.update()

      nil ->
        %Todo{}
        |> Todo.changeset(normalized_attrs)
        |> Repo.insert()
    end
  end

  defp upsert_synced_insight_todo(%Insight{} = insight) do
    attrs = synced_insight_attrs(insight)

    case Repo.get_by(Todo, user_id: insight.user_id, dedupe_key: attrs.dedupe_key) do
      %Todo{} = todo ->
        todo
        |> Todo.changeset(attrs)
        |> Repo.update()

      nil ->
        %Todo{}
        |> Todo.changeset(attrs)
        |> Repo.insert()
    end
  end

  defp update_status(user_id, todo_id, status, note) do
    Repo.transaction(fn ->
      with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
           {:ok, updated} <-
             todo
             |> Todo.changeset(%{
               status: status,
               snoozed_until: nil,
               closed_at: DateTime.utc_now() |> DateTime.truncate(:second),
               metadata: put_resolution_note(todo.metadata || %{}, note)
             })
             |> Repo.update(),
           {:ok, _insight} <- sync_linked_insight(updated) do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} -> {:ok, todo}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_linked_insight(%Todo{} = todo) do
    case linked_insight(todo) do
      %Insight{} = insight ->
        insight
        |> Ecto.Changeset.change(linked_insight_changes(insight, todo))
        |> Repo.update()

      nil ->
        {:ok, nil}
    end
  end

  defp linked_insight(%Todo{} = todo) do
    case get_in(todo.metadata || %{}, ["source_insight_id"]) do
      insight_id when is_binary(insight_id) ->
        Repo.get_by(Insight, id: insight_id, user_id: todo.user_id)

      _ ->
        nil
    end
  end

  defp maybe_learn_from_feedback(%Todo{} = todo, feedback) when feedback in @feedback_values do
    case linked_insight(todo) do
      %Insight{} = insight ->
        PreferenceMemory.learn_from_feedback(todo.user_id, insight, feedback,
          allow_fallback?: false
        )

      nil ->
        {:ok, %{reply: nil, learned: []}}
    end
  rescue
    _error ->
      {:ok, %{reply: nil, learned: []}}
  end

  defp maybe_learn_from_feedback(_todo, _feedback), do: {:ok, %{reply: nil, learned: []}}

  defp linked_insight_changes(%Insight{} = insight, %Todo{} = todo) do
    changes =
      case todo.status do
        "done" ->
          %{status: "acknowledged", snoozed_until: nil}

        "dismissed" ->
          %{status: "dismissed", snoozed_until: nil}

        "snoozed" ->
          %{status: "snoozed", snoozed_until: todo.snoozed_until}

        _ ->
          %{}
      end

    case linked_insight_resolution_metadata(insight, todo) do
      nil -> changes
      metadata -> Map.put(changes, :metadata, metadata)
    end
  end

  defp linked_insight_resolution_metadata(%Insight{} = insight, %Todo{} = todo) do
    note = get_in(todo.metadata || %{}, ["resolution_note"])

    resolution =
      %{
        "todo_resolution" => %{
          "status" => todo.status,
          "resolved_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "note" => normalize_optional_string(note)
        }
      }
      |> compact_map()

    if map_size(resolution) == 0 do
      nil
    else
      Map.merge(insight.metadata || %{}, resolution)
    end
  end

  defp merge_upsert_attrs(%Todo{} = existing, attrs) do
    incoming_status = Map.get(attrs, "status", "open")

    status = merge_status(existing.status, incoming_status)

    closed_at =
      if status in ["done", "dismissed"] do
        existing.closed_at || Map.get(attrs, "closed_at")
      else
        nil
      end

    snoozed_until =
      if status == "snoozed" do
        existing.snoozed_until || Map.get(attrs, "snoozed_until")
      else
        nil
      end

    attrs
    |> Map.put("status", status)
    |> Map.put("closed_at", closed_at)
    |> Map.put("snoozed_until", snoozed_until)
  end

  defp merge_status(_existing_status, incoming_status)
       when incoming_status in ["done", "dismissed", "snoozed"] do
    incoming_status
  end

  defp merge_status(existing_status, "open")
       when existing_status in ["done", "dismissed", "snoozed"] do
    existing_status
  end

  defp merge_status(_existing_status, incoming_status), do: incoming_status

  defp normalize_attrs(user_id, attrs) do
    metadata = read_map(attrs, "metadata")
    source = read_string(attrs, "source", "system")
    kind = normalize_kind(read_string(attrs, "kind", "general"))
    source_item_id = read_string(attrs, "source_item_id", nil)

    %{
      "user_id" => user_id,
      "source" => source,
      "kind" => kind,
      "attention_mode" =>
        normalize_attention_mode(read_string(attrs, "attention_mode", "act_now")),
      "title" => read_string(attrs, "title", "Open todo"),
      "summary" => read_string(attrs, "summary", "Review this item."),
      "next_action" => read_string(attrs, "next_action", "Review and decide the next step."),
      "priority" => clamp_integer(read_integer(attrs, "priority", 50), 0, 100),
      "status" => normalize_status(read_string(attrs, "status", "open")),
      "snoozed_until" => read_datetime(attrs, "snoozed_until"),
      "closed_at" => read_datetime(attrs, "closed_at"),
      "source_item_id" => source_item_id,
      "source_occurred_at" => read_datetime(attrs, "source_occurred_at"),
      "dedupe_key" =>
        read_string(attrs, "dedupe_key", dedupe_key_for(source, kind, source_item_id, metadata)),
      "metadata" => metadata
    }
  end

  defp dedupe_key_for(source, kind, source_item_id, metadata) do
    thread_id =
      case metadata do
        %{"thread_id" => value} when is_binary(value) and value != "" -> value
        _ -> nil
      end

    source_key = source_item_id || thread_id || Ecto.UUID.generate()
    "#{source}:#{kind}:#{source_key}"
  end

  defp synced_insight_attrs(%Insight{} = insight) do
    %{
      user_id: insight.user_id,
      source: insight.source || "system",
      kind: todo_kind_from_insight(insight),
      attention_mode: normalize_attention_mode(insight.attention_mode || "act_now"),
      title: normalize_required_text(insight.title, "Open todo"),
      summary: normalize_required_text(insight.summary, "Review this item."),
      next_action:
        normalize_required_text(
          insight.recommended_action,
          "Review and decide the next step."
        ),
      priority: clamp_integer(insight.priority || 50, 0, 100),
      status: todo_status_from_insight(insight.status),
      snoozed_until: insight.snoozed_until,
      closed_at: todo_closed_at(insight),
      source_item_id: insight.source_id,
      source_occurred_at: insight.source_occurred_at,
      dedupe_key: todo_dedupe_key_for_insight(insight),
      metadata: todo_metadata_from_insight(insight)
    }
  end

  defp todo_kind_from_insight(%Insight{source: "gmail"}), do: "gmail_triage"
  defp todo_kind_from_insight(_insight), do: "general"

  defp todo_status_from_insight("acknowledged"), do: "done"
  defp todo_status_from_insight("dismissed"), do: "dismissed"
  defp todo_status_from_insight("snoozed"), do: "snoozed"
  defp todo_status_from_insight(_status), do: "open"

  defp todo_closed_at(%Insight{status: status, updated_at: updated_at})
       when status in ["acknowledged", "dismissed"] do
    updated_at || DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp todo_closed_at(_insight), do: nil

  defp todo_dedupe_key_for_insight(%Insight{} = insight) do
    logical_key = insight.tracking_key || insight.dedupe_key || insight.id
    "insight:#{logical_key}"
  end

  defp todo_metadata_from_insight(%Insight{} = insight) do
    (insight.metadata || %{})
    |> Map.put("source_insight_id", insight.id)
    |> Map.put("source_insight_status", insight.status)
    |> Map.put("source_insight_dedupe_key", insight.dedupe_key)
    |> Map.put("source_insight_tracking_key", insight.tracking_key)
    |> Map.put("source_insight_category", insight.category)
    |> maybe_put("source_insight_due_at", insight.due_at && DateTime.to_iso8601(insight.due_at))
    |> maybe_put("source_agent_id", insight.agent_id)
    |> maybe_put("confidence", insight.confidence)
  end

  defp maybe_filter_source(query, nil), do: query
  defp maybe_filter_source(query, ""), do: query

  defp maybe_filter_source(query, source) when is_binary(source) do
    where(query, [todo], todo.source == ^source)
  end

  defp maybe_filter_statuses(query, nil), do: query
  defp maybe_filter_statuses(query, []), do: where(query, [todo], false)

  defp maybe_filter_statuses(query, statuses) when is_list(statuses) do
    where(query, [todo], todo.status in ^statuses)
  end

  defp maybe_filter_open_due_only(query, false), do: query

  defp maybe_filter_open_due_only(query, true) do
    where(
      query,
      [todo],
      todo.status != "snoozed" or is_nil(todo.snoozed_until) or
        todo.snoozed_until <= ^DateTime.utc_now()
    )
  end

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, ""), do: query

  defp maybe_filter_kind(query, kind) when is_binary(kind) do
    where(query, [todo], todo.kind == ^kind)
  end

  defp maybe_filter_attention_mode(query, nil), do: query
  defp maybe_filter_attention_mode(query, ""), do: query

  defp maybe_filter_attention_mode(query, attention_mode) when is_binary(attention_mode) do
    where(query, [todo], todo.attention_mode == ^attention_mode)
  end

  defp maybe_filter_query(query, nil), do: query
  defp maybe_filter_query(query, ""), do: query

  defp maybe_filter_query(query, query_text) when is_binary(query_text) do
    pattern = "%" <> query_text <> "%"

    where(
      query,
      [todo],
      ilike(todo.title, ^pattern) or
        ilike(todo.summary, ^pattern) or
        ilike(todo.next_action, ^pattern) or
        ilike(todo.source, ^pattern) or
        fragment("coalesce(?, '') ILIKE ?", todo.source_item_id, ^pattern) or
        fragment("coalesce(?->>'subject', '') ILIKE ?", todo.metadata, ^pattern) or
        fragment("coalesce(?->>'from', '') ILIKE ?", todo.metadata, ^pattern) or
        fragment("coalesce(?->>'google_account_email', '') ILIKE ?", todo.metadata, ^pattern)
    )
  end

  defp put_resolution_note(metadata, nil), do: metadata
  defp put_resolution_note(metadata, ""), do: metadata

  defp put_resolution_note(metadata, note) when is_binary(note) do
    Map.put(metadata, "resolution_note", String.trim(note))
  end

  defp put_feedback(metadata, feedback, source) when feedback in @feedback_values do
    Map.put(metadata, "assistant_feedback", %{
      "value" => feedback,
      "source" => source,
      "recorded_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })
  end

  defp put_scope_metadata(metadata, attrs) when is_map(metadata) and is_map(attrs) do
    metadata
    |> Map.merge(scope_metadata_attrs(attrs))
  end

  defp put_scope_metadata(metadata, _attrs), do: metadata

  defp scope_metadata_attrs(attrs) when is_map(attrs) do
    %{
      "suggested_project_id" => normalize_optional_string(fetch_attr(attrs, "project_id")),
      "suggested_project_name" => normalize_optional_string(fetch_attr(attrs, "project_name")),
      "suggested_life_domain" => normalize_life_domain(fetch_attr(attrs, "life_domain")),
      "scope_confidence" => normalize_confidence(fetch_attr(attrs, "confidence")),
      "scope_reasoning" => normalize_optional_string(fetch_attr(attrs, "reasoning")),
      "scope_source" =>
        normalize_optional_string(fetch_attr(attrs, "source")) || "chief_of_staff_weekend",
      "scope_updated_at" => normalize_datetime(fetch_attr(attrs, "reviewed_at"))
    }
    |> compact_map()
  end

  defp summarize_metadata(metadata) when is_map(metadata) do
    Map.take(metadata, [
      "thread_id",
      "google_account_email",
      "from",
      "subject",
      "life_domain",
      "resolution_note",
      "assistant_feedback",
      "source_insight_id",
      "source_insight_status",
      "suggested_project_id",
      "suggested_project_name",
      "suggested_life_domain",
      "scope_confidence",
      "scope_reasoning"
    ])
  end

  defp summarize_metadata(_metadata), do: %{}

  defp normalize_kind(kind) when kind in ~w(general gmail_triage), do: kind
  defp normalize_kind(_kind), do: "general"

  defp normalize_attention_mode(value) when value in ~w(act_now monitor), do: value
  defp normalize_attention_mode(_value), do: "act_now"

  defp normalize_status(value) when value in ~w(open done dismissed snoozed), do: value
  defp normalize_status(_value), do: "open"

  defp normalize_status_filters(nil), do: nil

  defp normalize_status_filters(statuses) when is_list(statuses) do
    statuses
    |> Enum.map(fn
      value when is_binary(value) -> normalize_status(String.trim(value))
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_status_filters(status) when is_binary(status) do
    normalize_status_filters([status])
  end

  defp normalize_status_filters(_statuses), do: []

  defp normalize_query_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_query_text(_value), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_life_domain(value) when value in ~w(home work), do: value
  defp normalize_life_domain(_value), do: nil

  defp normalize_confidence(value) when is_float(value), do: value |> max(0.0) |> min(1.0)
  defp normalize_confidence(value) when is_integer(value), do: normalize_confidence(value / 1)

  defp normalize_confidence(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> normalize_confidence(parsed)
      _ -> nil
    end
  end

  defp normalize_confidence(_value), do: nil

  defp normalize_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_datetime(value) when is_binary(value), do: normalize_optional_string(value)
  defp normalize_datetime(_value), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp normalize_required_text(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp normalize_required_text(_value, default), do: default

  defp read_string(attrs, key, default) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end

  defp read_map(attrs, key) do
    case fetch_attr(attrs, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_integer(attrs, key, default) do
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

  defp read_datetime(attrs, key) do
    case fetch_attr(attrs, key) do
      %DateTime{} = value ->
        value

      value when is_binary(value) ->
        case DateTime.from_iso8601(String.trim(value)) do
          {:ok, parsed, _offset} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        case existing_atom_key(key) do
          atom_key when is_atom(atom_key) -> Map.get(attrs, atom_key)
          _ -> nil
        end
    end
  end

  defp clamp_integer(value, min_value, max_value) when is_integer(value) do
    value |> max(min_value) |> min(max_value)
  end

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map

  defp maybe_put(map, key, value) do
    Map.put(map, key, value)
  end

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(_key), do: nil
end
