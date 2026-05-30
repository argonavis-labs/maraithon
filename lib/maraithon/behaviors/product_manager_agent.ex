defmodule Maraithon.Behaviors.ProductManagerAgent do
  @moduledoc """
  Long-lived PM agent for one project/repository.

  The public behavior id is still `github_product_planner` for package and
  installation compatibility, but the runtime module now represents the
  broader Product Manager agent: it reads project context, goals, repository
  state, and open tasks, then writes proposed backlog tickets back into
  Maraithon's task surfaces.
  """

  @behaviour Maraithon.Behaviors.Behavior

  import Ecto.Query

  alias Maraithon.GitHubRepoSnapshot
  alias Maraithon.Insights
  alias Maraithon.Insights.Insight
  alias Maraithon.Projects
  alias Maraithon.Projects.Project
  alias Maraithon.Repo
  alias Maraithon.Todos

  require Logger

  @default_base_branch "main"
  @default_ticket_limit 3
  @default_wakeup_interval_ms :timer.hours(24 * 7)
  @default_goals_path "GOALS.md"
  @default_telegram_fit_score 0.98
  @max_list_items 5
  @max_evidence_points 5

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      project_id: normalize_string(config["project_id"]),
      repo_full_name: normalize_string(config["repo_full_name"]),
      base_branch: normalize_string(config["base_branch"]) || @default_base_branch,
      feature_limit: to_ticket_limit(config["feature_limit"], @default_ticket_limit),
      wakeup_interval_ms:
        to_positive_integer(config["wakeup_interval_ms"], @default_wakeup_interval_ms),
      goals_path: normalize_string(config["goals_path"]) || @default_goals_path,
      pending_snapshot: nil,
      pending_project_context: nil,
      pending_plan_date: nil,
      pending_run_key: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    state = ensure_runtime_scope(state, context)
    timestamp = context[:timestamp] || DateTime.utc_now()
    plan_date = DateTime.to_date(timestamp) |> Date.to_iso8601()
    run_key = run_key_for(context, timestamp)

    cond do
      is_nil(state.user_id) ->
        Logger.warning("ProductManagerAgent skipped wakeup: user_id missing",
          agent_id: context.agent_id
        )

        {:idle, state}

      is_nil(state.repo_full_name) ->
        Logger.warning("ProductManagerAgent skipped wakeup: repo_full_name missing",
          agent_id: context.agent_id
        )

        {:idle, state}

      already_planned_for_run?(state.user_id, state.repo_full_name, run_key, plan_date) ->
        {:idle, state}

      true ->
        case GitHubRepoSnapshot.fetch(state.user_id, state.repo_full_name, state.base_branch) do
          {:ok, snapshot} ->
            project_context = build_project_context(state, context)

            params = %{
              "messages" => [
                %{
                  "role" => "user",
                  "content" =>
                    build_llm_prompt(
                      snapshot,
                      project_context,
                      context,
                      timestamp,
                      state.feature_limit,
                      Map.get(context, :user_memory, %{})
                    )
                }
              ],
              "max_tokens" => 2_400,
              "temperature" => 0.3
            }

            {:effect, {:llm_call, params},
             %{
               state
               | pending_snapshot: snapshot,
                 pending_project_context: project_context,
                 pending_plan_date: plan_date,
                 pending_run_key: run_key
             }}

          {:error, reason} ->
            Logger.warning("ProductManagerAgent failed to fetch repo snapshot",
              repo_full_name: state.repo_full_name,
              reason: inspect(reason)
            )

            {:emit,
             {:planning_error, %{repo_full_name: state.repo_full_name, reason: inspect(reason)}},
             state}
        end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    snapshot = state.pending_snapshot || %{}
    project_context = state.pending_project_context || %{}
    timestamp = context[:timestamp] || DateTime.utc_now()

    plan_date =
      state.pending_plan_date || DateTime.to_date(timestamp) |> Date.to_iso8601()

    run_key = state.pending_run_key || run_key_for(context, timestamp)

    insights =
      parse_llm_response(response.content, snapshot, project_context, state, plan_date, run_key)
      |> Enum.take(state.feature_limit)

    {:ok, stored} = Insights.record_many(state.user_id, context.agent_id, insights)
    {:ok, todos} = Todos.sync_many_from_insights(stored)

    project_items =
      maybe_write_project_items(project_context[:project], stored)

    {:emit,
     {:insights_recorded,
      %{
        count: length(stored),
        task_count: length(todos),
        project_item_count: length(project_items),
        user_id: state.user_id,
        project_id: project_context[:project] && project_context.project.id,
        categories: stored |> Enum.map(& &1.category) |> Enum.uniq()
      }},
     %{
       state
       | pending_snapshot: nil,
         pending_project_context: nil,
         pending_plan_date: nil,
         pending_run_key: nil
     }}
  end

  def handle_effect_result({:tool_call, _result}, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(state), do: {:relative, state.wakeup_interval_ms}

  defp ensure_runtime_scope(state, context) do
    %{
      state
      | user_id: state.user_id || normalize_string(context[:user_id]),
        project_id: state.project_id || normalize_string(context[:project_id])
    }
  end

  defp already_planned_for_run?(user_id, repo_full_name, run_key, plan_date) do
    run_prefix = "#{dedupe_prefix(repo_full_name, run_key)}:%"
    legacy_date_prefix = "github_feature_plan:#{repo_full_name}:#{plan_date}:%"

    Insight
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.category == "product_opportunity")
    |> where([i], like(i.dedupe_key, ^run_prefix) or like(i.dedupe_key, ^legacy_date_prefix))
    |> Repo.exists?()
  end

  defp build_project_context(state, context) do
    project = load_project(state.user_id, state.project_id)

    %{
      project: project,
      goals_doc: read_goals_doc(state.goals_path),
      open_tasks: open_tasks_for_prompt(state.user_id, project),
      project_items: project_items_for_prompt(state.user_id, project),
      trigger: trigger_for_prompt(context)
    }
  end

  defp load_project(user_id, project_id) when is_binary(user_id) and is_binary(project_id) do
    Projects.get_project_for_user(project_id, user_id)
  end

  defp load_project(user_id, _project_id) when is_binary(user_id) do
    Projects.default_project_for_user(user_id)
  end

  defp load_project(_user_id, _project_id), do: nil

  defp read_goals_doc(path) do
    root = File.cwd!()
    expanded = Path.expand(path || @default_goals_path, root)

    if String.starts_with?(expanded, root) and File.regular?(expanded) do
      expanded
      |> File.read!()
      |> truncate_text(10_000)
    else
      nil
    end
  end

  defp open_tasks_for_prompt(nil, _project), do: []

  defp open_tasks_for_prompt(user_id, %Project{} = project) do
    user_id
    |> Todos.list_for_user(limit: 30, statuses: ["open", "snoozed"])
    |> Enum.filter(&todo_belongs_to_project?(&1, project))
    |> Enum.take(12)
    |> Enum.map(&Todos.serialize_for_prompt/1)
  end

  defp open_tasks_for_prompt(user_id, _project) do
    user_id
    |> Todos.list_for_user(limit: 12, statuses: ["open", "snoozed"])
    |> Enum.map(&Todos.serialize_for_prompt/1)
  end

  defp todo_belongs_to_project?(todo, %Project{} = project) do
    metadata = todo.metadata || %{}

    Map.get(metadata, "project_id") == project.id or
      Map.get(metadata, "suggested_project_id") == project.id or
      Map.get(metadata, "source_project_id") == project.id
  end

  defp project_items_for_prompt(user_id, %Project{} = project) do
    Projects.list_project_items(user_id: user_id, project_id: project.id, limit: 12)
    |> Enum.map(fn item ->
      %{
        id: item.id,
        item_type: item.item_type,
        title: item.title,
        content: item.content,
        status: item.status,
        source: item.source,
        metadata: item.metadata || %{}
      }
    end)
  end

  defp project_items_for_prompt(_user_id, _project), do: []

  defp trigger_for_prompt(context) do
    %{
      trigger: Map.get(context, :trigger),
      last_message: Map.get(context, :last_message),
      event: Map.get(context, :event)
    }
  end

  defp parse_llm_response(content, snapshot, project_context, state, plan_date, run_key)
       when is_binary(content) do
    with {:ok, decoded} <- decode_json_payload(content),
         list when is_list(list) <- extract_ticket_list(decoded) do
      list
      |> Enum.with_index(1)
      |> Enum.reduce([], fn {item, index}, acc ->
        case ticket_to_insight(item, index, snapshot, project_context, state, plan_date, run_key) do
          nil -> acc
          insight -> [insight | acc]
        end
      end)
      |> Enum.reverse()
    else
      _ -> []
    end
  end

  defp parse_llm_response(_content, _snapshot, _project_context, _state, _plan_date, _run_key),
    do: []

  defp ticket_to_insight(item, index, snapshot, project_context, _state, plan_date, run_key)
       when is_map(item) do
    title = read_string(item, "title", nil)
    summary = read_string(item, "summary", nil)

    recommended_action =
      read_string(item, "next_action", nil) ||
        read_string(item, "recommended_action", nil) ||
        read_string(item, "first_milestone", nil)

    if Enum.any?([title, summary, recommended_action], &is_nil/1) do
      nil
    else
      project = project_context[:project]
      priority = clamp(read_integer(item, "priority", 82), 60, 95)
      confidence = clamp(read_float(item, "confidence", 0.82), 0.55, 0.99)
      why_now = read_string(item, "why_now", nil)

      acceptance_criteria =
        read_string_list(item, "acceptance_criteria")
        |> Enum.take(@max_list_items)

      follow_up_ideas =
        read_string_list(item, "follow_up_ideas")
        |> Enum.take(@max_list_items)

      evidence =
        read_string_list(item, "evidence")
        |> Enum.take(@max_evidence_points)

      metadata =
        %{
          "project_id" => project && project.id,
          "project_name" => project && project.name,
          "repo_full_name" => snapshot.repo_full_name,
          "base_branch" => snapshot.base_branch,
          "planner_date" => plan_date,
          "planner_run_key" => run_key,
          "planner_type" => "product_manager_agent",
          "source_behavior" => "github_product_planner",
          "latest_commit_sha" => snapshot.latest_commit_sha,
          "latest_commit_message" => snapshot.latest_commit_message,
          "telegram_fit_score" =>
            clamp(read_float(item, "telegram_fit_score", @default_telegram_fit_score), 0.0, 1.0),
          "telegram_fit_reason" =>
            read_string(
              item,
              "telegram_fit_reason",
              "PM backlog tickets are a high-signal operator workflow for this agent."
            ),
          "why_now" =>
            why_now ||
              "This ticket is grounded in current goals, project memory, open work, and repository activity.",
          "acceptance_criteria" => acceptance_criteria,
          "follow_up_ideas" => follow_up_ideas,
          "evidence" => evidence,
          "labels" => read_string_list(item, "labels") |> Enum.take(@max_list_items),
          "risk" => read_string(item, "risk", nil),
          "user_value" => read_string(item, "user_value", nil),
          "ticket_type" => read_string(item, "ticket_type", "feature")
        }
        |> compact_map()

      %{
        "source" => "product_manager_agent",
        "category" => "product_opportunity",
        "title" => title,
        "summary" => summary,
        "recommended_action" => recommended_action,
        "priority" => priority,
        "confidence" => confidence,
        "attention_mode" => "monitor",
        "source_id" => snapshot.latest_commit_sha || "#{snapshot.repo_full_name}:#{run_key}",
        "source_occurred_at" => snapshot.latest_commit_at,
        "tracking_key" => "#{dedupe_prefix(snapshot.repo_full_name, run_key)}:#{slugify(title)}",
        "dedupe_key" =>
          "#{dedupe_prefix(snapshot.repo_full_name, run_key)}:#{slugify(title)}:#{index}",
        "metadata" => metadata
      }
    end
  end

  defp ticket_to_insight(
         _item,
         _index,
         _snapshot,
         _project_context,
         _state,
         _plan_date,
         _run_key
       ),
       do: nil

  defp maybe_write_project_items(nil, _insights), do: []

  defp maybe_write_project_items(%Project{} = project, insights) when is_list(insights) do
    existing =
      Projects.list_project_items(user_id: project.user_id, project_id: project.id, limit: 100)

    insights
    |> Enum.reject(&project_item_exists?(existing, &1))
    |> Enum.reduce([], fn insight, acc ->
      case Projects.create_project_item(project, project_item_attrs(insight)) do
        {:ok, item} ->
          [item | acc]

        {:error, reason} ->
          Logger.warning("ProductManagerAgent failed to write project item",
            project_id: project.id,
            insight_id: insight.id,
            reason: inspect(reason)
          )

          acc
      end
    end)
    |> Enum.reverse()
  end

  defp maybe_write_project_items(_project, _insights), do: []

  defp project_item_exists?(existing, %Insight{} = insight) do
    Enum.any?(existing, fn item ->
      metadata = item.metadata || %{}

      Map.get(metadata, "source_insight_id") == insight.id or
        Map.get(metadata, "source_insight_dedupe_key") == insight.dedupe_key
    end)
  end

  defp project_item_attrs(%Insight{} = insight) do
    metadata = insight.metadata || %{}

    %{
      "item_type" => "todo",
      "title" => insight.title,
      "content" => insight.recommended_action || insight.summary,
      "status" => "active",
      "source" => "agent",
      "metadata" =>
        metadata
        |> Map.take([
          "project_id",
          "project_name",
          "repo_full_name",
          "base_branch",
          "planner_date",
          "planner_run_key",
          "planner_type",
          "latest_commit_sha",
          "why_now",
          "acceptance_criteria",
          "follow_up_ideas",
          "evidence",
          "labels",
          "risk",
          "user_value",
          "ticket_type"
        ])
        |> Map.put("source_insight_id", insight.id)
        |> Map.put("source_insight_dedupe_key", insight.dedupe_key)
    }
  end

  defp build_llm_prompt(snapshot, project_context, context, timestamp, ticket_limit, user_memory) do
    snapshot_json = Jason.encode!(snapshot)
    project_context_json = Jason.encode!(serializable_project_context(project_context))
    trigger_json = Jason.encode!(trigger_for_prompt(context))
    user_memory_json = Jason.encode!(user_memory || %{})

    """
    You are the operator's Product Manager Agent running inside Maraithon.
    Current time: #{DateTime.to_iso8601(timestamp)}
    Target ticket count: #{ticket_limit}

    Durable user memory JSON:
    #{user_memory_json}

    Trigger JSON:
    #{trigger_json}

    Project context JSON:
    #{project_context_json}

    Repository snapshot JSON:
    #{snapshot_json}

    Task:
    - Propose the next #{ticket_limit} highest-impact backlog tickets for this project.
    - Think like a PM, not an implementation planner: prioritize user value, proof of product progress, adoption, workflow leverage, and dogfood loops.
    - Use the goals doc, project memory, open tasks, README, root structure, recent commits, open issues, and open pull requests as evidence.
    - Avoid duplicates of existing tasks or in-flight issues unless the existing item is too vague and should be replaced by a clearer ticket.
    - Avoid pure refactors, chores, or generic platform work unless they unlock a concrete user-facing outcome named in evidence.
    - Make every ticket concrete enough that a coding agent can execute it without a PM rewrite.
    - Include acceptance_criteria as testable bullets.
    - Set why_now from the current goals, repo activity, project memory, or trigger event.
    - Set telegram_fit_score high only if the ticket is worth interrupting the operator about today.

    Return ONLY valid JSON.
    Preferred shape:
    {
      "tickets": [
        {
          "title": "...",
          "summary": "...",
          "user_value": "...",
          "next_action": "First scoped milestone...",
          "priority": 60,
          "confidence": 0.75,
          "why_now": "...",
          "acceptance_criteria": ["..."],
          "evidence": ["..."],
          "labels": ["product"],
          "risk": "...",
          "ticket_type": "feature",
          "telegram_fit_score": 0.9,
          "telegram_fit_reason": "..."
        }
      ]
    }
    """
  end

  defp serializable_project_context(project_context) do
    project =
      case project_context[:project] do
        %Project{} = project ->
          %{
            id: project.id,
            name: project.name,
            slug: project.slug,
            status: project.status,
            priority: project.priority,
            description: project.description,
            summary: project.summary,
            metadata: project.metadata || %{}
          }

        _ ->
          nil
      end

    %{
      project: project,
      goals_doc: project_context[:goals_doc],
      open_tasks: project_context[:open_tasks] || [],
      project_items: project_context[:project_items] || [],
      trigger: project_context[:trigger]
    }
  end

  defp run_key_for(context, timestamp) do
    case Map.get(context, :trigger) do
      %{type: :message, message_id: message_id} when is_binary(message_id) ->
        "manual:#{message_id}"

      %{"type" => "message", "message_id" => message_id} when is_binary(message_id) ->
        "manual:#{message_id}"

      %{type: :pubsub_event} ->
        "event:#{event_fingerprint(Map.get(context, :event), timestamp)}"

      %{"type" => "pubsub_event"} ->
        "event:#{event_fingerprint(Map.get(context, :event), timestamp)}"

      _ ->
        %{year: year, month: month, day: day} = DateTime.to_date(timestamp)
        {year, week} = :calendar.iso_week_number({year, month, day})
        "week:#{year}-W#{String.pad_leading(to_string(week), 2, "0")}"
    end
  end

  defp event_fingerprint(event, timestamp) when is_map(event) do
    payload = Map.get(event, :payload) || Map.get(event, "payload") || %{}
    data = Map.get(payload, :data) || Map.get(payload, "data") || payload

    [
      Map.get(event, :topic) || Map.get(event, "topic"),
      Map.get(data, :after) || Map.get(data, "after"),
      Map.get(data, :commit_count) || Map.get(data, "commit_count"),
      Map.get(payload, :type) || Map.get(payload, "type")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
    |> case do
      "" -> DateTime.to_iso8601(timestamp)
      value -> value
    end
    |> slugify()
  end

  defp event_fingerprint(_event, timestamp), do: timestamp |> DateTime.to_iso8601() |> slugify()

  defp dedupe_prefix(repo_full_name, run_key) do
    "pm_ticket:#{repo_full_name}:#{run_key}"
  end

  defp decode_json_payload(content) do
    case Jason.decode(content) do
      {:ok, value} ->
        {:ok, value}

      {:error, _reason} ->
        case Regex.run(~r/```json\s*(\[.*\]|\{.*\})\s*```/s, content, capture: :all_but_first) do
          [json] -> Jason.decode(json)
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp extract_ticket_list(list) when is_list(list), do: list

  defp extract_ticket_list(map) when is_map(map) do
    cond do
      is_list(fetch_attr(map, "tickets")) -> fetch_attr(map, "tickets")
      is_list(fetch_attr(map, "features")) -> fetch_attr(map, "features")
      true -> nil
    end
  end

  defp extract_ticket_list(_), do: nil

  defp to_ticket_limit(value, _default) when value in [2, 3], do: value

  defp to_ticket_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed in [2, 3] -> parsed
      _ -> default
    end
  end

  defp to_ticket_limit(_value, default), do: default

  defp to_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp to_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp to_positive_integer(_value, default), do: default

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_), do: nil

  defp read_string(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          normalized -> normalized
        end

      _ ->
        default
    end
  end

  defp read_integer(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
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
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_string_list(attrs, key) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      list when is_list(list) ->
        list
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&is_nil/1)

      value when is_binary(value) ->
        value
        |> String.split(~r/\r?\n|;/, trim: true)
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(attrs, fn
          {map_key, value} when is_atom(map_key) -> if Atom.to_string(map_key) == key, do: value
          _ -> nil
        end)
    end
  end

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, []}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp slugify(nil), do: "ticket"

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "ticket"
      slug -> slug
    end
  end

  defp truncate_text(nil, _limit), do: nil

  defp truncate_text(value, limit) when is_binary(value) and byte_size(value) > limit do
    String.slice(value, 0, limit) <> "..."
  end

  defp truncate_text(value, _limit), do: value

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value
end
