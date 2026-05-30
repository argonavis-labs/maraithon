defmodule Maraithon.Insights do
  @moduledoc """
  User-scoped actionable insights emitted by advisor agents.
  """

  import Ecto.Query

  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights.Detail
  alias Maraithon.Insights.Insight
  alias Maraithon.Repo
  alias Maraithon.Todos

  @open_statuses ["new", "snoozed"]
  @attention_modes ["act_now", "monitor"]

  def list_open_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 20)
    attention_mode = Keyword.get(opts, :attention_mode)

    user_id
    |> open_for_user_query(attention_mode)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_open_with_details_for_user(user_id, opts \\ []) when is_binary(user_id) do
    insights = list_open_for_user(user_id, opts)
    deliveries_by_insight_id = deliveries_by_insight_id(user_id, insights)
    timezone_info = Keyword.get(opts, :timezone_info)

    Enum.map(insights, fn insight ->
      deliveries = Map.get(deliveries_by_insight_id, insight.id, [])

      %{
        insight: insight,
        detail: Detail.build(insight, deliveries, timezone_info: timezone_info)
      }
    end)
  end

  def list_open_act_now_for_user(user_id, opts \\ []) when is_binary(user_id) do
    list_open_for_user(user_id, Keyword.put(opts, :attention_mode, "act_now"))
  end

  def list_open_monitor_for_user(user_id, opts \\ []) when is_binary(user_id) do
    list_open_for_user(user_id, Keyword.put(opts, :attention_mode, "monitor"))
  end

  def list_open_act_now_with_details_for_user(user_id, opts \\ []) when is_binary(user_id) do
    list_open_with_details_for_user(user_id, Keyword.put(opts, :attention_mode, "act_now"))
  end

  def list_open_monitor_with_details_for_user(user_id, opts \\ []) when is_binary(user_id) do
    list_open_with_details_for_user(user_id, Keyword.put(opts, :attention_mode, "monitor"))
  end

  def list_recent_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 40)

    Insight
    |> where([i], i.user_id == ^user_id)
    |> order_by([i], desc: i.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def record_many(user_id, agent_id, insights) when is_binary(user_id) and is_list(insights) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    inserted =
      Enum.reduce(insights, [], fn insight_attrs, acc ->
        attrs =
          insight_attrs
          |> normalize_attrs(user_id, agent_id)
          |> Map.put_new("status", "new")

        case record_one(attrs, now) do
          {:ok, insight} -> [insight | acc]
          {:error, _reason} -> acc
        end
      end)
      |> Enum.reverse()

    {:ok, inserted}
  end

  def acknowledge(user_id, insight_id) when is_binary(user_id) and is_binary(insight_id) do
    update_status(user_id, insight_id, "acknowledged")
  end

  def dismiss(user_id, insight_id) when is_binary(user_id) and is_binary(insight_id) do
    update_status(user_id, insight_id, "dismissed")
  end

  def snooze(user_id, insight_id, until_datetime)
      when is_binary(user_id) and is_binary(insight_id) and is_struct(until_datetime, DateTime) do
    with %Insight{} = insight <- Repo.get_by(Insight, id: insight_id, user_id: user_id),
         {:ok, updated} <-
           insight
           |> Ecto.Changeset.change(status: "snoozed", snoozed_until: until_datetime)
           |> Repo.update(),
         {:ok, _todo} <- Todos.sync_from_insight(updated) do
      {:ok, updated}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_one(attrs, now) do
    Repo.transaction(fn ->
      dismiss_prior_open_revisions(
        attrs["user_id"],
        attrs["tracking_key"],
        attrs["dedupe_key"],
        now
      )

      case upsert(attrs, now) do
        {:ok, insight} ->
          case Todos.sync_from_insight(insight) do
            {:ok, _todo} -> insight
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %Insight{} = insight} -> {:ok, insight}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert(attrs, now) do
    %Insight{}
    |> Insight.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [
          source: attrs["source"],
          category: attrs["category"],
          title: attrs["title"],
          summary: attrs["summary"],
          recommended_action: attrs["recommended_action"],
          priority: attrs["priority"],
          confidence: attrs["confidence"],
          status: "new",
          attention_mode: attrs["attention_mode"],
          snoozed_until: nil,
          due_at: attrs["due_at"],
          source_id: attrs["source_id"],
          source_occurred_at: attrs["source_occurred_at"],
          tracking_key: attrs["tracking_key"],
          metadata: attrs["metadata"],
          updated_at: now
        ]
      ],
      conflict_target: [:user_id, :dedupe_key],
      returning: true
    )
  end

  defp open_for_user_query(user_id, attention_mode) when is_binary(user_id) do
    now = DateTime.utc_now()

    Insight
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.status in ^@open_statuses)
    |> where([i], i.status != "snoozed" or is_nil(i.snoozed_until) or i.snoozed_until <= ^now)
    |> maybe_filter_attention_mode(attention_mode)
    |> order_by([i], desc: i.priority, asc_nulls_last: i.due_at, desc: i.inserted_at)
  end

  defp maybe_filter_attention_mode(query, mode) when mode in @attention_modes do
    where(query, [i], i.attention_mode == ^mode)
  end

  defp maybe_filter_attention_mode(query, _mode), do: query

  defp deliveries_by_insight_id(_user_id, []), do: %{}

  defp deliveries_by_insight_id(user_id, insights)
       when is_binary(user_id) and is_list(insights) do
    insight_ids = Enum.map(insights, & &1.id)

    Delivery
    |> where([d], d.user_id == ^user_id and d.insight_id in ^insight_ids)
    |> order_by([d], desc_nulls_last: d.sent_at, desc: d.inserted_at)
    |> Repo.all()
    |> Enum.group_by(& &1.insight_id)
  end

  defp update_status(user_id, insight_id, status) do
    with %Insight{} = insight <- Repo.get_by(Insight, id: insight_id, user_id: user_id),
         {:ok, updated} <-
           insight
           |> Ecto.Changeset.change(status: status, snoozed_until: nil)
           |> Repo.update(),
         {:ok, _todo} <- Todos.sync_from_insight(updated) do
      {:ok, updated}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dismiss_prior_open_revisions(_user_id, nil, _dedupe_key, _now), do: {0, nil}

  defp dismiss_prior_open_revisions(user_id, tracking_key, dedupe_key, now)
       when is_binary(user_id) and is_binary(tracking_key) and is_binary(dedupe_key) do
    Insight
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.tracking_key == ^tracking_key)
    |> where([i], i.status in ^@open_statuses)
    |> where([i], i.dedupe_key != ^dedupe_key)
    |> Repo.update_all(set: [status: "dismissed", snoozed_until: nil, updated_at: now])
  end

  defp normalize_attrs(attrs, user_id, agent_id) do
    dedupe_key = read_string(attrs, "dedupe_key", Ecto.UUID.generate())
    attention_mode = read_string(attrs, "attention_mode", "act_now")
    metadata = read_map(attrs, "metadata")

    %{
      "user_id" => user_id,
      "agent_id" => agent_id,
      "source" => read_string(attrs, "source", "system"),
      "category" => read_string(attrs, "category", "general"),
      "title" => read_string(attrs, "title", "Actionable insight"),
      "summary" => read_string(attrs, "summary", "Review this item."),
      "recommended_action" =>
        read_string(attrs, "recommended_action", "Review and decide next step"),
      "priority" => clamp_integer(read_integer(attrs, "priority", 50), 0, 100),
      "confidence" => clamp_float(read_float(attrs, "confidence", 0.5), 0.0, 1.0),
      "attention_mode" => normalize_attention_mode(attention_mode),
      "due_at" => read_datetime(attrs, "due_at"),
      "source_id" => read_string(attrs, "source_id", nil),
      "source_occurred_at" => read_datetime(attrs, "source_occurred_at"),
      "dedupe_key" => dedupe_key,
      "tracking_key" => read_string(attrs, "tracking_key", dedupe_key),
      "metadata" => normalize_metadata_attention(metadata, attention_mode)
    }
  end

  defp read_string(attrs, key, default) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end

  defp read_integer(attrs, key, default) do
    value = fetch_attr(attrs, key)

    cond do
      is_integer(value) ->
        value

      is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      true ->
        default
    end
  end

  defp read_float(attrs, key, default) do
    value = fetch_attr(attrs, key)

    cond do
      is_float(value) ->
        value

      is_integer(value) ->
        value / 1

      is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      true ->
        default
    end
  end

  defp read_datetime(attrs, key) do
    case fetch_attr(attrs, key) do
      %DateTime{} = value ->
        value

      %NaiveDateTime{} = value ->
        DateTime.from_naive!(value, "Etc/UTC")

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_map(attrs, key) do
    case fetch_attr(attrs, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_boolean(attrs, key, default) do
    case fetch_attr(attrs, key) do
      value when is_boolean(value) ->
        value

      value when is_binary(value) ->
        case String.downcase(String.trim(value)) do
          "true" -> true
          "false" -> false
          _ -> default
        end

      _ ->
        default
    end
  end

  defp clamp_integer(value, min, _max) when value < min, do: min
  defp clamp_integer(value, _min, max) when value > max, do: max
  defp clamp_integer(value, _min, _max), do: value

  defp clamp_float(value, min, _max) when value < min, do: min
  defp clamp_float(value, _min, max) when value > max, do: max
  defp clamp_float(value, _min, _max), do: value

  defp normalize_attention_mode("monitor"), do: "monitor"
  defp normalize_attention_mode(_mode), do: "act_now"

  defp normalize_metadata_attention(metadata, attention_mode) when is_map(metadata) do
    mode = normalize_attention_mode(attention_mode)
    metadata = stringify_keys(metadata)
    attention = Map.get(metadata, "attention", %{}) |> stringify_keys()

    metadata
    |> Map.put("attention", %{
      "mode" => read_string(attention, "mode", mode),
      "importance_band" => read_string(attention, "importance_band", "high"),
      "founder_action_required" =>
        read_boolean(attention, "founder_action_required", mode == "act_now"),
      "ownership_state" => read_string(attention, "ownership_state", "unknown"),
      "material_change_kind" =>
        read_string(attention, "material_change_kind", "initial_detection"),
      "change_summary" => read_string(attention, "change_summary", nil),
      "revision_key" => read_string(attention, "revision_key", nil),
      "re_notify_eligible" => read_boolean(attention, "re_notify_eligible", true)
    })
    |> ensure_action_draft_metadata()
  end

  defp normalize_metadata_attention(_metadata, attention_mode) do
    normalize_metadata_attention(%{}, attention_mode)
  end

  defp ensure_action_draft_metadata(metadata) when is_map(metadata) do
    record = read_map(metadata, "record")

    if record == %{} do
      metadata
    else
      person = read_string(record, "person", read_string(metadata, "person", "the recipient"))
      source = read_string(record, "source", read_string(metadata, "source", "thread"))
      deadline = read_string(record, "deadline", read_string(metadata, "deadline", nil))
      context = read_map(metadata, "conversation_context")

      metadata
      |> maybe_put_new_list(
        "missing_inputs",
        missing_inputs_for_action(metadata, record, deadline)
      )
      |> maybe_put_new_list(
        "suggested_reply_points",
        suggested_reply_points_for_action(person, source, deadline)
      )
      |> maybe_put_new_string("draft_plan", draft_plan_for_action(person, source, context))
    end
  end

  defp missing_inputs_for_action(metadata, record, deadline) do
    status = read_string(record, "status", read_string(metadata, "status", nil))

    []
    |> maybe_append(
      "Specific answer or promised item to send from the source thread",
      status == "unresolved"
    )
    |> maybe_append("Timing you are comfortable committing to", is_nil(deadline))
    |> Enum.take(3)
  end

  defp suggested_reply_points_for_action(person, source, deadline) do
    [
      "Acknowledge #{person}.",
      suggested_middle_reply_point(source),
      "Give timing only if the source thread supports it#{deadline_suffix(deadline)}."
    ]
  end

  defp suggested_middle_reply_point(source) do
    if String.contains?(source || "", "slack") do
      "Name the actual promise from the Slack thread and whether it is ready or still in progress."
    else
      "Answer the specific ask from the thread or say what you will check next."
    end
  end

  defp deadline_suffix(nil), do: ""
  defp deadline_suffix(deadline), do: ": #{deadline}"

  defp draft_plan_for_action(person, source, context) do
    case read_string(context, "notification_posture", "interrupt_now") do
      "heads_up" ->
        "Draft in your voice: acknowledge that the thread is moving, avoid saying nobody replied, and only confirm your ownership if the evidence supports it."

      "insufficient_context" ->
        "Draft in your voice: avoid strong claims, provide the minimum safe next step, and do not imply the full thread was checked."

      _ ->
        if String.contains?(source || "", "slack") do
          "Draft in your voice: close the Slack loop with #{person} by naming the actual promise, current status, and the timing you can safely stand behind."
        else
          "Draft in your voice: reply to #{person} with the direct answer, the next step you can stand behind, and timing only if it is supported by the thread."
        end
    end
  end

  defp maybe_put_new_list(map, key, value) when is_list(value) do
    case Map.get(map, key) do
      existing when is_list(existing) and existing != [] -> map
      _ -> if value == [], do: map, else: Map.put(map, key, value)
    end
  end

  defp maybe_put_new_string(map, key, value) when is_binary(value) do
    case Map.get(map, key) do
      existing when is_binary(existing) and existing != "" -> map
      _ -> Map.put(map, key, value)
    end
  end

  defp maybe_append(list, value, true), do: list ++ [value]
  defp maybe_append(list, _value, false), do: list

  defp fetch_attr(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(attrs, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
