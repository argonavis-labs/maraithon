defmodule MaraithonWeb.MobileTodoController do
  use MaraithonWeb, :controller

  alias Maraithon.{SourceFreshness, Todos}
  alias MaraithonWeb.MobileJSON
  alias MaraithonWeb.MobileParams

  @todo_param_keys ~w(
    source source_account_label kind attention_mode title todo summary next_action due_at due_date
    notes action_plan action_draft draft owner_label priority status snoozed_until source_item_id
    source_occurred_at dedupe_key metadata replace_metadata
  )

  def index(conn, params) do
    user_id = conn.assigns.current_user.id
    json_opts = json_opts(params, user_id)

    todos =
      Todos.list_for_user(user_id,
        limit: limit(params),
        statuses: status_filter(params),
        attention_mode: attention_filter(params),
        source: source_filter(params),
        due_nil?: due_nil_filter(params),
        due_after: due_after_filter(params),
        due_before: due_before_filter(params),
        query: text_param(params, "q"),
        sort_by: text_param(params, "sort") || "updated",
        sort_dir: text_param(params, "dir") || "desc"
      )

    json(conn, %{todos: Enum.map(todos, &MobileJSON.todo(&1, json_opts))})
  end

  def create(conn, params) do
    user_id = conn.assigns.current_user.id
    attrs = todo_params(params)
    json_opts = json_opts(params, user_id)

    case Todos.upsert_many(user_id, [attrs]) do
      {:ok, [todo]} ->
        conn
        |> put_status(:created)
        |> json(%{todo: MobileJSON.todo(todo, json_opts)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileJSON.error(reason))
    end
  end

  def show(conn, %{"id" => todo_id} = params) do
    user_id = conn.assigns.current_user.id
    json_opts = json_opts(params, user_id)

    case Todos.get_for_user(user_id, todo_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(MobileJSON.error(:not_found))

      todo ->
        json(conn, %{todo: MobileJSON.todo(todo, json_opts)})
    end
  end

  def update(conn, %{"id" => todo_id} = params) do
    user_id = conn.assigns.current_user.id
    json_opts = json_opts(params, user_id)

    case Todos.update_for_user(user_id, todo_id, todo_params(params)) do
      {:ok, todo} ->
        json(conn, %{todo: MobileJSON.todo(todo, json_opts)})

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

  def delete(conn, %{"id" => todo_id} = params) do
    user_id = conn.assigns.current_user.id
    note = text_param(params, "note") || "Dismissed from mobile."
    json_opts = json_opts(params, user_id)

    case Todos.dismiss(user_id, todo_id, note: note) do
      {:ok, todo} ->
        json(conn, %{
          ok: true,
          deleted: true,
          delete_mode: "dismiss_as_no_longer_relevant",
          todo: MobileJSON.todo(todo, json_opts)
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

  def perform_action(conn, %{"id" => todo_id, "action" => action} = params) do
    user_id = conn.assigns.current_user.id
    json_opts = json_opts(params, user_id)

    with {:ok, todo} <- apply_todo_action(user_id, todo_id, action, params) do
      json(conn, %{todo: MobileJSON.todo(todo, json_opts), action: normalize_action(action)})
    else
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

  defp apply_todo_action(user_id, todo_id, action, params) do
    note = text_param(params, "note")

    case normalize_action(action) do
      "done" ->
        Todos.mark_done(user_id, todo_id, note: note)

      "dismiss" ->
        Todos.dismiss(user_id, todo_id, note: note)

      "important" ->
        Todos.mark_important(user_id, todo_id, source: "mobile")

      feedback when feedback in ~w(helpful not_helpful) ->
        Todos.record_feedback(user_id, todo_id, feedback, source: "mobile")

      "snooze" ->
        Todos.snooze(user_id, todo_id, snooze_until(params), note: note)

      "see_less" ->
        case Todos.see_less_like(user_id, todo_id, source: "mobile") do
          {:ok, %{todo: todo}} -> {:ok, todo}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :unsupported_todo_action}
    end
  end

  defp normalize_action(action) when is_binary(action) do
    action
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "complete" -> "done"
      "completed" -> "done"
      "mark_done" -> "done"
      "not_important" -> "not_helpful"
      "not_helpful" -> "not_helpful"
      "helpful" -> "helpful"
      "dismissed" -> "dismiss"
      "mark_important" -> "important"
      "keep_active" -> "important"
      "see_less_like_this" -> "see_less"
      value -> value
    end
  end

  defp normalize_action(_action), do: ""

  defp snooze_until(params) do
    case text_param(params, "snoozed_until") || text_param(params, "until") do
      nil ->
        DateTime.utc_now()
        |> DateTime.add(24, :hour)
        |> DateTime.truncate(:second)

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> DateTime.utc_now() |> DateTime.add(24, :hour) |> DateTime.truncate(:second)
        end
    end
  end

  defp todo_params(%{"todo" => todo}) when is_map(todo),
    do: MobileParams.sanitize(todo, @todo_param_keys)

  defp todo_params(params), do: MobileParams.sanitize(params, @todo_param_keys)

  defp status_filter(%{"status" => "all"}), do: nil
  defp status_filter(%{"status" => "active"}), do: ["open", "snoozed"]
  defp status_filter(%{"status" => status}) when is_binary(status), do: status
  defp status_filter(_params), do: nil

  defp attention_filter(params) do
    case text_param(params, "attention") || text_param(params, "attention_mode") do
      value when value in ~w(act_now monitor) -> value
      _ -> nil
    end
  end

  defp source_filter(params) do
    case text_param(params, "source") do
      nil -> nil
      "all" -> nil
      source -> source
    end
  end

  defp due_nil_filter(%{"due" => "no_due"}), do: true
  defp due_nil_filter(%{"due_nil" => value}), do: truthy?(value)
  defp due_nil_filter(%{"due_nil?" => value}), do: truthy?(value)
  defp due_nil_filter(_params), do: false

  defp due_after_filter(%{"due" => "today"}) do
    Date.utc_today()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp due_after_filter(params), do: datetime_param(params, "due_after")

  defp due_before_filter(%{"due" => "overdue"}), do: DateTime.utc_now()

  defp due_before_filter(%{"due" => "today"}) do
    Date.utc_today()
    |> DateTime.new!(~T[23:59:59], "Etc/UTC")
  end

  defp due_before_filter(%{"due" => "week"}) do
    DateTime.utc_now()
    |> DateTime.add(7, :day)
  end

  defp due_before_filter(params) do
    datetime_param(params, "due_before") || datetime_param(params, "due_before_or_at")
  end

  defp limit(params) do
    case Integer.parse(to_string(Map.get(params, "limit", "200"))) do
      {value, ""} -> value |> max(1) |> min(500)
      _ -> 200
    end
  end

  defp text_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp datetime_param(params, key) do
    case text_param(params, key) do
      nil ->
        nil

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end
    end
  end

  defp json_opts(params, user_id) do
    include_card? = truthy?(Map.get(params, "include_cards") || Map.get(params, "include_card"))

    if include_card? do
      [include_card: true, source_health_snapshots: SourceFreshness.compact_for_prompt(user_id)]
    else
      [include_card: false]
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy?(_value), do: false
end
