defmodule MaraithonWeb.AdminController do
  use MaraithonWeb, :controller

  import Ecto.Query

  alias Maraithon.Admin
  alias Maraithon.AgentSubscriptions
  alias Maraithon.Agents
  alias Maraithon.Briefs.Brief
  alias Maraithon.ChiefOfStaff.SourceScope
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connections
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights.Refresh, as: InsightRefresh
  alias Maraithon.Insights.Insight
  alias Maraithon.Repo
  alias Maraithon.Runtime
  alias Maraithon.TelegramResponder
  alias Maraithon.TelegramAssistant.PushReceipt
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo
  alias Maraithon.Tools

  def dashboard(conn, params) do
    with {:ok, activity_limit} <-
           parse_positive_integer_param(params["activity_limit"], 40, "activity_limit"),
         {:ok, failure_limit} <-
           parse_positive_integer_param(params["failure_limit"], 20, "failure_limit"),
         {:ok, log_limit} <- parse_positive_integer_param(params["log_limit"], 200, "log_limit") do
      user_id = blank_to_nil(params["user_id"])

      snapshot =
        case Admin.safe_control_center_snapshot(
               activity_limit: activity_limit,
               failure_limit: failure_limit,
               log_limit: log_limit,
               user_id: user_id
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

  def gmail_recent(conn, params) do
    with {:ok, limit} <- parse_positive_integer_param(params["limit"], 5, "limit") do
      user_id = parse_user_id(params["user_id"])

      case Tools.execute("gmail_list_recent", %{
             "user_id" => user_id,
             "max_results" => min(limit, 20)
           }) do
        {:ok, %{messages: messages} = result} ->
          json(conn, %{
            user_id: user_id,
            source: "gmail",
            count: length(messages),
            provider_count: Map.get(result, :count, length(messages)),
            messages: Enum.map(messages, &serialize_gmail_message/1)
          })

        {:error, message} when is_binary(message) ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{error: "gmail_unavailable", message: message})

        {:error, reason} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{error: "gmail_unavailable", message: inspect(reason)})
      end
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", message: message})
    end
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

  def reset_operator_state(conn, params) do
    user_id = parse_user_id(params["user_id"])

    if truthy_param?(params["confirm"]) do
      result =
        Repo.transaction(fn ->
          {push_receipts, _} =
            from(receipt in PushReceipt, where: receipt.user_id == ^user_id)
            |> Repo.delete_all()

          {briefs, _} =
            from(brief in Brief, where: brief.user_id == ^user_id)
            |> Repo.delete_all()

          {todos, _} =
            from(todo in Todo, where: todo.user_id == ^user_id)
            |> Repo.delete_all()

          {deliveries, _} =
            from(delivery in Delivery, where: delivery.user_id == ^user_id)
            |> Repo.delete_all()

          {insights, _} =
            from(insight in Insight, where: insight.user_id == ^user_id)
            |> Repo.delete_all()

          %{
            user_id: user_id,
            deleted: %{
              telegram_push_receipts: push_receipts,
              briefs: briefs,
              todos: todos,
              insight_deliveries: deliveries,
              insights: insights
            },
            preserved: [
              "users",
              "connected_accounts",
              "oauth_tokens",
              "agents",
              "preference_rules",
              "user_memory"
            ]
          }
        end)

      case result do
        {:ok, payload} ->
          json(conn, payload)

        {:error, reason} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{error: "reset_failed", message: inspect(reason)})
      end
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "confirmation_required", message: "Pass confirm=true to reset state."})
    end
  end

  def push_telegram(conn, params) do
    user_id = parse_user_id(params["user_id"])
    message = blank_to_nil(params["message"] || params["body"])

    with body when is_binary(body) <- message,
         chat_id when is_binary(chat_id) <-
           blank_to_nil(params["chat_id"]) || telegram_chat_id(user_id),
         {:ok, result} <- TelegramResponder.send(chat_id, body, parse_mode: "HTML") do
      json(conn, %{
        status: "sent",
        user_id: user_id,
        chat_id: chat_id,
        message_id: result["message_id"]
      })
    else
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_params",
          message: "message and connected Telegram chat are required"
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "telegram_push_failed", message: inspect(reason)})
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

  def ensure_chief_of_staff(conn, params) do
    user_id = parse_user_id(params["user_id"])
    scope = SourceScope.resolve(user_id)
    subscriptions = SourceScope.subscriptions(scope, user_id)

    case ensure_chief_of_staff_agent(user_id, scope, subscriptions) do
      {:ok, status, agent} ->
        json(conn, %{
          status: status,
          user_id: user_id,
          agent: serialize_agent(agent),
          source_scope: scope,
          subscriptions: subscriptions,
          active_subscriptions:
            agent.id
            |> AgentSubscriptions.list_for_agent()
            |> Enum.map(&serialize_agent_subscription/1)
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "chief_of_staff_ensure_failed", message: format_error(reason)})
    end
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

  defp ensure_chief_of_staff_agent(user_id, source_scope, subscriptions) do
    config = chief_of_staff_config(%{}, user_id, source_scope, subscriptions)

    case chief_of_staff_agent_for_user(user_id) do
      nil ->
        case Runtime.start_agent(%{
               "user_id" => user_id,
               "behavior" => "ai_chief_of_staff",
               "config" => config
             }) do
          {:ok, agent} -> {:ok, "created", agent}
          {:error, reason} -> {:error, reason}
        end

      agent ->
        config = chief_of_staff_config(agent.config || %{}, user_id, source_scope, subscriptions)

        case Runtime.update_agent(agent.id, %{
               "user_id" => user_id,
               "behavior" => "ai_chief_of_staff",
               "config" => config
             }) do
          {:ok, agent} -> {:ok, "updated", agent}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp chief_of_staff_agent_for_user(user_id) do
    Agents.list_agents()
    |> Enum.find(fn agent ->
      agent.behavior == "ai_chief_of_staff" and
        (agent.user_id == user_id or get_in(agent.config || %{}, ["user_id"]) == user_id)
    end)
  end

  defp chief_of_staff_config(existing_config, user_id, source_scope, subscriptions) do
    existing_config
    |> Map.put_new("name", "AI Chief of Staff")
    |> Map.put_new("delivery_channels", ["telegram"])
    |> Map.put("user_id", user_id)
    |> Map.put("source_scope", source_scope)
    |> Map.put("subscribe", subscriptions)
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

  defp telegram_chat_id(user_id) when is_binary(user_id) do
    case ConnectedAccounts.get(user_id, "telegram") do
      %{status: "connected", external_account_id: value} when is_binary(value) ->
        blank_to_nil(value)

      %{status: "connected", metadata: metadata} when is_map(metadata) ->
        blank_to_nil(metadata["chat_id"])

      _ ->
        nil
    end
  end

  defp telegram_chat_id(_user_id), do: nil

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

  defp serialize_gmail_message(message) when is_map(message) do
    %{
      message_id: Map.get(message, :message_id),
      thread_id: Map.get(message, :thread_id),
      google_provider: Map.get(message, :google_provider),
      google_account_email: Map.get(message, :google_account_email),
      from: Map.get(message, :from),
      to: Map.get(message, :to),
      subject: Map.get(message, :subject),
      date: Map.get(message, :date),
      internal_date: Map.get(message, :internal_date),
      labels: Map.get(message, :labels, []),
      snippet: Map.get(message, :snippet)
    }
    |> normalize_json()
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
      user_id: Map.get(agent, :user_id),
      behavior: agent.behavior,
      config: Map.get(agent, :config, %{}),
      status: agent.status,
      started_at: agent.started_at,
      stopped_at: agent.stopped_at,
      inserted_at: Map.get(agent, :inserted_at),
      updated_at: Map.get(agent, :updated_at)
    }
  end

  defp serialize_agent_subscription(subscription) do
    %{
      topic: subscription.topic,
      status: subscription.status,
      user_id: subscription.user_id,
      project_id: subscription.project_id
    }
  end

  defp format_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> inspect()
  end

  defp format_error(reason), do: inspect(reason)

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
