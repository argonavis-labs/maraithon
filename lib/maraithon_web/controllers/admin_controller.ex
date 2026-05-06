defmodule MaraithonWeb.AdminController do
  use MaraithonWeb, :controller

  alias Maraithon.Admin
  alias Maraithon.Connections
  alias Maraithon.Insights.Refresh, as: InsightRefresh
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  def dashboard(conn, params) do
    with {:ok, activity_limit} <-
           parse_positive_integer_param(params["activity_limit"], 40, "activity_limit"),
         {:ok, failure_limit} <-
           parse_positive_integer_param(params["failure_limit"], 20, "failure_limit"),
         {:ok, log_limit} <- parse_positive_integer_param(params["log_limit"], 200, "log_limit") do
      snapshot =
        case Admin.safe_control_center_snapshot(
               activity_limit: activity_limit,
               failure_limit: failure_limit,
               log_limit: log_limit
             ) do
          {:ok, snapshot} -> snapshot
          {:degraded, snapshot} -> snapshot
        end

      json(conn, serialize_dashboard_snapshot(snapshot))
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: message})
    end
  end

  def agent_inspection(conn, %{"id" => id} = params) do
    with {:ok, event_limit} <-
           parse_positive_integer_param(params["event_limit"], 50, "event_limit"),
         {:ok, effect_limit} <-
           parse_positive_integer_param(params["effect_limit"], 20, "effect_limit"),
         {:ok, job_limit} <- parse_positive_integer_param(params["job_limit"], 20, "job_limit"),
         {:ok, log_limit} <- parse_positive_integer_param(params["log_limit"], 80, "log_limit") do
      case Admin.safe_agent_snapshot(
             id,
             event_limit: event_limit,
             effect_limit: effect_limit,
             job_limit: job_limit,
             log_limit: log_limit
           ) do
        {:ok, snapshot} ->
          json(conn, snapshot)

        {:degraded, snapshot} ->
          json(conn, snapshot)

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "not_found", message: "Agent not found"})
      end
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: message})
    end
  end

  def fly_logs(conn, params) do
    with {:ok, limit} <- parse_positive_integer_param(params["limit"], 100, "limit"),
         {:ok, apps} <- parse_apps_param(params["app"]),
         {:ok, next_token} <- parse_next_token_param(params["next_token"], apps),
         {:ok, snapshot} <-
           Admin.fly_logs(
             [
               limit: limit,
               region: blank_to_nil(params["region"]),
               next_token: next_token
             ]
             |> maybe_put_apps(apps)
           ) do
      json(conn, snapshot)
    else
      {:error, message} when is_binary(message) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: message})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "fly_logs_unavailable", message: inspect(reason)})
    end
  end

  def connections(conn, params) do
    user_id = parse_user_id(params["user_id"])

    snapshot =
      case Connections.safe_dashboard_snapshot(user_id, return_to: "/?user_id=#{user_id}") do
        {:ok, snapshot} -> snapshot
        {:degraded, snapshot} -> snapshot
      end

    json(conn, serialize_connections_snapshot(snapshot))
  end

  def todos(conn, params) do
    with {:ok, limit} <- parse_positive_integer_param(params["limit"], 40, "limit"),
         {:ok, statuses} <- parse_todo_statuses(params["status"] || params["statuses"]) do
      user_id = parse_user_id(params["user_id"])

      todos =
        Todos.list_for_user(user_id,
          limit: limit,
          statuses: statuses,
          query: blank_to_nil(params["query"]),
          source: blank_to_nil(params["source"]),
          kind: blank_to_nil(params["kind"]),
          attention_mode: blank_to_nil(params["attention_mode"])
        )

      json(conn, %{
        user_id: user_id,
        count: length(todos),
        todos: Enum.map(todos, &serialize_todo/1)
      })
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: message})
    end
  end

  def dismiss_todos(conn, params) do
    with {:ok, limit} <- parse_positive_integer_param(params["limit"], 40, "limit"),
         {:ok, statuses} <- parse_todo_statuses(params["status"] || params["statuses"]),
         {:ok, selector} <- parse_todo_selector(params) do
      user_id = parse_user_id(params["user_id"])
      note = blank_to_nil(params["reason"]) || "Dismissed from admin API."

      todos =
        case selector do
          {:ids, ids} ->
            Todos.list_by_ids(user_id, ids, statuses: statuses)

          {:query, query} ->
            Todos.list_for_user(user_id,
              limit: limit,
              statuses: statuses,
              query: query,
              source: blank_to_nil(params["source"]),
              kind: blank_to_nil(params["kind"]),
              attention_mode: blank_to_nil(params["attention_mode"])
            )

          :all_open ->
            Todos.list_for_user(user_id,
              limit: limit,
              statuses: statuses,
              source: blank_to_nil(params["source"]),
              kind: blank_to_nil(params["kind"]),
              attention_mode: blank_to_nil(params["attention_mode"])
            )
        end

      {dismissed, failed} =
        Enum.reduce(todos, {[], []}, fn todo, {dismissed, failed} ->
          case Todos.dismiss(user_id, todo.id, note: note) do
            {:ok, updated} -> {[updated | dismissed], failed}
            {:error, reason} -> {dismissed, [%{id: todo.id, reason: inspect(reason)} | failed]}
          end
        end)

      json(conn, %{
        user_id: user_id,
        matched_count: length(todos),
        dismissed_count: length(dismissed),
        failed_count: length(failed),
        dismissed: dismissed |> Enum.reverse() |> Enum.map(&serialize_todo/1),
        failed: Enum.reverse(failed)
      })
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: message})
    end
  end

  def refresh_insights(conn, params) do
    user_id = parse_user_id(params["user_id"])

    {:ok, result} =
      InsightRefresh.queue_for_user(user_id,
        requested_by: "admin_api",
        reason: blank_to_nil(params["reason"])
      )

    json(conn, normalize_json(result))
  end

  def disconnect_connection(conn, %{"provider" => provider} = params) do
    user_id = parse_user_id(params["user_id"])

    case Connections.disconnect(user_id, provider) do
      {:ok, _deleted} ->
        json(conn, %{status: "disconnected", provider: provider, user_id: user_id})

      {:error, :no_token} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "Connection not found"})

      {:error, :unsupported_provider} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: "Unsupported provider"})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "disconnect_failed", message: inspect(reason)})
    end
  end

  defp parse_positive_integer_param(nil, default, _field_name), do: {:ok, default}
  defp parse_positive_integer_param("", default, _field_name), do: {:ok, default}

  defp parse_positive_integer_param(value, _default, field_name) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, "#{field_name} must be a positive integer"}
    end
  end

  defp parse_todo_statuses(nil), do: {:ok, ["open", "snoozed"]}
  defp parse_todo_statuses(""), do: {:ok, ["open", "snoozed"]}

  defp parse_todo_statuses(value) when is_binary(value) do
    statuses =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    allowed = ~w(open snoozed done dismissed)

    if statuses != [] and Enum.all?(statuses, &(&1 in allowed)) do
      {:ok, statuses}
    else
      {:error, "status must include one or more of: #{Enum.join(allowed, ", ")}"}
    end
  end

  defp parse_todo_selector(params) do
    ids = parse_id_list(params["todo_ids"] || params["ids"])
    query = blank_to_nil(params["query"])
    dismiss_all_open? = truthy_param?(params["dismiss_all_open"])

    cond do
      ids != [] -> {:ok, {:ids, ids}}
      is_binary(query) -> {:ok, {:query, query}}
      dismiss_all_open? -> {:ok, :all_open}
      true -> {:error, "provide todo_ids, query, or dismiss_all_open=true"}
    end
  end

  defp parse_id_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_id_list(value) when is_binary(value), do: parse_id_list([value])
  defp parse_id_list(_value), do: []

  defp truthy_param?(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy_param?(_value), do: false

  defp parse_apps_param(nil), do: {:ok, []}
  defp parse_apps_param(""), do: {:ok, []}

  defp parse_apps_param(value) when is_binary(value) do
    apps =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, apps}
  end

  defp parse_next_token_param(nil, _apps), do: {:ok, nil}
  defp parse_next_token_param("", _apps), do: {:ok, nil}
  defp parse_next_token_param(_next_token, []), do: {:error, "next_token requires an app"}
  defp parse_next_token_param(next_token, [_app]), do: {:ok, next_token}

  defp parse_next_token_param(_next_token, _apps),
    do: {:error, "next_token requires exactly one app"}

  defp maybe_put_apps(opts, []), do: opts
  defp maybe_put_apps(opts, apps), do: Keyword.put(opts, :apps, apps)

  defp parse_user_id(nil), do: Connections.default_user_id()
  defp parse_user_id(""), do: Connections.default_user_id()

  defp parse_user_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> Connections.default_user_id()
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp serialize_dashboard_snapshot(snapshot) do
    Map.update(snapshot, :agents, [], fn agents ->
      Enum.map(agents, &serialize_agent/1)
    end)
  end

  defp serialize_connections_snapshot(snapshot) do
    normalize_json(snapshot)
  end

  defp serialize_todo(%Todo{} = todo) do
    %{
      id: todo.id,
      user_id: todo.user_id,
      source: todo.source,
      kind: todo.kind,
      attention_mode: todo.attention_mode,
      title: todo.title,
      summary: todo.summary,
      next_action: todo.next_action,
      priority: todo.priority,
      status: todo.status,
      source_item_id: todo.source_item_id,
      source_occurred_at: todo.source_occurred_at,
      snoozed_until: todo.snoozed_until,
      closed_at: todo.closed_at,
      dedupe_key: todo.dedupe_key,
      metadata: todo.metadata || %{},
      inserted_at: todo.inserted_at,
      updated_at: todo.updated_at
    }
    |> normalize_json()
  end

  defp serialize_agent(agent) when is_map(agent) do
    %{
      id: agent.id,
      behavior: agent.behavior,
      config: Map.get(agent, :config, %{}),
      status: agent.status,
      started_at: agent.started_at,
      stopped_at: agent.stopped_at,
      inserted_at: Map.get(agent, :inserted_at),
      updated_at: Map.get(agent, :updated_at)
    }
  end

  defp normalize_json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_json(value) when value in [nil, true, false], do: value
  defp normalize_json(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)

  defp normalize_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {normalize_json_key(key), normalize_json(item)} end)
    |> Map.new()
  end

  defp normalize_json(value), do: value

  defp normalize_json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_json_key(key), do: key
end
