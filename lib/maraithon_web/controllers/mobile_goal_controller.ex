defmodule MaraithonWeb.MobileGoalController do
  use MaraithonWeb, :controller

  alias Maraithon.Goals
  alias Maraithon.Goals.Goal
  alias MaraithonWeb.MobileJSON
  alias MaraithonWeb.MobileParams

  @goal_param_keys ~w(
    category status title desired_outcome why success_metric priority sensitivity
    proactive_visibility review_cadence starts_on target_at last_reviewed_at next_review_at metadata
  )
  @progress_param_keys ~w(source summary progress_state confidence evidence metadata occurred_at)

  def index(conn, params) do
    user_id = conn.assigns.current_user.id

    goals =
      Goals.list_goals(user_id,
        status: text_param(params, "status") || "active",
        category: text_param(params, "category") || "all",
        query: text_param(params, "q"),
        limit: limit(params)
      )

    json(conn, %{goals: Enum.map(goals, &MobileJSON.goal/1)})
  end

  def create(conn, params) do
    user_id = conn.assigns.current_user.id

    case Goals.create_goal(user_id, goal_params(params)) do
      {:ok, goal} ->
        conn
        |> put_status(:created)
        |> json(%{goal: MobileJSON.goal(goal)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(reason))
    end
  end

  def show(conn, %{"id" => goal_id}) do
    user_id = conn.assigns.current_user.id

    case Goals.get_goal(user_id, goal_id) do
      %Goal{} = goal ->
        json(conn, %{goal: MobileJSON.goal(goal, include_detail: true)})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(MobileJSON.error(:not_found))
    end
  end

  def update(conn, %{"id" => goal_id} = params) do
    user_id = conn.assigns.current_user.id

    case Goals.update_goal(user_id, goal_id, goal_params(params)) do
      {:ok, goal} ->
        json(conn, %{goal: MobileJSON.goal(goal)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(MobileJSON.error(:not_found))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(reason))
    end
  end

  def delete(conn, %{"id" => goal_id}) do
    user_id = conn.assigns.current_user.id

    case Goals.delete_goal(user_id, goal_id) do
      {:ok, goal} ->
        json(conn, %{
          ok: true,
          deleted: true,
          delete_mode: "archive_goal",
          goal: MobileJSON.goal(goal)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(MobileJSON.error(:not_found))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(reason))
    end
  end

  def progress(conn, %{"id" => goal_id} = params) do
    user_id = conn.assigns.current_user.id

    case Goals.record_progress(user_id, goal_id, progress_params(params), source: "manual") do
      {:ok, progress_update} ->
        conn
        |> put_status(:created)
        |> json(%{progress_update: MobileJSON.goal_progress_update(progress_update)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(MobileJSON.error(:not_found))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(reason))
    end
  end

  def review(conn, %{"id" => goal_id}) do
    user_id = conn.assigns.current_user.id

    case Goals.review_goal_alignment(user_id, goal_id: goal_id, trigger: "manual") do
      {:ok, review_run} ->
        json(conn, %{review_run: MobileJSON.goal_review_run(review_run)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(MobileJSON.error(:not_found))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(reason))
    end
  end

  defp goal_params(%{"goal" => goal}) when is_map(goal),
    do: MobileParams.sanitize(goal, @goal_param_keys)

  defp goal_params(params), do: MobileParams.sanitize(params, @goal_param_keys)

  defp progress_params(%{"progress" => progress}) when is_map(progress),
    do: MobileParams.sanitize(progress, @progress_param_keys)

  defp progress_params(params), do: MobileParams.sanitize(params, @progress_param_keys)

  defp limit(params) do
    case Integer.parse(to_string(Map.get(params, "limit", "50"))) do
      {value, ""} -> value |> max(1) |> min(200)
      _ -> 50
    end
  end

  defp text_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _other ->
        nil
    end
  end
end
