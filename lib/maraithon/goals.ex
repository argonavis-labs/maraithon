defmodule Maraithon.Goals do
  @moduledoc """
  User-scoped goals, progress, links, review runs, and goal-aware context snapshots.
  """

  import Ecto.Query

  alias Maraithon.Briefs.Brief
  alias Maraithon.Crm.Person
  alias Maraithon.Goals.{Goal, GoalLink, ProgressUpdate, ReviewRun}
  alias Maraithon.Insights.Insight
  alias Maraithon.Memory.Item, as: MemoryItem
  alias Maraithon.Repo
  alias Maraithon.ScheduledTasks.Task, as: ScheduledTask
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.Todos
  alias Maraithon.Todos.{SurfaceQuality, Todo}

  @default_limit 50
  @max_limit 200
  @context_limit 12
  @open_statuses ~w(open snoozed)
  @internal_goal_attrs ~w(user_id last_reviewed_at next_review_at metadata)

  def list_goals(user_id, opts \\ [])

  def list_goals(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    Goal
    |> where([goal], goal.user_id == ^user_id)
    |> maybe_filter_status(Keyword.get(opts, :status, "active"))
    |> maybe_filter_category(Keyword.get(opts, :category, "all"))
    |> maybe_filter_sensitivity(Keyword.get(opts, :sensitivity, "all"))
    |> maybe_filter_query(Keyword.get(opts, :query))
    |> order_by([goal],
      asc:
        fragment(
          "CASE ? WHEN 'active' THEN 0 WHEN 'paused' THEN 1 WHEN 'achieved' THEN 2 ELSE 3 END",
          goal.status
        ),
      desc: goal.priority,
      asc_nulls_last: goal.next_review_at,
      desc: goal.updated_at
    )
    |> limit(^limit)
    |> Repo.all()
  end

  def list_goals(_user_id, _opts), do: []

  def get_goal(user_id, goal_id, opts \\ [])

  def get_goal(user_id, goal_id, opts)
      when is_binary(user_id) and is_binary(goal_id) and is_list(opts) do
    case Repo.get_by(Goal, id: goal_id, user_id: user_id) do
      %Goal{} = goal ->
        if Keyword.get(opts, :preload, true), do: preload_goal_detail(goal), else: goal

      nil ->
        nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  def get_goal(_user_id, _goal_id, _opts), do: nil

  def create_goal(user_id, attrs, opts \\ [])

  def create_goal(user_id, attrs, opts)
      when is_binary(user_id) and is_map(attrs) and is_list(opts) do
    attrs = normalize_goal_create_attrs(user_id, attrs, opts)

    %Goal{}
    |> Goal.changeset(attrs)
    |> Repo.insert()
    |> tap(fn
      {:ok, goal} -> emit_goal_event(:create, goal, %{})
      _other -> :ok
    end)
  end

  def create_goal(_user_id, _attrs, _opts), do: {:error, :invalid_goal_attrs}

  def update_goal(user_id, goal_id, attrs, opts \\ [])

  def update_goal(user_id, goal_id, attrs, opts)
      when is_binary(user_id) and is_binary(goal_id) and is_map(attrs) and is_list(opts) do
    case get_goal(user_id, goal_id, preload: false) do
      %Goal{} = goal ->
        attrs = normalize_goal_update_attrs(goal, attrs, opts)
        previous_status = goal.status

        goal
        |> Goal.changeset(attrs)
        |> Repo.update()
        |> tap(fn
          {:ok, updated} ->
            emit_goal_event(:update, updated, %{previous_status: previous_status})

          _other ->
            :ok
        end)

      nil ->
        {:error, :not_found}
    end
  end

  def update_goal(_user_id, _goal_id, _attrs, _opts), do: {:error, :not_found}

  def delete_goal(user_id, goal_id, opts \\ []) do
    update_goal(user_id, goal_id, %{"status" => "archived"}, opts)
  end

  def record_progress(user_id, goal_id, attrs, opts \\ [])

  def record_progress(user_id, goal_id, attrs, opts)
      when is_binary(user_id) and is_binary(goal_id) and is_map(attrs) and is_list(opts) do
    case get_goal(user_id, goal_id, preload: false) do
      %Goal{} ->
        attrs = normalize_progress_attrs(user_id, goal_id, attrs, opts)

        %ProgressUpdate{}
        |> ProgressUpdate.changeset(attrs)
        |> Repo.insert()

      nil ->
        {:error, :not_found}
    end
  end

  def record_progress(_user_id, _goal_id, _attrs, _opts), do: {:error, :not_found}

  def link_resource(user_id, goal_id, attrs, opts \\ [])

  def link_resource(user_id, goal_id, attrs, opts)
      when is_binary(user_id) and is_binary(goal_id) and is_map(attrs) and is_list(opts) do
    with %Goal{} <- get_goal(user_id, goal_id, preload: false),
         attrs <- normalize_link_attrs(user_id, goal_id, attrs, opts),
         :ok <- validate_linked_resource(user_id, attrs["resource_type"], attrs["resource_id"]) do
      %GoalLink{}
      |> GoalLink.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:source, :confidence, :metadata, :updated_at]},
        conflict_target: [:user_id, :goal_id, :resource_type, :resource_id, :relationship]
      )
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def link_resource(_user_id, _goal_id, _attrs, _opts), do: {:error, :not_found}

  def unlink_resource(user_id, goal_id, link_id, _opts \\ [])

  def unlink_resource(user_id, goal_id, link_id, _opts)
      when is_binary(user_id) and is_binary(goal_id) and is_binary(link_id) do
    case Repo.get_by(GoalLink, id: link_id, goal_id: goal_id, user_id: user_id) do
      %GoalLink{} = link -> Repo.delete(link)
      nil -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def unlink_resource(_user_id, _goal_id, _link_id, _opts), do: {:error, :not_found}

  def context_snapshot(user_id, opts \\ [])

  def context_snapshot(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @context_limit) |> clamp_limit() |> min(@context_limit)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    include_private? = Keyword.get(opts, :include_private, false)

    goals =
      Goal
      |> where([goal], goal.user_id == ^user_id and goal.status == "active")
      |> maybe_exclude_private(include_private?)
      |> order_by([goal], desc: goal.priority, asc_nulls_last: goal.next_review_at)
      |> limit(^limit)
      |> Repo.all()

    goal_ids = Enum.map(goals, & &1.id)
    latest_progress = latest_progress_by_goal_id(user_id, goal_ids)
    link_counts = link_counts_by_goal_id(user_id, goal_ids)

    active_count = count_goals(user_id, status: "active")
    review_due_count = count_review_due(user_id, now)
    at_risk_count = count_latest_progress_states(user_id, ~w(at_risk blocked stale))

    snapshot = %{
      "active_goals" =>
        Enum.map(goals, fn goal ->
          progress = Map.get(latest_progress, goal.id)
          counts = Map.get(link_counts, goal.id, %{})

          %{
            "id" => goal.id,
            "category" => goal.category,
            "title" => goal.title,
            "desired_outcome" => goal.desired_outcome,
            "priority" => goal.priority,
            "sensitivity" => goal.sensitivity,
            "proactive_visibility" => goal.proactive_visibility,
            "target_at" => json_value(goal.target_at),
            "review_cadence" => goal.review_cadence,
            "next_review_at" => json_value(goal.next_review_at),
            "latest_progress" => progress_snapshot(progress),
            "linked_work_count" => Map.get(counts, "todo", 0),
            "linked_people_count" => Map.get(counts, "person", 0)
          }
        end),
      "counts" => %{
        "active" => active_count,
        "review_due" => review_due_count,
        "at_risk" => at_risk_count
      }
    }

    :telemetry.execute(
      [:maraithon, :goals, :context_snapshot],
      %{count: length(goals)},
      %{
        active_count: active_count,
        included_count: length(goals),
        private_excluded_count: if(include_private?, do: 0, else: count_private_active(user_id))
      }
    )

    snapshot
  end

  def context_snapshot(_user_id, _opts), do: %{"active_goals" => [], "counts" => %{}}

  def open_loop_snapshot(user_id, opts \\ [])

  def open_loop_snapshot(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @context_limit) |> clamp_limit() |> min(@context_limit)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    context = context_snapshot(user_id, Keyword.merge(opts, limit: limit, now: now))
    active_goals = Map.get(context, "active_goals", [])

    %{
      source: "maraithon_goals",
      counts: Map.get(context, "counts", %{}),
      review_due_goals:
        now
        |> due_for_review(user_id: user_id, limit: limit)
        |> Enum.map(&compact_goal/1),
      at_risk_goals:
        active_goals
        |> Enum.filter(fn goal ->
          get_in(goal, ["latest_progress", "progress_state"]) in ~w(at_risk blocked stale)
        end)
        |> Enum.take(limit),
      active_goals: active_goals,
      linked_open_work: linked_open_work(user_id, limit)
    }
  end

  def open_loop_snapshot(_user_id, _opts),
    do: %{
      source: "maraithon_goals",
      counts: %{},
      review_due_goals: [],
      at_risk_goals: [],
      active_goals: [],
      linked_open_work: []
    }

  def due_for_review(now \\ DateTime.utc_now(), opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    Goal
    |> where([goal], goal.status == "active")
    |> where([goal], not is_nil(goal.next_review_at) and goal.next_review_at <= ^now)
    |> maybe_filter_user(Keyword.get(opts, :user_id))
    |> order_by([goal], asc: goal.next_review_at, desc: goal.priority)
    |> limit(^limit)
    |> Repo.all()
  end

  def record_review_run(user_id, attrs, opts \\ [])

  def record_review_run(user_id, attrs, opts)
      when is_binary(user_id) and is_map(attrs) and is_list(opts) do
    attrs = normalize_review_run_attrs(user_id, attrs, opts)

    %ReviewRun{}
    |> ReviewRun.changeset(attrs)
    |> Repo.insert()
  end

  def record_review_run(_user_id, _attrs, _opts), do: {:error, :invalid_goal_review_attrs}

  def complete_review_run(user_id, review_run_id, attrs \\ %{})

  def complete_review_run(user_id, review_run_id, attrs)
      when is_binary(user_id) and is_binary(review_run_id) and is_map(attrs) do
    case Repo.get_by(ReviewRun, id: review_run_id, user_id: user_id) do
      %ReviewRun{} = run ->
        attrs =
          attrs
          |> stringify_keys()
          |> Map.put_new("status", "completed")
          |> Map.put_new("finished_at", DateTime.utc_now())

        run
        |> ReviewRun.changeset(attrs)
        |> Repo.update()
        |> tap(fn
          {:ok, updated} -> maybe_update_goal_review_timestamp(updated)
          _other -> :ok
        end)

      nil ->
        {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def complete_review_run(_user_id, _review_run_id, _attrs), do: {:error, :not_found}

  def review_goal_alignment(user_id, opts \\ [])

  def review_goal_alignment(user_id, opts) when is_binary(user_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    trigger = opts |> Keyword.get(:trigger, "manual") |> normalize_enum_string("manual")
    goal_id = Keyword.get(opts, :goal_id)

    case review_goals_for_request(user_id, goal_id, opts) do
      {:ok, goals} ->
        case record_review_run(user_id, %{
               "goal_id" => if(length(goals) == 1, do: hd(goals).id),
               "trigger" => trigger,
               "status" => "running",
               "started_at" => now,
               "source_summary" => %{"sources" => ["goals"], "mode" => "manual_stub"},
               "metadata" => %{"requested_goal_id" => goal_id}
             }) do
          {:ok, run} ->
            result = %{
              "goals_checked" => length(goals),
              "progress_updates_count" => 0,
              "todos_count" => 0,
              "links_count" => 0,
              "notes" => [
                "Recorded a goal alignment review run. Source-backed review will add findings when the Chief of Staff skill runs."
              ]
            }

            complete_review_run(user_id, run.id, %{
              "status" => if(goals == [], do: "partial", else: "completed"),
              "result" => result,
              "finished_at" => now
            })

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def review_goal_alignment(_user_id, _opts), do: {:error, :invalid_user}

  def apply_review_output(user_id, review_run_id, output, opts \\ [])

  def apply_review_output(user_id, review_run_id, output, opts)
      when is_binary(user_id) and is_binary(review_run_id) and is_map(output) and is_list(opts) do
    case Repo.get_by(ReviewRun, id: review_run_id, user_id: user_id) do
      %ReviewRun{} = run ->
        Repo.transaction(fn ->
          now = Keyword.get(opts, :now, DateTime.utc_now())

          {progress_updates, progress_skips} =
            output
            |> read_list("progress_updates")
            |> apply_review_items("progress_update", &insert_review_progress(user_id, &1, now))

          {resource_links, link_skips} =
            output
            |> read_list("resource_links")
            |> apply_review_items("resource_link", &insert_review_link(user_id, &1))

          {todo_links, todo_skips} =
            output
            |> read_list("todo_candidates")
            |> apply_review_items("todo_candidate", &insert_review_todo(user_id, run, &1, now))

          reviewed_goal_ids =
            output
            |> reviewed_goal_ids(run, progress_updates, resource_links, todo_links)
            |> update_reviewed_goals!(user_id, now)

          advice = output |> read_list("advice") |> normalize_review_advice()
          findings = output |> read_list("findings") |> normalize_review_findings()
          skipped_outputs = progress_skips ++ link_skips ++ todo_skips

          summary = %{
            "progress_updates_count" => length(progress_updates),
            "links_count" => length(resource_links) + length(todo_links),
            "todos_count" => length(todo_links),
            "skipped_outputs_count" => length(skipped_outputs),
            "skipped_outputs" => skipped_outputs,
            "reviewed_goal_ids" => reviewed_goal_ids,
            "advice" => advice,
            "findings" => findings
          }

          {:ok, updated_run} =
            complete_review_run(user_id, run.id, %{
              "status" => if(skipped_outputs == [], do: "completed", else: "partial"),
              "finished_at" => now,
              "result" => Map.merge(run.result || %{}, summary)
            })

          %{
            review_run: updated_run,
            progress_updates: progress_updates,
            resource_links: resource_links ++ todo_links,
            summary: summary
          }
        end)
        |> case do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def apply_review_output(_user_id, _review_run_id, _output, _opts),
    do: {:error, :invalid_goal_review_output}

  defp review_goals_for_request(user_id, goal_id, _opts) when is_binary(goal_id) do
    case get_goal(user_id, goal_id, preload: false) do
      %Goal{} = goal -> {:ok, [goal]}
      nil -> {:error, :not_found}
    end
  end

  defp review_goals_for_request(user_id, _goal_id, opts) do
    {:ok, list_goals(user_id, status: "active", limit: Keyword.get(opts, :limit, 20))}
  end

  def serialize_goal(%Goal{} = goal, opts \\ []) do
    latest_progress = Keyword.get(opts, :latest_progress) || latest_progress_for_goal(goal)
    counts = Keyword.get(opts, :link_counts) || link_counts_for_goal(goal)

    %{
      id: goal.id,
      category: goal.category,
      status: goal.status,
      title: goal.title,
      desired_outcome: goal.desired_outcome,
      why: goal.why,
      success_metric: goal.success_metric,
      priority: goal.priority,
      sensitivity: goal.sensitivity,
      proactive_visibility: goal.proactive_visibility,
      review_cadence: goal.review_cadence,
      starts_on: json_value(goal.starts_on),
      target_at: json_value(goal.target_at),
      last_reviewed_at: json_value(goal.last_reviewed_at),
      next_review_at: json_value(goal.next_review_at),
      linked_work_count: Map.get(counts, "todo", 0),
      linked_people_count: Map.get(counts, "person", 0),
      latest_progress: progress_snapshot(latest_progress),
      inserted_at: json_value(goal.inserted_at),
      updated_at: json_value(goal.updated_at)
    }
  end

  def serialize_progress(%ProgressUpdate{} = progress_update, opts \\ []) do
    base = %{
      id: progress_update.id,
      goal_id: progress_update.goal_id,
      source: progress_update.source,
      summary: progress_update.summary,
      progress_state: progress_update.progress_state,
      confidence: progress_update.confidence,
      occurred_at: json_value(progress_update.occurred_at),
      inserted_at: json_value(progress_update.inserted_at)
    }

    if Keyword.get(opts, :include_evidence, false) do
      Map.merge(base, %{
        evidence: progress_update.evidence || %{},
        metadata: progress_update.metadata || %{}
      })
    else
      base
    end
  end

  def serialize_link(%GoalLink{} = link) do
    %{
      id: link.id,
      goal_id: link.goal_id,
      resource_type: link.resource_type,
      resource_id: link.resource_id,
      relationship: link.relationship,
      source: link.source,
      confidence: link.confidence,
      metadata: link.metadata || %{},
      inserted_at: json_value(link.inserted_at),
      updated_at: json_value(link.updated_at)
    }
  end

  def serialize_review_run(%ReviewRun{} = review_run) do
    %{
      id: review_run.id,
      goal_id: review_run.goal_id,
      trigger: review_run.trigger,
      status: review_run.status,
      started_at: json_value(review_run.started_at),
      finished_at: json_value(review_run.finished_at),
      source_summary: review_run.source_summary || %{},
      result: review_run.result || %{},
      error: review_run.error || %{},
      metadata: review_run.metadata || %{},
      inserted_at: json_value(review_run.inserted_at),
      updated_at: json_value(review_run.updated_at)
    }
  end

  defp normalize_goal_create_attrs(user_id, attrs, opts) do
    attrs =
      attrs
      |> stringify_keys()
      |> strip_public_goal_attrs(opts)

    now = Keyword.get(opts, :now, DateTime.utc_now())
    category = attrs |> read_string("category", "work") |> normalize_enum_string("work")
    status = attrs |> read_string("status", "active") |> normalize_enum_string("active")

    cadence =
      attrs
      |> read_string("review_cadence", default_cadence(category))
      |> normalize_enum_string(default_cadence(category))

    sensitivity =
      attrs
      |> read_string("sensitivity", default_sensitivity(category))
      |> normalize_enum_string(default_sensitivity(category))

    visibility =
      attrs
      |> read_string("proactive_visibility", default_visibility(sensitivity))
      |> normalize_enum_string(default_visibility(sensitivity))

    attrs
    |> Map.put("user_id", String.trim(user_id))
    |> Map.put("category", category)
    |> Map.put("status", status)
    |> Map.put("review_cadence", cadence)
    |> Map.put("sensitivity", sensitivity)
    |> Map.put("proactive_visibility", visibility)
    |> Map.put_new("priority", 50)
    |> Map.put_new("starts_on", Date.utc_today())
    |> Map.put_new("metadata", %{})
    |> put_computed_next_review(status, cadence, now)
  end

  defp normalize_goal_update_attrs(%Goal{} = goal, attrs, opts) do
    attrs =
      attrs
      |> stringify_keys()
      |> strip_public_goal_attrs(opts)

    now = Keyword.get(opts, :now, DateTime.utc_now())

    recompute_review? =
      Map.has_key?(attrs, "status") or Map.has_key?(attrs, "review_cadence") or
        Map.has_key?(attrs, "category")

    category =
      attrs |> read_string("category", goal.category) |> normalize_enum_string(goal.category)

    status = attrs |> read_string("status", goal.status) |> normalize_enum_string(goal.status)

    cadence =
      attrs
      |> read_string("review_cadence", goal.review_cadence)
      |> normalize_enum_string(goal.review_cadence)

    sensitivity =
      attrs
      |> read_string(
        "sensitivity",
        if(Map.has_key?(attrs, "category"),
          do: default_sensitivity(category),
          else: goal.sensitivity
        )
      )
      |> normalize_enum_string(goal.sensitivity)

    visibility =
      attrs
      |> read_string(
        "proactive_visibility",
        if(Map.has_key?(attrs, "sensitivity"),
          do: default_visibility(sensitivity),
          else: goal.proactive_visibility
        )
      )
      |> normalize_enum_string(goal.proactive_visibility)

    attrs =
      attrs
      |> Map.put("category", category)
      |> Map.put("status", status)
      |> Map.put("review_cadence", cadence)
      |> Map.put("sensitivity", sensitivity)
      |> Map.put("proactive_visibility", visibility)

    if recompute_review? do
      put_computed_next_review(attrs, status, cadence, now)
    else
      attrs
    end
  end

  defp put_computed_next_review(attrs, "active", cadence, now) do
    Map.put_new(attrs, "next_review_at", next_review_at(cadence, now))
  end

  defp put_computed_next_review(attrs, _status, _cadence, _now) do
    Map.put(attrs, "next_review_at", nil)
  end

  defp next_review_at("daily", %DateTime{} = now), do: DateTime.add(now, 1, :day)
  defp next_review_at("weekly", %DateTime{} = now), do: DateTime.add(now, 7, :day)
  defp next_review_at("monthly", %DateTime{} = now), do: DateTime.add(now, 30, :day)
  defp next_review_at(_cadence, _now), do: nil

  defp default_cadence("life"), do: "monthly"
  defp default_cadence(_category), do: "weekly"

  defp default_sensitivity("work"), do: "standard"
  defp default_sensitivity(_category), do: "sensitive"

  defp default_visibility("private"), do: "none"
  defp default_visibility(_sensitivity), do: "summary"

  defp normalize_progress_attrs(user_id, goal_id, attrs, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    attrs
    |> stringify_keys()
    |> Map.put("user_id", String.trim(user_id))
    |> Map.put("goal_id", goal_id)
    |> Map.put_new("source", Keyword.get(opts, :source, "manual"))
    |> Map.put_new("progress_state", "unknown")
    |> Map.put_new("occurred_at", now)
    |> Map.put_new("evidence", %{})
    |> Map.put_new("metadata", %{})
  end

  defp normalize_link_attrs(user_id, goal_id, attrs, opts) do
    attrs
    |> stringify_keys()
    |> Map.put("user_id", String.trim(user_id))
    |> Map.put("goal_id", goal_id)
    |> Map.put_new("relationship", "context")
    |> Map.put_new("source", Keyword.get(opts, :source, "manual"))
    |> Map.put_new("metadata", %{})
  end

  defp normalize_review_run_attrs(user_id, attrs, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    attrs
    |> stringify_keys()
    |> Map.put("user_id", String.trim(user_id))
    |> Map.put_new("trigger", "manual")
    |> Map.put_new("status", "running")
    |> Map.put_new("started_at", now)
    |> Map.put_new("source_summary", %{})
    |> Map.put_new("result", %{})
    |> Map.put_new("error", %{})
    |> Map.put_new("metadata", %{})
  end

  defp validate_linked_resource(user_id, "todo", resource_id),
    do: owned_uuid?(Todo, user_id, resource_id)

  defp validate_linked_resource(user_id, "person", resource_id),
    do: owned_uuid?(Person, user_id, resource_id)

  defp validate_linked_resource(user_id, "insight", resource_id),
    do: owned_uuid?(Insight, user_id, resource_id)

  defp validate_linked_resource(user_id, "brief", resource_id),
    do: owned_uuid?(Brief, user_id, resource_id)

  defp validate_linked_resource(user_id, "chat_thread", resource_id),
    do: owned_uuid?(Conversation, user_id, resource_id)

  defp validate_linked_resource(user_id, "memory", resource_id),
    do: owned_uuid?(MemoryItem, user_id, resource_id)

  defp validate_linked_resource(user_id, "scheduled_task", resource_id),
    do: owned_uuid?(ScheduledTask, user_id, resource_id)

  defp validate_linked_resource(_user_id, "source_observation", resource_id)
       when is_binary(resource_id) and resource_id != "",
       do: :ok

  defp validate_linked_resource(_user_id, _resource_type, _resource_id),
    do: {:error, :linked_resource_not_found}

  defp owned_uuid?(schema, user_id, resource_id) when is_binary(resource_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(resource_id),
         %{} <- Repo.get_by(schema, id: uuid, user_id: user_id) do
      :ok
    else
      _other -> {:error, :linked_resource_not_found}
    end
  end

  defp owned_uuid?(_schema, _user_id, _resource_id), do: {:error, :linked_resource_not_found}

  defp insert_review_progress(user_id, attrs, now) do
    attrs = stringify_keys(attrs)
    goal_id = read_string(attrs, "goal_id")

    case record_progress(user_id, goal_id, attrs, now: now, source: "agent") do
      {:ok, progress_update} -> {:ok, progress_update}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_review_link(user_id, attrs) do
    attrs = stringify_keys(attrs)
    goal_id = read_string(attrs, "goal_id")

    case link_resource(user_id, goal_id, Map.put_new(attrs, "source", "agent")) do
      {:ok, link} -> {:ok, link}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_review_todo(user_id, %ReviewRun{} = run, attrs, now) do
    attrs = stringify_keys(attrs)
    goal_id = read_string(attrs, "goal_id")

    with %Goal{} = goal <- get_goal(user_id, goal_id, preload: false),
         :ok <- validate_goal_link_confidence(attrs),
         {:ok, todo_attrs} <- review_todo_attrs(user_id, goal, run, attrs, now),
         {:ok, [todo]} <- Todos.upsert_many(user_id, [todo_attrs], actor_opts(user_id)) do
      case link_resource(user_id, goal.id, %{
             "resource_type" => "todo",
             "resource_id" => todo.id,
             "relationship" => "next_move",
             "source" => "agent",
             "confidence" => read_float(attrs, "confidence"),
             "metadata" => %{"goal_review_run_id" => run.id}
           }) do
        {:ok, link} -> {:ok, link}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_goal_link_confidence(attrs) do
    case read_float(attrs, "confidence") do
      nil -> :ok
      value when value >= 0.0 and value <= 1.0 -> :ok
      _value -> {:error, :invalid_goal_todo_candidate_confidence}
    end
  end

  defp apply_review_items(items, kind, apply_fun) do
    items
    |> Enum.reduce({[], []}, fn item, {applied, skipped} ->
      case apply_fun.(item) do
        {:ok, value} ->
          {[value | applied], skipped}

        {:error, reason} ->
          {applied, [skipped_review_output(kind, item, reason) | skipped]}
      end
    end)
    |> then(fn {applied, skipped} -> {Enum.reverse(applied), Enum.reverse(skipped)} end)
  end

  defp skipped_review_output(kind, item, reason) do
    item = stringify_keys(item)

    %{
      "kind" => kind,
      "goal_id" => read_string(item, "goal_id"),
      "reason" => review_skip_reason(reason)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp review_skip_reason(%Ecto.Changeset{}), do: "invalid_changeset"
  defp review_skip_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp review_skip_reason(reason) when is_binary(reason), do: reason
  defp review_skip_reason(_reason), do: "invalid_review_output"

  defp review_todo_attrs(user_id, %Goal{} = goal, %ReviewRun{} = run, attrs, _now) do
    title = read_string(attrs, "title")
    summary = read_string(attrs, "summary")
    next_action = read_string(attrs, "next_action")
    evidence = read_map(attrs, "evidence")
    evidence_summary = read_string(evidence, "redacted_summary")

    cond do
      is_nil(title) or String.length(title) < 4 ->
        {:error, :invalid_goal_todo_candidate}

      is_nil(summary) or String.length(summary) < 4 ->
        {:error, :invalid_goal_todo_candidate}

      is_nil(next_action) or String.length(next_action) < 4 ->
        {:error, :invalid_goal_todo_candidate}

      is_nil(evidence_summary) or String.length(evidence_summary) < 4 ->
        {:error, :goal_todo_candidate_missing_evidence}

      true ->
        todo_attrs =
          %{
            "user_id" => user_id,
            "source" => "goals",
            "kind" => "general",
            "attention_mode" => read_string(attrs, "attention_mode", "act_now"),
            "title" => title,
            "summary" => summary,
            "next_action" => next_action,
            "priority" => read_integer(attrs, "priority", goal.priority || 50),
            "due_at" => Map.get(attrs, "due_at"),
            "dedupe_key" =>
              read_string(attrs, "dedupe_key") || goal_todo_dedupe_key(goal, title, next_action),
            "metadata" => %{
              "goal_id" => goal.id,
              "goal_category" => goal.category,
              "goal_review_run_id" => run.id,
              "evidence_summary" => evidence_summary,
              "source_refs" => read_list(evidence, "source_refs")
            }
          }
          |> SurfaceQuality.annotate_attrs()

        {:ok, todo_attrs}
    end
  end

  defp goal_todo_dedupe_key(%Goal{} = goal, title, next_action) do
    digest =
      :crypto.hash(:sha256, "#{goal.id}:#{title}:#{next_action}")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    "goal:#{goal.id}:#{digest}"
  end

  defp actor_opts(user_id) do
    [
      actor_type: "agent",
      actor_id: "goal_alignment",
      actor_label: "Goal alignment",
      source: "goals",
      user_id: user_id
    ]
  end

  defp preload_goal_detail(%Goal{} = goal) do
    Repo.preload(goal,
      progress_updates:
        from(update in ProgressUpdate,
          order_by: [desc: update.occurred_at, desc: update.inserted_at],
          limit: 50
        ),
      links: from(link in GoalLink, order_by: [desc: link.inserted_at]),
      review_runs:
        from(run in ReviewRun,
          order_by: [desc: run.started_at],
          limit: 20
        )
    )
  end

  defp maybe_filter_status(query, status) when status in [nil, "", "all"], do: query

  defp maybe_filter_status(query, status) when is_atom(status),
    do: maybe_filter_status(query, Atom.to_string(status))

  defp maybe_filter_status(query, status) when is_binary(status) do
    normalized = normalize_enum_string(status, "active")
    where(query, [goal], goal.status == ^normalized)
  end

  defp maybe_filter_category(query, category) when category in [nil, "", "all"], do: query

  defp maybe_filter_category(query, category) when is_atom(category),
    do: maybe_filter_category(query, Atom.to_string(category))

  defp maybe_filter_category(query, category) when is_binary(category) do
    normalized = normalize_enum_string(category, "work")
    where(query, [goal], goal.category == ^normalized)
  end

  defp maybe_filter_sensitivity(query, sensitivity) when sensitivity in [nil, "", "all"],
    do: query

  defp maybe_filter_sensitivity(query, sensitivity) when is_binary(sensitivity) do
    normalized = normalize_enum_string(sensitivity, "standard")
    where(query, [goal], goal.sensitivity == ^normalized)
  end

  defp maybe_filter_query(query, value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        query

      term ->
        like = "%#{term}%"

        where(
          query,
          [goal],
          ilike(goal.title, ^like) or ilike(goal.desired_outcome, ^like) or
            ilike(goal.why, ^like) or ilike(goal.success_metric, ^like)
        )
    end
  end

  defp maybe_filter_query(query, _value), do: query

  defp maybe_filter_user(query, user_id) when is_binary(user_id),
    do: where(query, [goal], goal.user_id == ^user_id)

  defp maybe_filter_user(query, _user_id), do: query

  defp maybe_exclude_private(query, true), do: query

  defp maybe_exclude_private(query, _false),
    do: where(query, [goal], goal.sensitivity != "private")

  defp count_goals(user_id, opts) do
    status = Keyword.get(opts, :status)

    Goal
    |> where([goal], goal.user_id == ^user_id)
    |> maybe_filter_status(status || "all")
    |> Repo.aggregate(:count)
  end

  defp count_review_due(user_id, now) do
    Goal
    |> where([goal], goal.user_id == ^user_id and goal.status == "active")
    |> where([goal], not is_nil(goal.next_review_at) and goal.next_review_at <= ^now)
    |> Repo.aggregate(:count)
  end

  defp count_private_active(user_id) do
    Goal
    |> where(
      [goal],
      goal.user_id == ^user_id and goal.status == "active" and goal.sensitivity == "private"
    )
    |> Repo.aggregate(:count)
  end

  defp count_latest_progress_states(user_id, states) do
    goals = list_goals(user_id, status: "active", limit: @max_limit)
    goal_ids = Enum.map(goals, & &1.id)

    latest_progress_by_goal_id(user_id, goal_ids)
    |> Map.values()
    |> Enum.count(&(&1.progress_state in states))
  end

  defp latest_progress_by_goal_id(_user_id, []), do: %{}

  defp latest_progress_by_goal_id(user_id, goal_ids) do
    ProgressUpdate
    |> where([update], update.user_id == ^user_id and update.goal_id in ^goal_ids)
    |> order_by([update], desc: update.occurred_at, desc: update.inserted_at)
    |> Repo.all()
    |> Enum.reduce(%{}, fn update, acc ->
      Map.put_new(acc, update.goal_id, update)
    end)
  end

  defp link_counts_by_goal_id(_user_id, []), do: %{}

  defp link_counts_by_goal_id(user_id, goal_ids) do
    GoalLink
    |> where([link], link.user_id == ^user_id and link.goal_id in ^goal_ids)
    |> group_by([link], [link.goal_id, link.resource_type])
    |> select([link], {link.goal_id, link.resource_type, count(link.id)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {goal_id, resource_type, count}, acc ->
      Map.update(acc, goal_id, %{resource_type => count}, &Map.put(&1, resource_type, count))
    end)
  end

  defp latest_progress_for_goal(%Goal{id: goal_id, user_id: user_id}) do
    ProgressUpdate
    |> where([update], update.user_id == ^user_id and update.goal_id == ^goal_id)
    |> order_by([update], desc: update.occurred_at, desc: update.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp link_counts_for_goal(%Goal{id: goal_id, user_id: user_id}) do
    link_counts_by_goal_id(user_id, [goal_id])
    |> Map.get(goal_id, %{})
  end

  defp reviewed_goal_ids(output, %ReviewRun{} = run, progress_updates, resource_links, todo_links) do
    output_ids =
      output
      |> read_list("reviewed_goal_ids")
      |> Enum.filter(&is_binary/1)

    run_ids =
      case run.goal_id do
        goal_id when is_binary(goal_id) -> [goal_id]
        _other -> []
      end

    progress_ids = Enum.map(progress_updates, & &1.goal_id)
    link_ids = Enum.map(resource_links ++ todo_links, & &1.goal_id)

    (output_ids ++ run_ids ++ progress_ids ++ link_ids)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp update_reviewed_goals!([], _user_id, _now), do: []

  defp update_reviewed_goals!(goal_ids, user_id, now) do
    goal_ids
    |> Enum.reduce([], fn goal_id, acc ->
      case update_goal(
             user_id,
             goal_id,
             %{
               "last_reviewed_at" => now,
               "next_review_at" =>
                 user_id
                 |> get_goal(goal_id, preload: false)
                 |> case do
                   %Goal{} = goal -> next_review_at(goal.review_cadence, now)
                   nil -> nil
                 end
             },
             allow_internal_fields: true
           ) do
        {:ok, goal} -> [goal.id | acc]
        {:error, :not_found} -> acc
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_review_advice(items) when is_list(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_keys/1)
    |> Enum.map(fn item ->
      item
      |> Map.take(~w(goal_id headline summary source_refs confidence urgency))
      |> Map.update("source_refs", [], fn refs ->
        refs
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.take(8)
      end)
    end)
    |> Enum.reject(&map_empty_or_missing_text?(&1, "summary"))
    |> Enum.take(12)
  end

  defp normalize_review_advice(_items), do: []

  defp normalize_review_findings(items) when is_list(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_keys/1)
    |> Enum.map(fn item ->
      item
      |> Map.take(~w(goal_id kind summary source_refs confidence))
      |> Map.update("source_refs", [], fn refs ->
        refs
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.take(8)
      end)
    end)
    |> Enum.reject(&map_empty_or_missing_text?(&1, "summary"))
    |> Enum.take(20)
  end

  defp normalize_review_findings(_items), do: []

  defp map_empty_or_missing_text?(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value) == ""
      _other -> true
    end
  end

  defp linked_open_work(user_id, limit) do
    links =
      GoalLink
      |> where([link], link.user_id == ^user_id and link.resource_type == "todo")
      |> where([link], link.relationship in ["next_move", "supports", "progress", "context"])
      |> order_by([link], desc: link.inserted_at)
      |> limit(^(limit * 4))
      |> Repo.all()

    todo_ids = links |> Enum.map(& &1.resource_id) |> Enum.uniq()
    goal_ids = links |> Enum.map(& &1.goal_id) |> Enum.uniq()

    todos_by_id =
      user_id
      |> Todos.list_by_ids(todo_ids, statuses: @open_statuses, open_due_only: false)
      |> Map.new(&{&1.id, &1})

    goals_by_id =
      Goal
      |> where([goal], goal.user_id == ^user_id and goal.id in ^goal_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    links
    |> Enum.reduce([], fn link, acc ->
      with %Todo{} = todo <- Map.get(todos_by_id, link.resource_id),
           %Goal{} = goal <- Map.get(goals_by_id, link.goal_id) do
        [
          %{
            goal: compact_goal(goal),
            todo: compact_todo(todo),
            relationship: link.relationship
          }
          | acc
        ]
      else
        _other -> acc
      end
    end)
    |> Enum.reverse()
    |> Enum.take(limit)
  end

  defp compact_goal(%Goal{} = goal) do
    %{
      id: goal.id,
      title: goal.title,
      category: goal.category,
      status: goal.status,
      priority: goal.priority,
      sensitivity: goal.sensitivity,
      proactive_visibility: goal.proactive_visibility,
      next_review_at: json_value(goal.next_review_at),
      target_at: json_value(goal.target_at)
    }
  end

  defp compact_todo(%Todo{} = todo) do
    %{
      id: todo.id,
      title: todo.title,
      summary: todo.summary,
      next_action: todo.next_action,
      status: todo.status,
      priority: todo.priority,
      due_at: json_value(todo.due_at)
    }
  end

  defp progress_snapshot(nil), do: nil

  defp progress_snapshot(%ProgressUpdate{} = progress_update) do
    %{
      "progress_state" => progress_update.progress_state,
      "summary" => progress_update.summary,
      "occurred_at" => json_value(progress_update.occurred_at)
    }
  end

  defp maybe_update_goal_review_timestamp(%ReviewRun{
         goal_id: goal_id,
         user_id: user_id,
         status: status,
         finished_at: %DateTime{} = finished_at
       })
       when status in ["completed", "partial"] and is_binary(goal_id) do
    case get_goal(user_id, goal_id, preload: false) do
      %Goal{} = goal ->
        update_goal(
          user_id,
          goal.id,
          %{
            "last_reviewed_at" => finished_at,
            "next_review_at" => next_review_at(goal.review_cadence, finished_at)
          },
          allow_internal_fields: true
        )

      nil ->
        :ok
    end
  end

  defp maybe_update_goal_review_timestamp(_review_run), do: :ok

  defp clamp_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp clamp_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> clamp_limit(integer)
      :error -> @default_limit
    end
  end

  defp clamp_limit(_value), do: @default_limit

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
      {_key, _value}, acc -> acc
    end)
  end

  defp stringify_keys(_value), do: %{}

  defp strip_public_goal_attrs(attrs, opts) do
    if Keyword.get(opts, :allow_internal_fields, false) do
      attrs
    else
      Map.drop(attrs, @internal_goal_attrs)
    end
  end

  defp read_list(map, key) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, safe_existing_atom(key))
    if is_list(value), do: value, else: []
  end

  defp read_map(map, key) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, safe_existing_atom(key))
    if is_map(value), do: value, else: %{}
  end

  defp read_string(map, key, default \\ nil)

  defp read_string(map, key, default) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, safe_existing_atom(key)) || default

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          normalized -> normalized
        end

      nil ->
        default

      value ->
        to_string(value)
    end
  end

  defp read_string(_map, _key, default), do: default

  defp read_integer(map, key, default) when is_map(map) do
    case Map.get(map, key) || Map.get(map, safe_existing_atom(key)) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, _rest} -> integer
          :error -> default
        end

      _other ->
        default
    end
  end

  defp read_float(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, safe_existing_atom(key)) do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value / 1

      value when is_binary(value) ->
        case Float.parse(value) do
          {float, _rest} -> float
          :error -> nil
        end

      _other ->
        nil
    end
  end

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__maraithon_missing_key__
  end

  defp normalize_enum_string(value, default) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> default
      normalized -> normalized
    end
  end

  defp normalize_enum_string(_value, default), do: default

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_value(nil), do: nil
  defp json_value(value), do: value

  defp emit_goal_event(kind, %Goal{} = goal, metadata) do
    :telemetry.execute(
      [:maraithon, :goals, kind],
      %{count: 1},
      Map.merge(metadata, %{
        user_id_hash: user_id_hash(goal.user_id),
        category: goal.category,
        sensitivity: goal.sensitivity,
        status: goal.status
      })
    )
  end

  defp user_id_hash(user_id) when is_binary(user_id) do
    :crypto.hash(:sha256, user_id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp user_id_hash(_user_id), do: nil
end
