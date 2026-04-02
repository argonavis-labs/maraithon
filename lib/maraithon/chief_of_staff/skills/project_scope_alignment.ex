defmodule Maraithon.ChiefOfStaff.Skills.ProjectScopeAlignment do
  @moduledoc """
  Weekend Chief of Staff skill that lets the LLM classify projects and todos
  into work vs home domains and ask for confirmation only when needed.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.Briefs
  alias Maraithon.Projects
  alias Maraithon.Projects.Project
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  @default_timezone_offset_hours -5
  @default_max_projects 12
  @default_max_todos 40
  @valid_life_domains ~w(home work)

  @impl true
  def id, do: "project_scope_alignment"

  @impl true
  def default_config do
    %{
      "assistant_behavior" => "ai_chief_of_staff",
      "timezone_offset_hours" => @default_timezone_offset_hours,
      "max_projects" => @default_max_projects,
      "max_todos" => @default_max_todos
    }
  end

  @impl true
  def requirements do
    [
      %{
        kind: :provider,
        provider: "telegram",
        label: "Telegram",
        description: "Needed to ask quick work-vs-home clarification questions on weekends.",
        required?: true
      }
    ]
  end

  @impl true
  def subscriptions(_config, _user_id), do: []

  @impl true
  def interested_in?(_config, context) do
    case get_in(context, [:trigger, :type]) do
      :message -> false
      :pubsub_event -> false
      _ -> true
    end
  end

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      timezone_offset_hours:
        integer_in_range(config["timezone_offset_hours"], @default_timezone_offset_hours, -12, 14),
      max_projects: integer_in_range(config["max_projects"], @default_max_projects, 1, 20),
      max_todos: integer_in_range(config["max_todos"], @default_max_todos, 1, 80),
      pending_review_key: nil,
      pending_projects: %{},
      pending_todos: %{},
      last_review_key: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    timestamp = context[:timestamp] || DateTime.utc_now()

    cond do
      is_nil(user_id) ->
        {:idle, %{state | user_id: user_id}}

      not scheduled_trigger?(context) ->
        {:idle, %{state | user_id: user_id}}

      true ->
        local_now = shift_local(timestamp, state.timezone_offset_hours)

        if weekend?(local_now) do
          review_key = DateTime.to_date(local_now) |> Date.to_iso8601()

          if state.last_review_key == review_key do
            {:idle, %{state | user_id: user_id}}
          else
            projects =
              Projects.list_projects(user_id: user_id, status: "active")
              |> Enum.take(state.max_projects)

            todos =
              Todos.list_open_for_user(user_id, limit: state.max_todos)
              |> Enum.take(state.max_todos)

            if projects == [] and todos == [] do
              {:idle, %{state | user_id: user_id, last_review_key: review_key}}
            else
              {:effect, {:llm_call, llm_params(projects, todos, local_now, context)},
               %{
                 state
                 | user_id: user_id,
                   pending_review_key: review_key,
                   pending_projects: Map.new(projects, &{&1.id, &1}),
                   pending_todos: Map.new(todos, &{&1.id, &1})
               }}
            end
          end
        else
          {:idle, %{state | user_id: user_id}}
        end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    review_key =
      state.pending_review_key ||
        (context[:timestamp] || DateTime.utc_now())
        |> shift_local(state.timezone_offset_hours)
        |> DateTime.to_date()
        |> Date.to_iso8601()

    with {:ok, decoded} <- decode_json_payload(response.content),
         {:ok, persisted} <- persist_scope_updates(decoded, state, context) do
      next_state = clear_pending(%{state | last_review_key: review_key})

      case persisted.briefs do
        [] ->
          {:idle, next_state}

        briefs ->
          {:emit,
           {:briefs_recorded,
            %{
              count: length(briefs),
              user_id: state.user_id,
              cadences: Enum.map(briefs, & &1.cadence)
            }}, next_state}
      end
    else
      _ ->
        {:emit,
         {:brief_error, %{reason: "project_scope_alignment_invalid_json", attempted_count: 1}},
         clear_pending(state)}
    end
  end

  def handle_effect_result({:tool_call, _result}, state, _context),
    do: {:idle, clear_pending(state)}

  @impl true
  def next_wakeup(_state), do: :none

  defp persist_scope_updates(decoded, state, context) when is_map(decoded) do
    project_updates =
      decoded
      |> Map.get("projects", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    todo_updates =
      decoded
      |> Map.get("todos", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    summary = normalize_string(Map.get(decoded, "summary"))
    reviewed_at = context[:timestamp] || DateTime.utc_now()

    updated_projects =
      project_updates
      |> Enum.reduce([], fn attrs, acc ->
        case apply_project_update(attrs, state.pending_projects, reviewed_at) do
          {:ok, project} -> [project | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    updated_todos =
      todo_updates
      |> Enum.reduce([], fn attrs, acc ->
        case apply_todo_update(attrs, state.pending_todos, reviewed_at) do
          {:ok, todo} -> [todo | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    briefs =
      project_updates
      |> Enum.filter(&(Map.get(&1, "ask_user") == true))
      |> Enum.map(&question_brief_attrs(&1, state, summary, reviewed_at))
      |> Enum.reject(&is_nil/1)
      |> then(fn attrs_list ->
        case attrs_list do
          [] ->
            []

          items ->
            case Briefs.record_many(state.user_id, context.agent_id, items) do
              {:ok, recorded} -> recorded
              {:error, _reason} -> []
            end
        end
      end)

    {:ok, %{projects: updated_projects, todos: updated_todos, briefs: briefs}}
  end

  defp persist_scope_updates(_decoded, _state, _context), do: {:error, :invalid_payload}

  defp apply_project_update(attrs, pending_projects, reviewed_at) do
    with project_id when is_binary(project_id) <- normalize_string(Map.get(attrs, "project_id")),
         %Project{} = project <- Map.get(pending_projects, project_id),
         life_domain when life_domain in @valid_life_domains <-
           normalize_life_domain(Map.get(attrs, "life_domain")),
         {:ok, updated} <-
           Projects.classify_life_domain(project, %{
             "life_domain" => life_domain,
             "confidence" => Map.get(attrs, "confidence"),
             "reasoning" => Map.get(attrs, "reasoning"),
             "needs_confirmation" => Map.get(attrs, "ask_user") == true,
             "source" => "chief_of_staff_weekend",
             "reviewed_at" => reviewed_at
           }) do
      {:ok, updated}
    else
      _ -> :skip
    end
  end

  defp apply_todo_update(attrs, pending_todos, reviewed_at) do
    with todo_id when is_binary(todo_id) <- normalize_string(Map.get(attrs, "todo_id")),
         %Todo{} = todo <- Map.get(pending_todos, todo_id),
         {:ok, updated} <-
           Todos.annotate_scope(todo.user_id, todo.id, %{
             "project_id" => Map.get(attrs, "project_id"),
             "project_name" => Map.get(attrs, "project_name"),
             "life_domain" => Map.get(attrs, "life_domain"),
             "confidence" => Map.get(attrs, "confidence"),
             "reasoning" => Map.get(attrs, "reasoning"),
             "source" => "chief_of_staff_weekend",
             "reviewed_at" => reviewed_at
           }) do
      {:ok, updated}
    else
      _ -> :skip
    end
  end

  defp question_brief_attrs(attrs, state, summary, reviewed_at) do
    project_id = normalize_string(Map.get(attrs, "project_id"))
    question = normalize_string(Map.get(attrs, "question"))
    project = project_id && Map.get(state.pending_projects, project_id)

    case {project, question} do
      {%Project{} = project, question} when is_binary(question) ->
        life_domain = normalize_life_domain(Map.get(attrs, "life_domain"))
        reasoning = normalize_string(Map.get(attrs, "reasoning"))
        confidence = normalize_confidence(Map.get(attrs, "confidence"))

        %{
          "cadence" => "weekend_scope",
          "scheduled_for" => reviewed_at,
          "dedupe_key" =>
            "brief:weekend_scope:#{project.id}:#{DateTime.to_unix(reviewed_at, :second)}",
          "title" => "Weekend project check: #{project.name}",
          "summary" =>
            summary ||
              "I sorted weekend projects and todos, but I want to confirm this one before I keep grouping related work.",
          "body" =>
            [
              "Weekend home/work pass:",
              guess_sentence(project.name, life_domain, reasoning, confidence),
              question,
              "Reply in-thread with `work` or `home` and I'll update the project and related todos."
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("\n\n"),
          "metadata" => %{
            "linked_project" => %{
              "id" => project.id,
              "name" => project.name,
              "slug" => project.slug,
              "summary" => project.summary
            },
            "life_domain_guess" => life_domain,
            "life_domain_confidence" => confidence,
            "life_domain_reasoning" => reasoning,
            "scope_question" => question,
            "brief_type" => "weekend_scope"
          }
        }

      _ ->
        nil
    end
  end

  defp guess_sentence(_project_name, nil, nil, _confidence), do: nil

  defp guess_sentence(project_name, life_domain, reasoning, confidence) do
    base =
      "I currently think #{project_name} is #{life_domain}"
      |> Kernel.<>(
        if(is_number(confidence), do: " (#{confidence_percent(confidence)} confidence)", else: "")
      )

    case normalize_string(reasoning) do
      nil -> base <> "."
      text -> base <> " because " <> String.trim_trailing(text, ".") <> "."
    end
  end

  defp confidence_percent(value) when is_number(value) do
    value
    |> normalize_confidence()
    |> Kernel.*(100)
    |> round()
    |> Integer.to_string()
    |> Kernel.<>("%")
  end

  defp llm_params(projects, todos, local_now, context) do
    %{
      "messages" => [
        %{
          "role" => "user",
          "content" => build_prompt(projects, todos, local_now, context)
        }
      ],
      "max_tokens" => 1_800,
      "temperature" => 0.2
    }
  end

  defp build_prompt(projects, todos, local_now, context) do
    projects_json = Jason.encode!(Enum.map(projects, &serialize_project_for_prompt/1))
    todos_json = Jason.encode!(Enum.map(todos, &serialize_todo_for_prompt/1))
    user_memory_json = Jason.encode!(Map.get(context, :user_memory, %{}))

    """
    You are Maraithon's Chief of Staff running a weekend home-vs-work reconciliation pass.
    Local weekend time: #{DateTime.to_iso8601(local_now)}

    Durable user memory JSON:
    #{user_memory_json}

    Active projects JSON:
    #{projects_json}

    Open todos JSON:
    #{todos_json}

    Task:
    - Decide whether each active project is primarily `work` or `home`.
    - Suggest which open todos belong to which project when the match is strong enough to be useful.
    - Use intelligence, memory, project context, todo content, and the operating context already present in the data.
    - Do not rely on hard-coded rules or deterministic heuristics. Make an AI judgment from the actual evidence.
    - Default to making the best reasonable guess. Only ask the user when uncertainty remains material enough that the wrong domain would cause bad sorting.
    - Keep reasoning short and concrete.
    - Never invent projects or todos.

    Return ONLY valid JSON shaped like:
    {
      "summary": "short operator-facing summary",
      "projects": [
        {
          "project_id": "existing project id",
          "life_domain": "work" | "home" | null,
          "confidence": 0.0,
          "reasoning": "short explanation",
          "ask_user": false,
          "question": "only when ask_user is true"
        }
      ],
      "todos": [
        {
          "todo_id": "existing todo id",
          "project_id": "best matching project id or null",
          "project_name": "best matching project name or null",
          "life_domain": "work" | "home" | null,
          "confidence": 0.0,
          "reasoning": "short explanation"
        }
      ]
    }
    """
  end

  defp serialize_project_for_prompt(%Project{} = project) do
    %{
      "id" => project.id,
      "name" => project.name,
      "slug" => project.slug,
      "summary" => project.summary,
      "description" => project.description,
      "metadata" =>
        (project.metadata || %{})
        |> Map.take([
          "life_domain",
          "life_domain_confidence",
          "life_domain_reasoning",
          "life_domain_needs_confirmation"
        ]),
      "items" =>
        Projects.list_project_items(user_id: project.user_id, project_id: project.id, limit: 6)
        |> Enum.map(fn item ->
          %{
            "id" => item.id,
            "item_type" => item.item_type,
            "title" => item.title,
            "content" => item.content,
            "status" => item.status
          }
        end),
      "recommendations" =>
        Projects.list_project_recommendations(project.id, project.user_id, limit: 3)
        |> Enum.map(fn recommendation ->
          %{
            "id" => recommendation.id,
            "title" => recommendation.title,
            "summary" => recommendation.summary,
            "recommended_action" => recommendation.recommended_action
          }
        end)
    }
  end

  defp serialize_todo_for_prompt(%Todo{} = todo) do
    %{
      "id" => todo.id,
      "source" => todo.source,
      "kind" => todo.kind,
      "attention_mode" => todo.attention_mode,
      "title" => todo.title,
      "summary" => todo.summary,
      "next_action" => todo.next_action,
      "priority" => todo.priority,
      "metadata" =>
        (todo.metadata || %{})
        |> Map.take([
          "life_domain",
          "suggested_project_id",
          "suggested_project_name",
          "suggested_life_domain",
          "scope_confidence",
          "scope_reasoning",
          "source_insight_category",
          "source_insight_tracking_key"
        ])
    }
  end

  defp clear_pending(state) do
    %{
      state
      | pending_review_key: nil,
        pending_projects: %{},
        pending_todos: %{}
    }
  end

  defp weekend?(%DateTime{} = local_now) do
    Date.day_of_week(DateTime.to_date(local_now)) in [6, 7]
  end

  defp scheduled_trigger?(context) do
    get_in(context, [:trigger, :type]) in [nil, :wakeup]
  end

  defp shift_local(%DateTime{} = datetime, offset_hours) do
    DateTime.add(datetime, offset_hours * 3600, :second)
  end

  defp integer_in_range(value, default, min, max) do
    case value do
      int when is_integer(int) and int >= min and int <= max ->
        int

      binary when is_binary(binary) ->
        case Integer.parse(binary) do
          {int, ""} when int >= min and int <= max -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp normalize_life_domain(value) when value in @valid_life_domains, do: value
  defp normalize_life_domain(_value), do: nil

  defp normalize_confidence(value) when is_float(value), do: value |> max(0.0) |> min(1.0)
  defp normalize_confidence(value) when is_integer(value), do: normalize_confidence(value / 1)

  defp normalize_confidence(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> normalize_confidence(parsed)
      _ -> nil
    end
  end

  defp normalize_confidence(_value), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp decode_json_payload(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, value} ->
        {:ok, value}

      {:error, _reason} ->
        case Regex.run(~r/```json\s*(\{.*\})\s*```/s, content, capture: :all_but_first) do
          [json] -> Jason.decode(json)
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp decode_json_payload(_content), do: {:error, :invalid_json}
end
