defmodule Maraithon.Projects do
  @moduledoc """
  Context for managing project-scoped operating state.
  """

  import Ecto.Query

  alias Maraithon.Agents.Agent
  alias Maraithon.Insights.Insight
  alias Maraithon.Redaction
  alias Maraithon.RunErrorCopy

  alias Maraithon.Projects.{
    DeliveryLauncher,
    ImplementationRun,
    Project,
    ProjectItem,
    RecommendationDecision,
    RepoGrant
  }

  alias Maraithon.Repo
  alias Maraithon.Todos.UserFacingCopy

  @project_item_limit 10
  @recommendation_limit 5
  @open_insight_statuses ["new", "snoozed"]
  @recommendation_decision_limit 10
  @implementation_run_limit 10
  @repo_grant_limit 10
  @delivery_agent_behaviors ~w(repo_planner prompt_agent codebase_advisor)
  @implementation_run_statuses ~w(
    pending_plan
    awaiting_repo_access
    queued
    running
    blocked
    awaiting_review
    completed
    failed
  )

  def list_projects(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    status = Keyword.get(opts, :status)
    preload = Keyword.get(opts, :preload, [])

    Project
    |> maybe_filter_user(user_id)
    |> maybe_filter_status(status)
    |> order_by([project], asc: project.name, desc: project.updated_at)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  def get_project(id, opts \\ [])

  def get_project(id, opts) when is_binary(id) do
    user_id = Keyword.get(opts, :user_id)
    preload = Keyword.get(opts, :preload, [])

    Project
    |> maybe_filter_user(user_id)
    |> Repo.get(id)
    |> Repo.preload(preload)
  end

  def get_project(_id, _opts), do: nil

  def get_project!(id), do: Repo.get!(Project, id)

  def get_project_for_user(id, user_id, opts \\ [])

  def get_project_for_user(id, user_id, opts) when is_binary(id) and is_binary(user_id) do
    preload = Keyword.get(opts, :preload, [])

    Project
    |> where([project], project.id == ^id and project.user_id == ^user_id)
    |> Repo.one()
    |> Repo.preload(preload)
  end

  def get_project_for_user(_id, _user_id, _opts), do: nil

  def get_project_by_slug_for_user(slug, user_id, opts \\ [])

  def get_project_by_slug_for_user(slug, user_id, opts)
      when is_binary(slug) and is_binary(user_id) do
    preload = Keyword.get(opts, :preload, [])
    normalized_slug = normalize_slug(slug)

    Project
    |> where([project], project.user_id == ^user_id and project.slug == ^normalized_slug)
    |> Repo.one()
    |> Repo.preload(preload)
  end

  def get_project_by_slug_for_user(_slug, _user_id, _opts), do: nil

  def get_project_by_name_for_user(name, user_id, opts \\ [])

  def get_project_by_name_for_user(name, user_id, opts)
      when is_binary(name) and is_binary(user_id) do
    preload = Keyword.get(opts, :preload, [])
    normalized_name = normalize_project_name(name)

    if is_nil(normalized_name) do
      nil
    else
      project =
        Project
        |> where(
          [project],
          project.user_id == ^user_id and fragment("lower(?)", project.name) == ^normalized_name
        )
        |> Repo.one()

      project =
        project ||
          Project
          |> where([project], project.user_id == ^user_id)
          |> where([project], ilike(project.name, ^"%#{normalized_name}%"))
          |> order_by([project], asc: project.name, desc: project.updated_at)
          |> limit(1)
          |> Repo.one()

      Repo.preload(project, preload)
    end
  end

  def get_project_by_name_for_user(_name, _user_id, _opts), do: nil

  def create_project(user_id, attrs \\ %{})

  def create_project(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    %Project{user_id: user_id}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  def create_project(_user_id, _attrs), do: {:error, :invalid_project_attrs}

  def update_project(%Project{} = project, attrs) when is_map(attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def classify_life_domain(%Project{} = project, attrs \\ %{}) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    metadata =
      project.metadata
      |> project_life_domain_metadata(attrs)

    update_project(project, %{"metadata" => metadata})
  end

  def delete_project(%Project{} = project), do: Repo.delete(project)

  def list_project_items(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    status = Keyword.get(opts, :status)
    item_type = Keyword.get(opts, :item_type)
    limit = Keyword.get(opts, :limit, @project_item_limit)

    ProjectItem
    |> maybe_filter_project_item_user(user_id)
    |> maybe_filter_project_id(project_id)
    |> maybe_filter_project_item_status(status)
    |> maybe_filter_project_item_type(item_type)
    |> order_by([item], desc: item.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def create_project_item(%Project{} = project, attrs) when is_map(attrs) do
    %ProjectItem{project_id: project.id, user_id: project.user_id}
    |> ProjectItem.changeset(attrs)
    |> Repo.insert()
  end

  def create_project_item(project_id, user_id, attrs)
      when is_binary(project_id) and is_binary(user_id) and is_map(attrs) do
    case get_project_for_user(project_id, user_id) do
      %Project{} = project -> create_project_item(project, attrs)
      nil -> {:error, :project_not_found}
    end
  end

  def create_project_item(_project_id, _user_id, _attrs),
    do: {:error, :invalid_project_item_attrs}

  def list_project_recommendations(project_id, user_id, opts \\ [])

  def list_project_recommendations(project_id, user_id, opts)
      when is_binary(project_id) and is_binary(user_id) do
    limit = Keyword.get(opts, :limit, @recommendation_limit)
    category = Keyword.get(opts, :category, "product_opportunity")
    open_only? = Keyword.get(opts, :open_only?, true)

    Insight
    |> join(:inner, [insight], agent in Agent, on: agent.id == insight.agent_id)
    |> where(
      [insight, agent],
      insight.user_id == ^user_id and agent.project_id == ^project_id and
        insight.category == ^category
    )
    |> maybe_filter_open_project_recommendations(open_only?)
    |> order_by([insight, _agent], desc: insight.priority, desc: insight.inserted_at)
    |> limit(^limit)
    |> select([insight, agent], {insight, agent})
    |> Repo.all()
    |> Enum.map(fn {insight, agent} ->
      metadata = insight.metadata || %{}

      %{
        id: insight.id,
        title: insight.title,
        summary: insight.summary,
        recommended_action: insight.recommended_action,
        priority: insight.priority,
        confidence: insight.confidence,
        status: insight.status,
        why_now: Map.get(metadata, "why_now"),
        repo_full_name: Map.get(metadata, "repo_full_name"),
        planner_type: Map.get(metadata, "planner_type"),
        follow_up_ideas: Map.get(metadata, "follow_up_ideas") || [],
        agent_id: agent.id,
        agent_name: get_in(agent.config || %{}, ["name"]) || agent.behavior,
        agent_behavior: agent.behavior,
        inserted_at: insight.inserted_at
      }
      |> attach_delivery_state(project_id, user_id)
    end)
  end

  def list_project_recommendations(_project_id, _user_id, _opts), do: []

  def get_project_recommendation(project_id, user_id, recommendation_id)
      when is_binary(project_id) and is_binary(user_id) and is_binary(recommendation_id) do
    Insight
    |> join(:inner, [insight], agent in Agent, on: agent.id == insight.agent_id)
    |> where(
      [insight, agent],
      insight.id == ^recommendation_id and insight.user_id == ^user_id and
        agent.project_id == ^project_id and
        insight.category == "product_opportunity"
    )
    |> select([insight, agent], {insight, agent})
    |> Repo.one()
    |> case do
      {insight, agent} ->
        metadata = insight.metadata || %{}

        %{
          id: insight.id,
          title: insight.title,
          summary: insight.summary,
          recommended_action: insight.recommended_action,
          priority: insight.priority,
          confidence: insight.confidence,
          status: insight.status,
          why_now: Map.get(metadata, "why_now"),
          repo_full_name: Map.get(metadata, "repo_full_name"),
          planner_type: Map.get(metadata, "planner_type"),
          follow_up_ideas: Map.get(metadata, "follow_up_ideas") || [],
          evidence: Map.get(metadata, "evidence") || [],
          agent_id: agent.id,
          agent_name: get_in(agent.config || %{}, ["name"]) || agent.behavior,
          agent_behavior: agent.behavior,
          metadata: metadata,
          inserted_at: insight.inserted_at
        }
        |> attach_delivery_state(project_id, user_id)

      _ ->
        nil
    end
  end

  def get_project_recommendation(_project_id, _user_id, _recommendation_id), do: nil

  def list_recommendation_decisions(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    source_insight_id = Keyword.get(opts, :source_insight_id)
    limit = Keyword.get(opts, :limit, @recommendation_decision_limit)

    RecommendationDecision
    |> maybe_filter_decision_user(user_id)
    |> maybe_filter_decision_project(project_id)
    |> maybe_filter_decision_source_insight(source_insight_id)
    |> order_by([decision], desc: decision.updated_at, desc: decision.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def decide_project_recommendation(project_id, user_id, recommendation_id, attrs \\ %{})

  def decide_project_recommendation(project_id, user_id, recommendation_id, attrs)
      when is_binary(project_id) and is_binary(user_id) and is_binary(recommendation_id) and
             is_map(attrs) do
    with %Project{} <- get_project_for_user(project_id, user_id) || {:error, :project_not_found},
         %{} = recommendation <-
           get_project_recommendation(project_id, user_id, recommendation_id) ||
             {:error, :recommendation_not_found},
         {:ok, decision_value} <- normalize_decision_value(attrs),
         {:ok, decision_note} <- normalize_decision_note(attrs),
         existing <- recommendation_decision_for_source(user_id, recommendation_id),
         plan = accepted_plan_for_recommendation(recommendation, decision_value, decision_note) do
      record =
        existing ||
          %RecommendationDecision{
            user_id: user_id,
            project_id: project_id,
            source_insight_id: recommendation_id
          }

      record
      |> RecommendationDecision.changeset(%{
        user_id: user_id,
        project_id: project_id,
        source_insight_id: recommendation_id,
        decision: decision_value,
        decision_note: decision_note,
        accepted_plan: plan,
        metadata: %{
          "repo_full_name" => recommendation.repo_full_name,
          "recommendation_title" => recommendation.title
        }
      })
      |> Repo.insert_or_update()
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def decide_project_recommendation(_project_id, _user_id, _recommendation_id, _attrs),
    do: {:error, :invalid_recommendation_decision_attrs}

  def list_repo_grants(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    provider = Keyword.get(opts, :provider)
    repo_full_name = Keyword.get(opts, :repo_full_name)
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, @repo_grant_limit)

    RepoGrant
    |> maybe_filter_repo_grant_user(user_id)
    |> maybe_filter_repo_grant_project(project_id)
    |> maybe_filter_repo_grant_provider(provider)
    |> maybe_filter_repo_grant_repo(repo_full_name)
    |> maybe_filter_repo_grant_status(status)
    |> order_by([grant], desc: grant.granted_at, desc: grant.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def grant_project_repo_access(project_id, user_id, attrs \\ %{})

  def grant_project_repo_access(project_id, user_id, attrs)
      when is_binary(project_id) and is_binary(user_id) and is_map(attrs) do
    with %Project{} <- get_project_for_user(project_id, user_id) || {:error, :project_not_found},
         {:ok, repo_full_name} <- required_repo_full_name(attrs),
         {:ok, provider} <- normalize_repo_provider(attrs),
         {:ok, scope} <- normalize_repo_scope(attrs),
         {:ok, status} <- normalize_repo_grant_status(attrs) do
      grant_time = DateTime.utc_now()

      existing =
        Repo.get_by(RepoGrant,
          project_id: project_id,
          provider: provider,
          repo_full_name: repo_full_name,
          scope: scope
        )

      record =
        existing ||
          %RepoGrant{
            project_id: project_id,
            user_id: user_id,
            granted_by_user_id: user_id
          }

      record
      |> RepoGrant.changeset(%{
        project_id: project_id,
        user_id: user_id,
        granted_by_user_id: user_id,
        provider: provider,
        repo_full_name: repo_full_name,
        scope: scope,
        status: status,
        granted_at: (existing && existing.granted_at) || grant_time,
        metadata:
          stringify_metadata(Map.get(attrs, "metadata") || Map.get(attrs, :metadata) || %{})
      })
      |> Repo.insert_or_update()
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def grant_project_repo_access(_project_id, _user_id, _attrs),
    do: {:error, :invalid_repo_grant_attrs}

  def active_repo_grant(
        project_id,
        user_id,
        provider,
        repo_full_name,
        required_scope \\ "read_only"
      )

  def active_repo_grant(project_id, user_id, provider, repo_full_name, required_scope)
      when is_binary(project_id) and is_binary(user_id) and is_binary(provider) and
             is_binary(repo_full_name) and is_binary(required_scope) do
    list_repo_grants(
      project_id: project_id,
      user_id: user_id,
      provider: provider,
      repo_full_name: repo_full_name,
      status: "active",
      limit: @repo_grant_limit
    )
    |> Enum.filter(&(RepoGrant.scope_order(&1.scope) >= RepoGrant.scope_order(required_scope)))
    |> Enum.max_by(&RepoGrant.scope_order(&1.scope), fn -> nil end)
  end

  def active_repo_grant(_project_id, _user_id, _provider, _repo_full_name, _required_scope),
    do: nil

  def get_implementation_run_for_user(id, user_id, opts \\ [])

  def get_implementation_run_for_user(id, user_id, opts)
      when is_binary(id) and is_binary(user_id) do
    preload = Keyword.get(opts, :preload, [])

    ImplementationRun
    |> where([run], run.id == ^id and run.user_id == ^user_id)
    |> Repo.one()
    |> Repo.preload(preload)
  end

  def get_implementation_run_for_user(_id, _user_id, _opts), do: nil

  def list_implementation_runs(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    recommendation_decision_id = Keyword.get(opts, :recommendation_decision_id)
    statuses = Keyword.get(opts, :statuses)
    limit = Keyword.get(opts, :limit, @implementation_run_limit)
    preload = Keyword.get(opts, :preload, [])

    ImplementationRun
    |> maybe_filter_run_user(user_id)
    |> maybe_filter_run_project(project_id)
    |> maybe_filter_run_recommendation_decision(recommendation_decision_id)
    |> maybe_filter_run_statuses(statuses)
    |> order_by([run], desc: run.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  def update_implementation_run(%ImplementationRun{} = run, attrs) when is_map(attrs) do
    with {:ok, normalized_attrs} <- normalize_implementation_run_update(run, attrs) do
      run
      |> ImplementationRun.changeset(normalized_attrs)
      |> Repo.update()
    end
  end

  def update_implementation_run(run_id, user_id, attrs)
      when is_binary(run_id) and is_binary(user_id) and is_map(attrs) do
    case get_implementation_run_for_user(run_id, user_id) do
      %ImplementationRun{} = run -> update_implementation_run(run, attrs)
      nil -> {:error, :implementation_run_not_found}
    end
  end

  def update_implementation_run(_run_id, _user_id, _attrs),
    do: {:error, :invalid_implementation_run_update_attrs}

  def start_implementation_run(project_id, user_id, attrs \\ %{})

  def start_implementation_run(project_id, user_id, attrs)
      when is_binary(project_id) and is_binary(user_id) and is_map(attrs) do
    with %Project{} = project <-
           get_project_for_user(project_id, user_id, preload: [:agents]) ||
             {:error, :project_not_found},
         {:ok, recommendation_id} <- required_recommendation_id(attrs),
         %{} = recommendation <-
           get_project_recommendation(project_id, user_id, recommendation_id) ||
             {:error, :recommendation_not_found},
         {:ok, decision} <-
           decide_project_recommendation(project_id, user_id, recommendation_id, %{
             "decision" => "accepted",
             "decision_note" => Map.get(attrs, "decision_note") || Map.get(attrs, :decision_note)
           }) do
      delivery_agent = delivery_agent(project.agents)

      repo_full_name =
        Map.get(attrs, "repo_full_name") || Map.get(attrs, :repo_full_name) ||
          recommendation.repo_full_name

      required_scope = required_scope_for_agent(delivery_agent)
      now = DateTime.utc_now()

      base_metadata = %{
        "repo_full_name" => repo_full_name,
        "required_scope" => required_scope
      }

      launch_result =
        cond do
          is_nil(repo_full_name) ->
            {:ready,
             %{
               status: "pending_plan",
               result_summary:
                 "Accepted #{recommendation.title}, but the project manager recommendation did not include a repository. Add repo context before implementation can start.",
               agent_id: nil,
               metadata: base_metadata
             }}

          is_nil(active_repo_grant(project_id, user_id, "github", repo_full_name, required_scope)) ->
            {:ready,
             %{
               status: "awaiting_repo_access",
               result_summary:
                 "Accepted #{recommendation.title}. Grant #{human_scope(required_scope)} GitHub access for #{repo_full_name} so Maraithon can continue.",
               agent_id: delivery_agent && delivery_agent.id,
               metadata: base_metadata
             }}

          is_nil(delivery_agent) ->
            {:ready,
             %{
               status: "blocked",
               result_summary:
                 "Accepted #{recommendation.title}, but this project does not have a delivery agent yet. Attach a Repo Planner or coding agent first.",
               agent_id: nil,
               metadata: base_metadata
             }}

          true ->
            {:launch,
             %{
               status: launcher_boot_status(delivery_agent),
               result_summary:
                 "Starting delivery for #{recommendation.title} with #{display_delivery_agent_name(delivery_agent)}.",
               agent_id: delivery_agent.id,
               metadata: base_metadata
             }}
        end

      with {mode, initial_run} <- launch_result,
           {:ok, run} <-
             create_implementation_run(project_id, user_id, decision.id, now, initial_run) do
        case mode do
          :ready ->
            {:ok, run}

          :launch ->
            case launch_delivery(project, recommendation, decision, delivery_agent, run) do
              {:ok, launched} ->
                update_implementation_run(run, %{
                  status: launched.status,
                  result_summary: launched.result_summary,
                  metadata:
                    Map.merge(
                      base_metadata,
                      stringify_metadata(launched.metadata || %{})
                    )
                })

              {:error, reason} ->
                update_implementation_run(run, %{
                  status: "failed",
                  result_summary:
                    implementation_run_launch_failure_summary(recommendation, reason),
                  metadata:
                    Map.merge(base_metadata, %{
                      "launch_error" => redacted_implementation_run_error(reason)
                    })
                })
            end
        end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def start_implementation_run(_project_id, _user_id, _attrs),
    do: {:error, :invalid_implementation_run_attrs}

  def default_project_for_user(user_id) when is_binary(user_id) do
    case list_projects(user_id: user_id, status: "active") do
      [project] -> project
      _ -> nil
    end
  end

  def summarize_for_prompt(user_id, limit \\ 8)

  def summarize_for_prompt(user_id, limit) when is_binary(user_id) do
    list_projects(user_id: user_id)
    |> Enum.take(limit)
    |> Enum.map(fn project ->
      %{
        id: project.id,
        name: project.name,
        slug: project.slug,
        status: project.status,
        priority: project.priority,
        summary: project.summary
      }
    end)
  end

  def summarize_for_prompt(_user_id, _limit), do: []

  defp recommendation_decision_for_source(user_id, recommendation_id) do
    Repo.get_by(RecommendationDecision, user_id: user_id, source_insight_id: recommendation_id)
  end

  defp attach_delivery_state(recommendation, project_id, user_id) do
    decision = recommendation_decision_for_source(user_id, recommendation.id)

    latest_run =
      case decision do
        %RecommendationDecision{id: decision_id} ->
          list_implementation_runs(
            project_id: project_id,
            user_id: user_id,
            recommendation_decision_id: decision_id,
            limit: 1
          )
          |> List.first()

        _ ->
          nil
      end

    repo_grant =
      case recommendation.repo_full_name do
        value when is_binary(value) and value != "" ->
          active_repo_grant(project_id, user_id, "github", value, "read_only")

        _ ->
          nil
      end

    Map.merge(recommendation, %{
      decision: serialize_recommendation_decision(decision),
      repo_grant: serialize_repo_grant(repo_grant),
      latest_run: serialize_implementation_run(latest_run)
    })
  end

  defp serialize_recommendation_decision(%RecommendationDecision{} = decision) do
    %{
      id: decision.id,
      decision: decision.decision,
      decision_note: decision.decision_note,
      accepted_plan: decision.accepted_plan || %{},
      updated_at: decision.updated_at
    }
  end

  defp serialize_recommendation_decision(_decision), do: nil

  defp serialize_repo_grant(%RepoGrant{} = grant) do
    %{
      id: grant.id,
      provider: grant.provider,
      repo_full_name: grant.repo_full_name,
      scope: grant.scope,
      status: grant.status,
      granted_at: grant.granted_at
    }
  end

  defp serialize_repo_grant(_grant), do: nil

  defp serialize_implementation_run(%ImplementationRun{} = run) do
    %{
      id: run.id,
      agent_id: run.agent_id,
      repo_full_name: run.repo_full_name,
      status: run.status,
      branch_name: run.branch_name,
      pull_request_url: run.pull_request_url,
      result_summary: run.result_summary,
      queued_at: run.queued_at,
      started_at: run.started_at,
      completed_at: run.completed_at,
      metadata: run.metadata || %{}
    }
  end

  defp serialize_implementation_run(_run), do: nil

  defp accepted_plan_for_recommendation(recommendation, decision, decision_note) do
    %{
      "title" => recommendation.title,
      "summary" => recommendation.summary,
      "recommended_action" => recommendation.recommended_action,
      "why_now" => recommendation.why_now,
      "repo_full_name" => recommendation.repo_full_name,
      "follow_up_ideas" => recommendation.follow_up_ideas || [],
      "evidence" => recommendation.evidence || [],
      "decision" => decision,
      "decision_note" => decision_note
    }
    |> stringify_metadata()
  end

  defp delivery_agent(agents) when is_list(agents) do
    agents
    |> Enum.filter(&(&1.behavior in @delivery_agent_behaviors))
    |> Enum.sort_by(&delivery_agent_rank/1)
    |> List.first()
  end

  defp delivery_agent(_agents), do: nil

  defp delivery_agent_rank(%Agent{behavior: "repo_planner"}), do: 1
  defp delivery_agent_rank(%Agent{behavior: "prompt_agent"}), do: 2
  defp delivery_agent_rank(%Agent{behavior: "codebase_advisor"}), do: 3
  defp delivery_agent_rank(_agent), do: 99

  defp required_scope_for_agent(%Agent{behavior: "repo_planner"}), do: "read_only"
  defp required_scope_for_agent(%Agent{}), do: "branch_write"
  defp required_scope_for_agent(_agent), do: "branch_write"

  defp delivery_launcher do
    Application.get_env(
      :maraithon,
      Maraithon.Projects,
      []
    )
    |> Keyword.get(:delivery_launcher, DeliveryLauncher)
  end

  defp launch_delivery(project, recommendation, decision, delivery_agent, run) do
    case delivery_launcher() do
      launcher when is_function(launcher, 5) ->
        launcher.(project, recommendation, decision, delivery_agent, run)

      launcher when is_function(launcher, 4) ->
        launcher.(project, recommendation, decision, delivery_agent)

      launcher ->
        cond do
          function_exported?(launcher, :launch, 5) ->
            launcher.launch(project, recommendation, decision, delivery_agent, run)

          true ->
            launcher.launch(project, recommendation, decision, delivery_agent)
        end
    end
  end

  defp human_scope("read_only"), do: "read-only"
  defp human_scope("branch_write"), do: "branch-write"
  defp human_scope("pr_open"), do: "PR-open"
  defp human_scope(scope), do: scope

  defp launcher_boot_status(%Agent{behavior: "repo_planner"}), do: "pending_plan"
  defp launcher_boot_status(%Agent{}), do: "queued"
  defp launcher_boot_status(_agent), do: "queued"

  defp display_delivery_agent_name(%Agent{} = agent) do
    get_in(agent.config || %{}, ["name"]) || agent.behavior
  end

  defp display_delivery_agent_name(_agent), do: "the delivery agent"

  defp normalize_decision_value(attrs) when is_map(attrs) do
    case Map.get(attrs, "decision") || Map.get(attrs, :decision) || "accepted" do
      value when value in ["accepted", "rejected", "deferred"] -> {:ok, value}
      _ -> {:error, :invalid_recommendation_decision}
    end
  end

  defp normalize_decision_note(attrs) when is_map(attrs) do
    value = Map.get(attrs, "decision_note") || Map.get(attrs, :decision_note)

    case value do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      text when is_binary(text) -> {:ok, String.trim(text)}
      _ -> {:error, :invalid_recommendation_decision_note}
    end
  end

  defp required_repo_full_name(attrs) when is_map(attrs) do
    case Map.get(attrs, "repo_full_name") || Map.get(attrs, :repo_full_name) do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _ -> {:error, :missing_repo_full_name}
    end
  end

  defp required_recommendation_id(attrs) when is_map(attrs) do
    case Map.get(attrs, "recommendation_id") || Map.get(attrs, :recommendation_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_recommendation_id}
    end
  end

  defp normalize_repo_provider(attrs) when is_map(attrs) do
    case Map.get(attrs, "provider") || Map.get(attrs, :provider) || "github" do
      "github" -> {:ok, "github"}
      _ -> {:error, :invalid_repo_provider}
    end
  end

  defp normalize_repo_scope(attrs) when is_map(attrs) do
    case Map.get(attrs, "scope") || Map.get(attrs, :scope) || "read_only" do
      value when value in ["read_only", "branch_write", "pr_open"] -> {:ok, value}
      _ -> {:error, :invalid_repo_scope}
    end
  end

  defp normalize_repo_grant_status(attrs) when is_map(attrs) do
    case Map.get(attrs, "status") || Map.get(attrs, :status) || "active" do
      value when value in ["active", "revoked", "pending"] -> {:ok, value}
      _ -> {:error, :invalid_repo_grant_status}
    end
  end

  defp normalize_implementation_run_update(%ImplementationRun{} = run, attrs)
       when is_map(attrs) do
    with {:ok, status} <-
           normalize_implementation_run_status(
             Map.get(attrs, "status") || Map.get(attrs, :status) || run.status
           ),
         {:ok, metadata} <-
           normalize_implementation_run_metadata(
             run.metadata,
             Map.get(attrs, "metadata") || Map.get(attrs, :metadata)
           ) do
      now = DateTime.utc_now()

      result_summary =
        Map.get(attrs, "result_summary") || Map.get(attrs, :result_summary) || run.result_summary

      {:ok,
       %{
         status: status,
         branch_name:
           normalize_optional_text(
             Map.get(attrs, "branch_name") || Map.get(attrs, :branch_name) || run.branch_name
           ),
         pull_request_url:
           normalize_optional_text(
             Map.get(attrs, "pull_request_url") || Map.get(attrs, :pull_request_url) ||
               run.pull_request_url
           ),
         result_summary:
           normalize_implementation_run_summary(
             result_summary,
             implementation_run_status_summary(status)
           ),
         started_at: implementation_run_started_at(run, status, now),
         completed_at: implementation_run_completed_at(run, status, now),
         metadata: metadata
       }}
    end
  end

  defp normalize_implementation_run_status(value) when value in @implementation_run_statuses,
    do: {:ok, value}

  defp normalize_implementation_run_status(_value),
    do: {:error, :invalid_implementation_run_status}

  defp normalize_implementation_run_metadata(existing, nil) when is_map(existing),
    do: {:ok, existing}

  defp normalize_implementation_run_metadata(_existing, nil), do: {:ok, %{}}

  defp normalize_implementation_run_metadata(existing, attrs) when is_map(attrs) do
    base = if is_map(existing), do: existing, else: %{}
    {:ok, Map.merge(base, stringify_metadata(attrs))}
  end

  defp normalize_implementation_run_metadata(_existing, _attrs),
    do: {:error, :invalid_implementation_run_metadata}

  defp implementation_run_started_at(
         %ImplementationRun{started_at: %DateTime{} = started_at},
         _status,
         _now
       ),
       do: started_at

  defp implementation_run_started_at(_run, status, now) do
    if status in ["pending_plan", "queued", "running", "awaiting_review"], do: now, else: nil
  end

  defp implementation_run_completed_at(
         %ImplementationRun{completed_at: %DateTime{} = completed_at},
         status,
         _now
       ) do
    if implementation_run_closed_status?(status), do: completed_at, else: nil
  end

  defp implementation_run_completed_at(_run, status, now) do
    if implementation_run_closed_status?(status), do: now, else: nil
  end

  defp implementation_run_closed_status?(status),
    do: status in ["completed", "failed", "blocked", "awaiting_repo_access"]

  defp create_implementation_run(project_id, user_id, recommendation_decision_id, now, attrs) do
    status = Map.fetch!(attrs, :status)

    %ImplementationRun{}
    |> ImplementationRun.changeset(%{
      user_id: user_id,
      project_id: project_id,
      agent_id: Map.get(attrs, :agent_id),
      recommendation_decision_id: recommendation_decision_id,
      repo_full_name:
        Map.get(attrs, :repo_full_name) || get_in(attrs, [:metadata, "repo_full_name"]),
      status: status,
      result_summary:
        normalize_implementation_run_summary(
          Map.get(attrs, :result_summary),
          implementation_run_status_summary(status)
        ),
      queued_at: now,
      started_at:
        if(status in ["running", "pending_plan", "queued"],
          do: now,
          else: nil
        ),
      completed_at: if(implementation_run_closed_status?(status), do: now, else: nil),
      metadata: Map.get(attrs, :metadata) || %{}
    })
    |> Repo.insert()
  end

  defp implementation_run_launch_failure_summary(recommendation, reason) do
    title =
      recommendation
      |> Map.get(:title)
      |> normalize_implementation_run_summary("the accepted recommendation")

    "Accepted #{title}, but delivery could not start. " <>
      RunErrorCopy.runtime_failure(%{source: "effect", details: reason})
  end

  defp redacted_implementation_run_error(reason) do
    reason
    |> inspect(limit: 20)
    |> Redaction.redact_string()
  end

  defp normalize_implementation_run_summary(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    if implementation_run_summary_safe?(trimmed) do
      trimmed
      |> UserFacingCopy.polish_text()
      |> normalize_optional_text()
      |> case do
        nil -> fallback
        "" -> fallback
        summary -> if implementation_run_summary_safe?(summary), do: summary, else: fallback
      end
    else
      fallback
    end
  end

  defp normalize_implementation_run_summary(_value, fallback), do: fallback

  defp implementation_run_summary_safe?(value) when is_binary(value) do
    lower = String.downcase(value)

    technical_marker? =
      String.contains?(lower, [
        "access_token",
        "api_key",
        "apikey",
        "authorization",
        "bearer",
        "client_secret",
        "dbconnection",
        "ecto.",
        "functionclauseerror",
        "http_status",
        "internal_stacktrace",
        "openrouter_api_key",
        "password",
        "phoenix.",
        "postgrex",
        "private_key",
        "refresh_token",
        "runtimeerror",
        "secret",
        "stacktrace",
        "token=",
        "traceback"
      ]) or String.contains?(value, ["{", "}", "=>", "#PID<"])

    not technical_marker?
  end

  defp implementation_run_summary_safe?(_value), do: false

  defp implementation_run_status_summary("pending_plan"), do: "Delivery work is being planned."

  defp implementation_run_status_summary("awaiting_repo_access"),
    do: "Grant repo access before delivery can continue."

  defp implementation_run_status_summary("queued"), do: "Delivery work is queued."
  defp implementation_run_status_summary("running"), do: "Delivery work is in progress."

  defp implementation_run_status_summary("blocked"),
    do: "Delivery work is blocked. Review the latest project status."

  defp implementation_run_status_summary("awaiting_review"),
    do: "Delivery work is ready for review."

  defp implementation_run_status_summary("completed"), do: "Delivery work completed."

  defp implementation_run_status_summary("failed"),
    do: "Delivery work did not complete. Review the latest project status."

  defp implementation_run_status_summary(_status), do: "Delivery work needs review."

  defp normalize_optional_text(nil), do: nil
  defp normalize_optional_text(""), do: nil
  defp normalize_optional_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_optional_text(value), do: value

  defp stringify_metadata(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_map(value) ->
        Map.put(acc, to_string(key), stringify_metadata(value))

      {key, value}, acc when is_list(value) ->
        Map.put(
          acc,
          to_string(key),
          Enum.map(value, fn
            item when is_map(item) -> stringify_metadata(item)
            item -> item
          end)
        )

      {key, value}, acc ->
        Map.put(acc, to_string(key), value)
    end)
  end

  defp stringify_metadata(_value), do: %{}

  defp maybe_filter_user(query, nil), do: query
  defp maybe_filter_user(query, ""), do: query

  defp maybe_filter_user(query, user_id) when is_binary(user_id) do
    where(query, [project], project.user_id == ^user_id)
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, ""), do: query

  defp maybe_filter_status(query, status) when is_binary(status) do
    where(query, [project], project.status == ^status)
  end

  defp maybe_filter_project_item_user(query, nil), do: query
  defp maybe_filter_project_item_user(query, ""), do: query

  defp maybe_filter_project_item_user(query, user_id) when is_binary(user_id) do
    where(query, [item], item.user_id == ^user_id)
  end

  defp maybe_filter_project_id(query, nil), do: query
  defp maybe_filter_project_id(query, ""), do: query

  defp maybe_filter_project_id(query, project_id) when is_binary(project_id) do
    where(query, [item], item.project_id == ^project_id)
  end

  defp maybe_filter_project_item_status(query, nil), do: query
  defp maybe_filter_project_item_status(query, ""), do: query

  defp maybe_filter_project_item_status(query, status) when is_binary(status) do
    where(query, [item], item.status == ^status)
  end

  defp maybe_filter_project_item_type(query, nil), do: query
  defp maybe_filter_project_item_type(query, ""), do: query

  defp maybe_filter_project_item_type(query, item_type) when is_binary(item_type) do
    where(query, [item], item.item_type == ^item_type)
  end

  defp maybe_filter_open_project_recommendations(query, true) do
    where(query, [insight, _agent], insight.status in ^@open_insight_statuses)
  end

  defp maybe_filter_open_project_recommendations(query, _open_only?), do: query

  defp maybe_filter_decision_user(query, nil), do: query
  defp maybe_filter_decision_user(query, ""), do: query

  defp maybe_filter_decision_user(query, user_id),
    do: where(query, [decision], decision.user_id == ^user_id)

  defp maybe_filter_decision_project(query, nil), do: query
  defp maybe_filter_decision_project(query, ""), do: query

  defp maybe_filter_decision_project(query, project_id),
    do: where(query, [decision], decision.project_id == ^project_id)

  defp maybe_filter_decision_source_insight(query, nil), do: query
  defp maybe_filter_decision_source_insight(query, ""), do: query

  defp maybe_filter_decision_source_insight(query, source_insight_id),
    do: where(query, [decision], decision.source_insight_id == ^source_insight_id)

  defp maybe_filter_repo_grant_user(query, nil), do: query
  defp maybe_filter_repo_grant_user(query, ""), do: query

  defp maybe_filter_repo_grant_user(query, user_id),
    do: where(query, [grant], grant.user_id == ^user_id)

  defp maybe_filter_repo_grant_project(query, nil), do: query
  defp maybe_filter_repo_grant_project(query, ""), do: query

  defp maybe_filter_repo_grant_project(query, project_id),
    do: where(query, [grant], grant.project_id == ^project_id)

  defp maybe_filter_repo_grant_provider(query, nil), do: query
  defp maybe_filter_repo_grant_provider(query, ""), do: query

  defp maybe_filter_repo_grant_provider(query, provider),
    do: where(query, [grant], grant.provider == ^provider)

  defp maybe_filter_repo_grant_repo(query, nil), do: query
  defp maybe_filter_repo_grant_repo(query, ""), do: query

  defp maybe_filter_repo_grant_repo(query, repo_full_name),
    do: where(query, [grant], grant.repo_full_name == ^repo_full_name)

  defp maybe_filter_repo_grant_status(query, nil), do: query
  defp maybe_filter_repo_grant_status(query, ""), do: query

  defp maybe_filter_repo_grant_status(query, status),
    do: where(query, [grant], grant.status == ^status)

  defp maybe_filter_run_user(query, nil), do: query
  defp maybe_filter_run_user(query, ""), do: query
  defp maybe_filter_run_user(query, user_id), do: where(query, [run], run.user_id == ^user_id)

  defp maybe_filter_run_project(query, nil), do: query
  defp maybe_filter_run_project(query, ""), do: query

  defp maybe_filter_run_project(query, project_id),
    do: where(query, [run], run.project_id == ^project_id)

  defp maybe_filter_run_recommendation_decision(query, nil), do: query
  defp maybe_filter_run_recommendation_decision(query, ""), do: query

  defp maybe_filter_run_recommendation_decision(query, recommendation_decision_id),
    do: where(query, [run], run.recommendation_decision_id == ^recommendation_decision_id)

  defp maybe_filter_run_statuses(query, nil), do: query
  defp maybe_filter_run_statuses(query, []), do: where(query, [run], false)

  defp maybe_filter_run_statuses(query, statuses) when is_list(statuses),
    do: where(query, [run], run.status in ^statuses)

  defp maybe_filter_run_statuses(query, status) when is_binary(status),
    do: where(query, [run], run.status == ^status)

  defp normalize_slug(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_slug(value), do: value

  defp normalize_project_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_project_name(_value), do: nil

  defp project_life_domain_metadata(metadata, attrs) do
    metadata = metadata || %{}

    life_domain_attrs =
      %{
        "life_domain" => normalize_life_domain(Map.get(attrs, "life_domain")),
        "life_domain_confidence" => normalize_confidence(Map.get(attrs, "confidence")),
        "life_domain_reasoning" => normalize_text(Map.get(attrs, "reasoning")),
        "life_domain_needs_confirmation" =>
          normalize_boolean(Map.get(attrs, "needs_confirmation")),
        "life_domain_source" =>
          normalize_text(Map.get(attrs, "source")) || "chief_of_staff_weekend",
        "life_domain_reviewed_at" => normalize_reviewed_at(Map.get(attrs, "reviewed_at"))
      }
      |> compact_map()

    Map.merge(metadata, life_domain_attrs)
  end

  defp normalize_life_domain(value) when value in ["home", "work"], do: value

  defp normalize_life_domain(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_life_domain()
  end

  defp normalize_life_domain(_value), do: nil

  defp normalize_confidence(value) when is_float(value),
    do: value |> max(0.0) |> min(1.0)

  defp normalize_confidence(value) when is_integer(value), do: normalize_confidence(value / 1)

  defp normalize_confidence(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> normalize_confidence(parsed)
      _ -> nil
    end
  end

  defp normalize_confidence(_value), do: nil

  defp normalize_boolean(value) when value in [true, false], do: value
  defp normalize_boolean("true"), do: true
  defp normalize_boolean("false"), do: false
  defp normalize_boolean(_value), do: nil

  defp normalize_reviewed_at(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_reviewed_at(value) when is_binary(value), do: normalize_text(value)
  defp normalize_reviewed_at(_value), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_value), do: nil

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp compact_map(_map), do: %{}
end
