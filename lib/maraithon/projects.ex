defmodule Maraithon.Projects do
  @moduledoc """
  Context for managing project-scoped operating state.
  """

  import Ecto.Query

  alias Maraithon.Agents.Agent
  alias Maraithon.Insights.Insight
  alias Maraithon.Projects.Project
  alias Maraithon.Projects.ProjectItem
  alias Maraithon.Repo

  @project_item_limit 10
  @recommendation_limit 5
  @open_insight_statuses ["new", "snoozed"]

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
    end)
  end

  def list_project_recommendations(_project_id, _user_id, _opts), do: []

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
end
