defmodule Maraithon.Todos do
  @moduledoc """
  Context for user-scoped todo items managed by conversational operators.
  """

  import Ecto.Query

  alias Maraithon.Insights.Insight
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo

  alias Maraithon.Todos.{
    AttentionRanker,
    DecisionSignals,
    FeedbackTrainer,
    Intelligence,
    SurfaceQuality
  }

  alias Maraithon.Todos.UserFacingCopy
  alias Maraithon.Todos.Todo

  @open_statuses ~w(open snoozed)
  @feedback_values ~w(helpful not_helpful)
  @decision_text_pattern "\\m(approve|approval|approved|ask|asked|blocked|blocking|call|choose|commitment|committed|decide|decision|owe|owes|owed|reply|replied|respond|response|wait|waiting)\\M"
  @fallback_title "Review open work"
  @fallback_summary "This saved open work needs a keep, delegate, or dismiss decision."
  @fallback_action "Open the source context, confirm the request, then keep, delegate, or dismiss it."

  def get_for_user(user_id, todo_id)
      when is_binary(user_id) and is_binary(todo_id) do
    Todo
    |> Repo.get_by(id: todo_id, user_id: user_id)
    |> polish_todo_copy()
  end

  def get_for_user(_user_id, _todo_id), do: nil

  def list_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = normalize_limit(Keyword.get(opts, :limit, 20), 20)
    sort_by = normalize_sort_by(Keyword.get(opts, :sort_by, "rank"))
    sort_dir = normalize_sort_dir(Keyword.get(opts, :sort_dir, "desc"))
    decision_only? = decision_only_option?(opts)

    user_id
    |> filtered_todo_query(opts)
    |> maybe_filter_decision_only(decision_only?)
    |> apply_todo_order(sort_by, sort_dir)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&polish_todo_copy/1)
    |> Enum.filter(&(not decision_only? or DecisionSignals.needs_decision?(&1)))
  end

  def count_for_user(user_id, opts \\ []) when is_binary(user_id) do
    decision_only? = decision_only_option?(opts)

    user_id
    |> filtered_todo_query(opts)
    |> maybe_filter_decision_only(decision_only?)
    |> exclude(:order_by)
    |> select([todo], count(todo.id))
    |> Repo.one()
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
    |> Enum.map(&polish_todo_copy/1)
  end

  def list_by_ids(user_id, todo_ids, opts \\ [])

  def list_by_ids(user_id, todo_ids, opts)
      when is_binary(user_id) and is_list(todo_ids) do
    ids =
      todo_ids
      |> Enum.flat_map(&cast_todo_id/1)
      |> Enum.uniq()

    if ids == [] do
      []
    else
      statuses = normalize_status_filters(Keyword.get(opts, :statuses))
      open_due_only? = Keyword.get(opts, :open_due_only, false)
      order = Map.new(Enum.with_index(ids))

      Todo
      |> where([todo], todo.user_id == ^user_id and todo.id in ^ids)
      |> maybe_filter_statuses(statuses)
      |> maybe_filter_open_due_only(open_due_only?)
      |> Repo.all()
      |> Enum.sort_by(fn todo -> Map.get(order, todo.id, map_size(order)) end)
      |> Enum.map(&polish_todo_copy/1)
    end
  end

  def list_by_ids(_user_id, _todo_ids, _opts), do: []

  defp cast_todo_id(value) when is_binary(value) do
    value = String.trim(value)

    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> [uuid]
      :error -> []
    end
  end

  defp cast_todo_id(_value), do: []

  defp polish_todo_copy(%Todo{} = todo), do: UserFacingCopy.polish_attrs(todo)
  defp polish_todo_copy(other), do: other

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

  def ingest_many(user_id, attrs_list, opts \\ [])

  def ingest_many(user_id, attrs_list, opts)
      when is_binary(user_id) and is_list(attrs_list) and is_list(opts) do
    Intelligence.ingest_many(user_id, attrs_list, opts)
  end

  def ingest_many(_user_id, _attrs_list, _opts), do: {:error, :invalid_todo_candidates}

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

  def mark_important(user_id, todo_id, opts \\ [])

  def mark_important(user_id, todo_id, opts) when is_binary(user_id) and is_binary(todo_id) do
    source = Keyword.get(opts, :source)

    Repo.transaction(fn ->
      with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
           {:ok, updated} <-
             todo
             |> Todo.changeset(%{
               attention_mode: "act_now",
               priority: max(todo.priority || 0, 90),
               status: if(todo.status == "snoozed", do: "open", else: todo.status),
               snoozed_until: nil,
               metadata: put_importance_override(todo.metadata || %{}, source)
             })
             |> Repo.update() do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} -> {:ok, polish_todo_copy(todo)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_important(_user_id, _todo_id, _opts), do: {:error, :not_found}

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
      {:ok, %Todo{} = todo} -> {:ok, polish_todo_copy(todo)}
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
        todo = polish_todo_copy(todo)
        _ = maybe_learn_from_feedback(todo, feedback)
        {:ok, todo}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def record_feedback(_user_id, _todo_id, _feedback, _opts), do: {:error, :not_found}

  def see_less_like(user_id, todo_id, opts \\ [])

  def see_less_like(user_id, todo_id, opts) when is_binary(user_id) and is_binary(todo_id) do
    source = normalize_feedback_source(Keyword.get(opts, :source, "todo_surface"))

    with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
         {:ok, %{memory: memory, training: training}} <-
           FeedbackTrainer.train_see_less(user_id, todo, opts),
         {:ok, dismissed} <-
           update_status(
             user_id,
             todo_id,
             "dismissed",
             see_less_resolution_note(source),
             put_see_less_feedback(%{}, source, memory, training)
           ) do
      {:ok, %{todo: dismissed, memory: memory, training: training}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :todo_see_less_failed}
    end
  end

  def see_less_like(_user_id, _todo_id, _opts), do: {:error, :not_found}

  def update_for_user(user_id, todo_id, attrs)
      when is_binary(user_id) and is_binary(todo_id) and is_map(attrs) do
    Repo.transaction(fn ->
      with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id) do
        changes = update_attrs(todo, attrs)

        if changes == %{} do
          Repo.rollback(:empty_update)
        else
          with {:ok, updated} <- todo |> Todo.changeset(changes) |> Repo.update(),
               {:ok, _insight} <- sync_linked_insight(updated) do
            updated
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      else
        nil -> Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, %Todo{} = todo} -> {:ok, polish_todo_copy(todo)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :empty_update} -> {:error, :empty_update}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_for_user(_user_id, _todo_id, _attrs), do: {:error, :not_found}

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
      {:ok, %Todo{} = todo} -> {:ok, polish_todo_copy(todo)}
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
    todo = UserFacingCopy.polish_attrs(todo)

    %{
      id: todo.id,
      source: todo.source,
      kind: todo.kind,
      attention_mode: todo.attention_mode,
      status: todo.status,
      title: todo.title,
      summary: todo.summary,
      next_action: todo.next_action,
      due_at: todo.due_at,
      notes: todo.notes,
      action_plan: todo.action_plan,
      action_draft: todo.action_draft || %{},
      owner_user_id: todo.owner_user_id,
      owner_label: todo.owner_label,
      priority: todo.priority,
      source_account_id: todo.source_account_id,
      source_account_label: todo.source_account_label,
      source_item_id: todo.source_item_id,
      source_occurred_at: todo.source_occurred_at,
      inserted_at: todo.inserted_at,
      updated_at: todo.updated_at,
      attention_profile: AttentionRanker.profile(todo),
      surface_quality: SurfaceQuality.assess(todo),
      metadata: summarize_metadata(todo.metadata || %{})
    }
  end

  defp upsert_one(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    normalized_attrs =
      user_id
      |> normalize_attrs(attrs)
      |> UserFacingCopy.polish_attrs()

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

  defp update_status(user_id, todo_id, status, note, extra_metadata \\ %{}) do
    Repo.transaction(fn ->
      with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
           {:ok, updated} <-
             todo
             |> Todo.changeset(%{
               status: status,
               snoozed_until: nil,
               closed_at: DateTime.utc_now() |> DateTime.truncate(:second),
               metadata:
                 (todo.metadata || %{})
                 |> put_resolution_note(note)
                 |> Map.merge(extra_metadata || %{})
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
      {:ok, %Todo{} = todo} -> {:ok, polish_todo_copy(todo)}
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

  defp update_attrs(%Todo{} = todo, attrs) when is_map(attrs) do
    %{}
    |> update_text_attr(attrs, "source", "source")
    |> update_integer_attr(attrs, "source_account_id", "source_account_id")
    |> update_text_attr(attrs, "source_account_label", "source_account_label")
    |> update_kind_attr(attrs)
    |> update_attention_mode_attr(attrs)
    |> update_text_attr(attrs, "title", "title")
    |> update_text_attr(attrs, "todo", "summary")
    |> update_text_attr(attrs, "summary", "summary")
    |> update_text_attr(attrs, "next_action", "next_action")
    |> update_datetime_attr(attrs, "due_at", "due_at")
    |> update_datetime_attr(attrs, "due_date", "due_at")
    |> update_text_attr(attrs, "notes", "notes")
    |> update_text_attr(attrs, "action_plan", "action_plan")
    |> update_action_draft_attr(attrs)
    |> update_text_attr(attrs, "owner_user_id", "owner_user_id")
    |> update_text_attr(attrs, "owner_label", "owner_label")
    |> update_integer_attr(attrs, "priority", "priority", &clamp_integer(&1, 0, 100))
    |> update_status_attrs(todo, attrs)
    |> update_text_attr(attrs, "source_item_id", "source_item_id")
    |> update_datetime_attr(attrs, "source_occurred_at", "source_occurred_at")
    |> update_text_attr(attrs, "dedupe_key", "dedupe_key")
    |> update_metadata_attr(todo, attrs)
    |> UserFacingCopy.polish_attrs()
  end

  defp update_text_attr(changes, attrs, key, field) do
    if attr_present?(attrs, key) do
      case read_string(attrs, key, nil) do
        nil -> changes
        value -> Map.put(changes, field, value)
      end
    else
      changes
    end
  end

  defp update_integer_attr(changes, attrs, key, field, transform \\ & &1) do
    if attr_present?(attrs, key) do
      case read_integer(attrs, key, nil) do
        nil -> changes
        value -> Map.put(changes, field, transform.(value))
      end
    else
      changes
    end
  end

  defp update_datetime_attr(changes, attrs, key, field) do
    if attr_present?(attrs, key) do
      case read_datetime(attrs, key) do
        nil -> changes
        value -> Map.put(changes, field, value)
      end
    else
      changes
    end
  end

  defp update_kind_attr(changes, attrs) do
    if attr_present?(attrs, "kind") do
      Map.put(changes, "kind", normalize_kind(read_string(attrs, "kind", "general")))
    else
      changes
    end
  end

  defp update_attention_mode_attr(changes, attrs) do
    if attr_present?(attrs, "attention_mode") do
      Map.put(
        changes,
        "attention_mode",
        normalize_attention_mode(read_string(attrs, "attention_mode", "act_now"))
      )
    else
      changes
    end
  end

  defp update_action_draft_attr(changes, attrs) do
    if attr_present?(attrs, "action_draft") or attr_present?(attrs, "draft") do
      Map.put(changes, "action_draft", read_action_draft(attrs))
    else
      changes
    end
  end

  defp update_status_attrs(changes, %Todo{} = todo, attrs) do
    changes =
      if attr_present?(attrs, "status") do
        status = normalize_status(read_string(attrs, "status", "open"))
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case status do
          "open" ->
            changes
            |> Map.put("status", "open")
            |> Map.put("closed_at", nil)
            |> Map.put("snoozed_until", nil)

          "done" ->
            changes
            |> Map.put("status", "done")
            |> Map.put("closed_at", todo.closed_at || now)
            |> Map.put("snoozed_until", nil)

          "dismissed" ->
            changes
            |> Map.put("status", "dismissed")
            |> Map.put("closed_at", todo.closed_at || now)
            |> Map.put("snoozed_until", nil)

          "snoozed" ->
            snoozed_until =
              read_datetime(attrs, "snoozed_until") || todo.snoozed_until ||
                DateTime.add(now, 24, :hour)

            changes
            |> Map.put("status", "snoozed")
            |> Map.put("closed_at", nil)
            |> Map.put("snoozed_until", snoozed_until)
        end
      else
        changes
      end

    update_datetime_attr(changes, attrs, "snoozed_until", "snoozed_until")
  end

  defp update_metadata_attr(changes, %Todo{} = todo, attrs) do
    if attr_present?(attrs, "metadata") do
      metadata = read_map(attrs, "metadata") |> stringify_top_level_keys()

      merged_metadata =
        if truthy?(fetch_attr(attrs, "replace_metadata")) do
          metadata
        else
          Map.merge(todo.metadata || %{}, metadata)
        end

      Map.put(changes, "metadata", merged_metadata)
    else
      changes
    end
  end

  defp attr_present?(attrs, key) when is_map(attrs) and is_binary(key) do
    Map.has_key?(attrs, key) or
      case existing_atom_key(key) do
        atom_key when is_atom(atom_key) -> Map.has_key?(attrs, atom_key)
        _ -> false
      end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp normalize_attrs(user_id, attrs) do
    metadata = read_map(attrs, "metadata")
    source = read_string(attrs, "source", "system")
    kind = normalize_kind(read_string(attrs, "kind", "general"))
    source_item_id = read_string(attrs, "source_item_id", nil)

    due_at =
      read_datetime(attrs, "due_at") || read_datetime(attrs, "due_date") ||
        read_datetime(attrs, "due")

    owner_user_id = read_string(attrs, "owner_user_id", user_id)
    owner_label = read_string(attrs, "owner_label", read_string(attrs, "owner", nil))

    action_plan =
      read_string(
        attrs,
        "action_plan",
        read_string(attrs, "draft_plan", read_string(attrs, "plan", nil))
      )

    %{
      "user_id" => user_id,
      "owner_user_id" => owner_user_id,
      "owner_label" => normalize_owner_label(owner_label, owner_user_id, user_id),
      "source" => source,
      "source_account_id" => read_integer(attrs, "source_account_id", nil),
      "source_account_label" =>
        read_string(attrs, "source_account_label", source_account_label_from_metadata(metadata)),
      "kind" => kind,
      "attention_mode" =>
        normalize_attention_mode(read_string(attrs, "attention_mode", "act_now")),
      "title" => read_string(attrs, "title", @fallback_title),
      "summary" => read_string(attrs, "summary", read_string(attrs, "todo", @fallback_summary)),
      "next_action" => read_string(attrs, "next_action", @fallback_action),
      "due_at" => due_at,
      "notes" => read_string(attrs, "notes", nil),
      "action_plan" => action_plan,
      "action_draft" => read_action_draft(attrs),
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
    metadata = insight.metadata || %{}

    %{
      user_id: insight.user_id,
      owner_user_id: insight.user_id,
      owner_label: owner_label_from_metadata(metadata),
      source: insight.source || "system",
      source_account_id: read_integer(metadata, "source_account_id", nil),
      source_account_label: source_account_label_from_metadata(metadata),
      kind: todo_kind_from_insight(insight),
      attention_mode: normalize_attention_mode(insight.attention_mode || "act_now"),
      title: normalize_required_text(insight.title, @fallback_title),
      summary: normalize_required_text(insight.summary, @fallback_summary),
      next_action: normalize_required_text(insight.recommended_action, @fallback_action),
      due_at: insight.due_at,
      notes: notes_from_metadata(metadata),
      action_plan: action_plan_from_metadata(metadata),
      action_draft: read_action_draft(metadata),
      priority: clamp_integer(insight.priority || 50, 0, 100),
      status: todo_status_from_insight(insight.status),
      snoozed_until: insight.snoozed_until,
      closed_at: todo_closed_at(insight),
      source_item_id: insight.source_id,
      source_occurred_at: insight.source_occurred_at,
      dedupe_key: todo_dedupe_key_for_insight(insight),
      metadata: todo_metadata_from_insight(insight)
    }
    |> UserFacingCopy.polish_attrs()
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

  defp filtered_todo_query(user_id, opts) do
    source = Keyword.get(opts, :source)
    source_account_id = Keyword.get(opts, :source_account_id)
    kind = Keyword.get(opts, :kind)
    attention_mode = Keyword.get(opts, :attention_mode)
    owner_user_id = Keyword.get(opts, :owner_user_id)
    due_before = Keyword.get(opts, :due_before) || Keyword.get(opts, :due_before_or_at)
    due_after = Keyword.get(opts, :due_after) || Keyword.get(opts, :due_after_or_at)
    due_nil? = Keyword.get(opts, :due_nil?, false)
    statuses = normalize_status_filters(Keyword.get(opts, :statuses))
    query_text = normalize_query_text(Keyword.get(opts, :query))
    open_due_only? = Keyword.get(opts, :open_due_only, false)

    Todo
    |> where([todo], todo.user_id == ^user_id)
    |> maybe_filter_statuses(statuses)
    |> maybe_filter_open_due_only(open_due_only?)
    |> maybe_filter_source(source)
    |> maybe_filter_source_account_id(source_account_id)
    |> maybe_filter_kind(kind)
    |> maybe_filter_attention_mode(attention_mode)
    |> maybe_filter_owner_user_id(owner_user_id)
    |> maybe_filter_due_after(due_after)
    |> maybe_filter_due_before(due_before)
    |> maybe_filter_due_nil(due_nil?)
    |> maybe_filter_query(query_text)
  end

  defp maybe_filter_source(query, nil), do: query
  defp maybe_filter_source(query, ""), do: query
  defp maybe_filter_source(query, "all"), do: query

  defp maybe_filter_source(query, source) when is_binary(source) do
    where(query, [todo], todo.source == ^source)
  end

  defp maybe_filter_source_account_id(query, nil), do: query
  defp maybe_filter_source_account_id(query, ""), do: query

  defp maybe_filter_source_account_id(query, source_account_id) do
    case normalize_integer_filter(source_account_id) do
      nil -> query
      id -> where(query, [todo], todo.source_account_id == ^id)
    end
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
  defp maybe_filter_attention_mode(query, "all"), do: query

  defp maybe_filter_attention_mode(query, attention_mode) when is_binary(attention_mode) do
    where(query, [todo], todo.attention_mode == ^attention_mode)
  end

  defp maybe_filter_decision_only(query, false), do: query

  defp maybe_filter_decision_only(query, true) do
    where(
      query,
      [todo],
      todo.status in ^@open_statuses and
        (fragment(
           """
           coalesce(?->>'commitment_direction', '') in ('i_owe', 'asked_of_me', 'pending_reply', 'user_owes', 'waiting_on_user', 'waiting_on_me')
           """,
           todo.metadata
         ) or
           fragment(
             """
             coalesce(?->>'thread_state', '') in ('i_owe', 'asked_of_me', 'pending_reply', 'user_owes', 'waiting_on_user', 'waiting_on_me', 'waiting_on_kent')
             """,
             todo.metadata
           ) or
           fragment(
             """
             coalesce(? #>> '{conversation_context,momentum_state}', '') in ('i_owe', 'asked_of_me', 'pending_reply', 'user_owes', 'waiting_on_user', 'waiting_on_me', 'waiting_on_kent')
             """,
             todo.metadata
           ) or
           fragment(
             """
             lower(concat_ws(' ', ?, ?, ?, ?, ?, coalesce(?->>'why_now', ''), coalesce(?->>'why_it_matters', ''), coalesce(?->>'context_brief', ''), coalesce(?->>'thread_state', ''), coalesce(?->>'source_quote', ''), coalesce(?->>'source_excerpt', ''), coalesce(?->>'quote', ''))) ~ ?
             """,
             todo.title,
             todo.summary,
             todo.next_action,
             todo.notes,
             todo.action_plan,
             todo.metadata,
             todo.metadata,
             todo.metadata,
             todo.metadata,
             todo.metadata,
             todo.metadata,
             todo.metadata,
             ^@decision_text_pattern
           ))
    )
  end

  defp decision_only_option?(opts) when is_list(opts) do
    Enum.any?(opts, fn
      {:decision_only?, value} -> truthy?(value)
      {:decision_only, value} -> truthy?(value)
      {"decision_only?", value} -> truthy?(value)
      {"decision_only", value} -> truthy?(value)
      _entry -> false
    end)
  end

  defp decision_only_option?(opts) when is_map(opts) do
    opts
    |> Map.take([:decision_only?, :decision_only, "decision_only?", "decision_only"])
    |> Map.values()
    |> Enum.any?(&truthy?/1)
  end

  defp decision_only_option?(_opts), do: false

  defp maybe_filter_owner_user_id(query, nil), do: query
  defp maybe_filter_owner_user_id(query, ""), do: query

  defp maybe_filter_owner_user_id(query, owner_user_id) when is_binary(owner_user_id) do
    where(query, [todo], todo.owner_user_id == ^owner_user_id)
  end

  defp maybe_filter_owner_user_id(query, _owner_user_id), do: query

  defp maybe_filter_due_after(query, nil), do: query
  defp maybe_filter_due_after(query, ""), do: query

  defp maybe_filter_due_after(query, value) do
    case coerce_datetime(value) do
      nil -> query
      due_after -> where(query, [todo], not is_nil(todo.due_at) and todo.due_at >= ^due_after)
    end
  end

  defp maybe_filter_due_before(query, nil), do: query
  defp maybe_filter_due_before(query, ""), do: query

  defp maybe_filter_due_before(query, value) do
    case coerce_datetime(value) do
      nil -> query
      due_before -> where(query, [todo], not is_nil(todo.due_at) and todo.due_at <= ^due_before)
    end
  end

  defp maybe_filter_due_nil(query, true), do: where(query, [todo], is_nil(todo.due_at))
  defp maybe_filter_due_nil(query, "true"), do: where(query, [todo], is_nil(todo.due_at))
  defp maybe_filter_due_nil(query, _due_nil?), do: query

  defp apply_todo_order(query, "title", "asc"),
    do: order_by(query, [todo], asc: todo.title, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "title", "desc"),
    do: order_by(query, [todo], desc: todo.title, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "source", "asc"),
    do: order_by(query, [todo], asc: todo.source, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "source", "desc"),
    do: order_by(query, [todo], desc: todo.source, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "status", "asc"),
    do: order_by(query, [todo], asc: todo.status, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "status", "desc"),
    do: order_by(query, [todo], desc: todo.status, desc: todo.priority, desc: todo.updated_at)

  defp apply_todo_order(query, "attention", "asc"),
    do:
      order_by(query, [todo],
        asc:
          fragment(
            "CASE WHEN ? = 'act_now' THEN 0 WHEN ? = 'monitor' THEN 1 ELSE 2 END",
            todo.attention_mode,
            todo.attention_mode
          ),
        desc: todo.priority,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "attention", "desc"),
    do:
      order_by(query, [todo],
        desc:
          fragment(
            "CASE WHEN ? = 'act_now' THEN 0 WHEN ? = 'monitor' THEN 1 ELSE 2 END",
            todo.attention_mode,
            todo.attention_mode
          ),
        desc: todo.priority,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "priority", "asc"),
    do:
      order_by(query, [todo],
        asc: todo.priority,
        asc_nulls_last: todo.due_at,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "priority", "desc"),
    do:
      order_by(query, [todo],
        desc: todo.priority,
        asc_nulls_last: todo.due_at,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "due", "asc"),
    do:
      order_by(query, [todo],
        asc_nulls_last: todo.due_at,
        desc: todo.priority,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "due", "desc"),
    do:
      order_by(query, [todo],
        desc_nulls_last: todo.due_at,
        desc: todo.priority,
        desc: todo.updated_at
      )

  defp apply_todo_order(query, "updated", "asc"),
    do:
      order_by(query, [todo],
        asc: todo.updated_at,
        desc: todo.priority,
        asc_nulls_last: todo.due_at
      )

  defp apply_todo_order(query, "updated", "desc"),
    do:
      order_by(query, [todo],
        desc: todo.updated_at,
        desc: todo.priority,
        asc_nulls_last: todo.due_at
      )

  defp apply_todo_order(query, _sort_by, _sort_dir) do
    order_by(
      query,
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
      asc_nulls_last: todo.due_at,
      desc: todo.updated_at,
      desc: todo.inserted_at
    )
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
        fragment("coalesce(?, '') ILIKE ?", todo.notes, ^pattern) or
        fragment("coalesce(?, '') ILIKE ?", todo.action_plan, ^pattern) or
        fragment("coalesce(?, '') ILIKE ?", todo.owner_label, ^pattern) or
        fragment("coalesce(?, '') ILIKE ?", todo.source_account_label, ^pattern) or
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

  defp put_see_less_feedback(metadata, source, memory, training) when is_map(metadata) do
    recorded_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    feedback = %{
      "value" => "see_less",
      "source" => source,
      "memory_id" => memory.id,
      "memory_title" => memory.title,
      "pattern_key" => Map.get(training, "pattern_key"),
      "summary" => Map.get(training, "summary"),
      "recorded_at" => recorded_at
    }

    metadata
    |> Map.put("assistant_feedback", feedback)
    |> Map.put("see_less_feedback", feedback)
  end

  defp see_less_resolution_note(source) when is_binary(source) and source != "" do
    "See less feedback recorded from #{source}."
  end

  defp see_less_resolution_note(_source), do: "See less feedback recorded."

  defp normalize_feedback_source(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "todo_surface"
      source -> source
    end
  end

  defp normalize_feedback_source(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_feedback_source(_value), do: "todo_surface"

  defp put_importance_override(metadata, source) when is_map(metadata) do
    recorded_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    metadata
    |> Map.put("assistant_feedback", %{
      "value" => "important",
      "source" => source,
      "recorded_at" => recorded_at
    })
    |> Map.put("importance_override", %{
      "value" => "important",
      "source" => source,
      "recorded_at" => recorded_at
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
    metadata
    |> Map.take([
      "thread_id",
      "google_account_email",
      "from",
      "subject",
      "account_email",
      "source_account_label",
      "person",
      "company",
      "organization",
      "relationship",
      "relationship_context",
      "relationship_strength",
      "interaction_count",
      "communication_frequency",
      "context",
      "context_brief",
      "why_it_matters",
      "project",
      "project_name",
      "life_domain",
      "source_tags",
      "commitment_direction",
      "team_name",
      "workspace_name",
      "owner",
      "assignee",
      "draft_plan",
      "suggested_reply_points",
      "life_domain",
      "resolution_note",
      "assistant_feedback",
      "see_less_feedback",
      "source_insight_id",
      "source_insight_status",
      "suggested_project_id",
      "suggested_project_name",
      "suggested_life_domain",
      "scope_confidence",
      "scope_reasoning",
      "surface_quality"
    ])
    |> maybe_put("record", summarize_record_metadata(fetch_attr(metadata, "record")))
  end

  defp summarize_metadata(_metadata), do: %{}

  defp summarize_record_metadata(record) when is_map(record) do
    summarized =
      record
      |> Map.take([
        "person",
        "company",
        "organization",
        "relationship",
        "relationship_context",
        "relationship_strength",
        "interaction_count",
        "communication_frequency",
        "summary",
        "ask",
        "commitment",
        "context",
        "why_it_matters",
        "project",
        "project_name"
      ])
      |> compact_map()

    if summarized == %{}, do: nil, else: summarized
  end

  defp summarize_record_metadata(_record), do: nil

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

  defp normalize_sort_by(value)
       when value in ~w(rank title source status attention priority due updated),
       do: value

  defp normalize_sort_by("due_at"), do: "due"
  defp normalize_sort_by("updated_at"), do: "updated"
  defp normalize_sort_by("inserted_at"), do: "updated"
  defp normalize_sort_by(_value), do: "rank"

  defp normalize_sort_dir(value) when value in ~w(asc desc), do: value
  defp normalize_sort_dir(_value), do: "desc"

  defp normalize_limit(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_limit(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_limit(_value, default), do: default

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

  defp normalize_owner_label(nil, _owner_user_id, _user_id), do: nil
  defp normalize_owner_label("", _owner_user_id, _user_id), do: nil
  defp normalize_owner_label(owner_user_id, owner_user_id, _user_id), do: nil
  defp normalize_owner_label(user_id, _owner_user_id, user_id), do: nil
  defp normalize_owner_label(owner_label, _owner_user_id, _user_id), do: owner_label

  defp source_account_label_from_metadata(metadata) when is_map(metadata) do
    read_string(
      metadata,
      "source_account_label",
      read_string(
        metadata,
        "google_account_email",
        read_string(
          metadata,
          "account_email",
          read_string(
            metadata,
            "email",
            read_string(
              metadata,
              "team_name",
              read_string(metadata, "workspace_name", read_string(metadata, "username", nil))
            )
          )
        )
      )
    )
  end

  defp source_account_label_from_metadata(_metadata), do: nil

  defp owner_label_from_metadata(metadata) when is_map(metadata) do
    read_string(
      metadata,
      "owner_label",
      read_string(metadata, "owner", read_string(metadata, "assignee", nil))
    )
  end

  defp owner_label_from_metadata(_metadata), do: nil

  defp notes_from_metadata(metadata) when is_map(metadata) do
    read_string(metadata, "notes", read_string(metadata, "note", nil))
  end

  defp notes_from_metadata(_metadata), do: nil

  defp action_plan_from_metadata(metadata) when is_map(metadata) do
    read_string(metadata, "action_plan", read_string(metadata, "draft_plan", nil))
  end

  defp action_plan_from_metadata(_metadata), do: nil

  defp read_action_draft(attrs) when is_map(attrs) do
    case fetch_attr(attrs, "action_draft") || fetch_attr(attrs, "draft") do
      value when is_map(value) ->
        stringify_top_level_keys(value)

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> %{}
          trimmed -> %{"text" => trimmed}
        end

      _ ->
        %{}
    end
  end

  defp read_action_draft(_attrs), do: %{}

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
    attrs
    |> fetch_attr(key)
    |> coerce_datetime()
  end

  defp coerce_datetime(%DateTime{} = value), do: value

  defp coerce_datetime(%NaiveDateTime{} = value) do
    DateTime.from_naive!(value, "Etc/UTC")
  end

  defp coerce_datetime(%Date{} = value) do
    DateTime.new!(value, ~T[00:00:00], "Etc/UTC")
  end

  defp coerce_datetime(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      true ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, parsed, _offset} ->
            parsed

          _ ->
            case Date.from_iso8601(trimmed) do
              {:ok, date} -> coerce_datetime(date)
              _ -> nil
            end
        end
    end
  end

  defp coerce_datetime(_value), do: nil

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

  defp normalize_integer_filter(value) when is_integer(value), do: value

  defp normalize_integer_filter(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer_filter(_value), do: nil

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

  defp stringify_top_level_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(_key), do: nil
end
