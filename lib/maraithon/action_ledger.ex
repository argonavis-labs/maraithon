defmodule Maraithon.ActionLedger do
  @moduledoc """
  Records and explains material assistant decisions and side effects.

  Ledger entries are intentionally stored and returned through the same
  redaction pass. The ledger is for durable decision accountability, not raw
  prompt, token, webhook, or tool-output storage.
  """

  import Ecto.Query

  alias Maraithon.ActionLedger.Action
  alias Maraithon.Crm.Person
  alias Maraithon.Memory.Item, as: MemoryItem
  alias Maraithon.Normalization
  alias Maraithon.Redaction
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.PushReceipt
  alias Maraithon.Timezones
  alias Maraithon.Todos.ActivityEvent
  alias Maraithon.Todos.Todo
  alias MaraithonWeb.LocalTime

  @default_limit 20
  @max_limit 100
  @default_retention_days 180
  # SPEC 09 R1: "what did you do today" audit surface.
  @notable_limit 5
  @recent_pings_default_limit 8
  @recent_pings_max_limit 50
  @recent_pings_lookback_days 30

  def record(attrs) when is_map(attrs) do
    attrs
    |> normalize_attrs()
    |> redact_attrs()
    |> then(fn normalized ->
      %Action{}
      |> Action.changeset(normalized)
      |> Repo.insert()
    end)
  end

  def record(_attrs), do: {:error, :invalid_action_ledger_attrs}

  def list_recent(user_id, opts \\ [])

  def list_recent(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()
    event_type = Keyword.get(opts, :event_type)
    since = Keyword.get(opts, :since)
    until = Keyword.get(opts, :until)

    Action
    |> where([action], action.user_id == ^user_id)
    |> maybe_filter_event_type(event_type)
    |> maybe_filter_since(since)
    |> maybe_filter_until(until)
    |> order_by([action], desc: action.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_recent(_user_id, _opts), do: []

  @doc """
  Structured "what did you do" activity aggregate for one user across a
  period: `:today`, `:yesterday`, a single `Date`, or an explicit
  `{from_date, to_date}` range of `Date` structs (inclusive both ends).

  Periods resolve against the user's local day — the same
  `BriefingSchedules`-derived timezone the proactive planner and delivery
  planner already use for quiet hours/local time (see
  `MaraithonWeb.LocalTime.timezone_info_for_user/1` and
  `Maraithon.Timezones.offset_at/3`) — not the server's UTC day.

  Returns todos created/updated/closed, memories written by kind (titles
  only — memory content/summary are encrypted and never read here), people
  created/enriched, proactive sends with `why_now`/source refs, and
  holds/ignores with reasons.
  """
  def activity_summary(user_id, period) when is_binary(user_id) do
    {since, until, label} = resolve_period(user_id, period)

    %{
      period: %{label: label, since: since, until: until},
      todos: todos_activity(user_id, since, until),
      memories: memories_activity(user_id, since, until),
      people: people_activity(user_id, since, until),
      pings: pings_activity(user_id, since, until),
      holds: holds_activity(user_id, since, until)
    }
  end

  def activity_summary(_user_id, _period), do: empty_activity_summary()

  @doc """
  Most recent `sent_now`/`merged` proactive pushes with their recorded
  `why_now`/`model_summary` and source refs, independent of
  `activity_summary`'s period — for "why did you ping me (about X)?"
  lookups that may reach back further than today. `opts[:topic]` optionally
  filters to pushes whose why_now/origin mention it.
  """
  def recent_pings(user_id, opts \\ [])

  def recent_pings(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit =
      opts
      |> Keyword.get(:limit, @recent_pings_default_limit)
      |> Normalization.clamp_limit(@recent_pings_default_limit, @recent_pings_max_limit)

    topic = opts |> Keyword.get(:topic) |> normalize_topic()
    since = DateTime.add(DateTime.utc_now(), -@recent_pings_lookback_days * 86_400, :second)

    receipts =
      PushReceipt
      |> where([receipt], receipt.user_id == ^user_id)
      |> where([receipt], receipt.decision in ["sent_now", "merged"])
      |> where([receipt], receipt.inserted_at >= ^since)
      |> order_by([receipt], desc: receipt.inserted_at)
      |> limit(500)
      |> Repo.all()

    actions = sent_actions_for_join(user_id, since)

    receipts
    |> Enum.map(&ping_item(&1, actions))
    |> maybe_filter_topic(topic)
    |> Enum.take(limit)
  end

  def recent_pings(_user_id, _opts), do: []

  def find_by_object(user_id, object_type, object_id)
      when is_binary(user_id) and is_binary(object_type) and is_binary(object_id) do
    Action
    |> where([action], action.user_id == ^user_id)
    |> where(
      [action],
      fragment("? ->> ? = ?", action.result_object_refs, ^object_type, ^object_id) or
        fragment("? ->> ? = ?", action.metadata, ^object_type, ^object_id)
    )
    |> order_by([action], desc: action.inserted_at)
    |> Repo.all()
  end

  def find_by_object(_user_id, _object_type, _object_id), do: []

  def explain(user_id, action_id) when is_binary(user_id) and is_binary(action_id) do
    case Repo.get_by(Action, id: action_id, user_id: user_id) do
      %Action{} = action -> {:ok, explain_action(action)}
      nil -> {:error, :not_found}
    end
  end

  def explain(_user_id, _action_id), do: {:error, :invalid_action_reference}

  def explain_action(%Action{} = action) do
    %{
      id: action.id,
      user_id: action.user_id,
      agent_id: action.agent_id,
      surface: action.surface,
      event_type: action.event_type,
      status: action.status,
      reason_code: get_in(action.policy_decision || %{}, ["reason_code"]),
      message: get_in(action.policy_decision || %{}, ["message"]),
      confirmation_state: action.confirmation_state,
      source_evidence: redacted_map(action.source_evidence),
      model_summary: redacted_string(action.model_summary),
      result_object_refs: redacted_map(action.result_object_refs),
      remediation_hint: action.remediation_hint,
      metadata: redacted_map(action.metadata),
      inserted_at: action.inserted_at
    }
  end

  @doc """
  Return the default redacted map representation used by diagnostics exports.
  """
  def redacted_action(%Action{} = action) do
    %{
      id: action.id,
      user_id: action.user_id,
      agent_id: action.agent_id,
      surface: action.surface,
      event_type: action.event_type,
      status: action.status,
      source_evidence: redacted_map(action.source_evidence),
      policy_decision: redacted_map(action.policy_decision),
      model_summary: redacted_string(action.model_summary),
      confirmation_state: action.confirmation_state,
      result_object_refs: redacted_map(action.result_object_refs),
      remediation_hint: action.remediation_hint,
      metadata: redacted_map(action.metadata),
      inserted_at: action.inserted_at,
      updated_at: action.updated_at
    }
  end

  def retention_days do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retention_days, @default_retention_days)
    |> normalize_retention_days()
  end

  def redaction_manifest do
    %{
      retention_days: retention_days(),
      default_view: "redacted",
      disallowed_content: [
        "raw secrets",
        "access tokens",
        "refresh tokens",
        "authorization headers",
        "cookies",
        "raw prompts",
        "raw webhook bodies",
        "raw tool outputs"
      ],
      redaction: "Maraithon.Redaction field-name and credential-pattern scanners"
    }
  end

  def purge_expired(opts \\ []) when is_list(opts) do
    days = opts |> Keyword.get(:retention_days, retention_days()) |> normalize_retention_days()
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    {count, _rows} =
      Action
      |> where([action], action.inserted_at < ^cutoff)
      |> Repo.delete_all()

    {:ok, count}
  end

  defp maybe_filter_event_type(query, nil), do: query
  defp maybe_filter_event_type(query, ""), do: query

  defp maybe_filter_event_type(query, event_type) when is_binary(event_type) do
    where(query, [action], action.event_type == ^event_type)
  end

  defp maybe_filter_since(query, nil), do: query

  defp maybe_filter_since(query, %DateTime{} = since),
    do: where(query, [action], action.inserted_at >= ^since)

  defp maybe_filter_until(query, nil), do: query

  defp maybe_filter_until(query, %DateTime{} = until),
    do: where(query, [action], action.inserted_at < ^until)

  # -- SPEC 09 R1: activity_summary/2 period resolution -----------------

  defp resolve_period(user_id, :today) do
    {local_date, offset_hours} = local_day_context(user_id)
    {since, until} = day_bounds(local_date, offset_hours)
    {since, until, "today"}
  end

  defp resolve_period(user_id, :yesterday) do
    {local_date, offset_hours} = local_day_context(user_id)
    {since, until} = day_bounds(Date.add(local_date, -1), offset_hours)
    {since, until, "yesterday"}
  end

  defp resolve_period(user_id, %Date{} = date), do: resolve_period(user_id, {date, date})

  defp resolve_period(user_id, {%Date{} = from_date, %Date{} = to_date}) do
    {_local_date, offset_hours} = local_day_context(user_id)
    {since, _until} = day_bounds(from_date, offset_hours)
    {_since, until} = day_bounds(to_date, offset_hours)
    {since, until, range_label(from_date, to_date)}
  end

  defp resolve_period(user_id, _other), do: resolve_period(user_id, :today)

  defp range_label(%Date{} = date, %Date{} = date), do: Date.to_iso8601(date)

  defp range_label(%Date{} = from_date, %Date{} = to_date),
    do: "#{Date.to_iso8601(from_date)}..#{Date.to_iso8601(to_date)}"

  defp local_day_context(user_id) do
    info = LocalTime.timezone_info_for_user(user_id)
    now = DateTime.utc_now()
    offset_hours = Timezones.offset_at(info.name, now, info.offset_hours)
    local_date = now |> DateTime.add(offset_hours * 3600, :second) |> DateTime.to_date()
    {local_date, offset_hours}
  end

  defp day_bounds(%Date{} = date, offset_hours) do
    since = local_midnight_to_utc(date, offset_hours)
    until = local_midnight_to_utc(Date.add(date, 1), offset_hours)
    {since, until}
  end

  defp local_midnight_to_utc(%Date{} = date, offset_hours) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(-offset_hours * 3600, :second)
  end

  # -- SPEC 09 R1: activity_summary/2 section builders -------------------

  defp todos_activity(user_id, since, until) do
    events =
      ActivityEvent
      |> where([event], event.user_id == ^user_id)
      |> where([event], event.occurred_at >= ^since and event.occurred_at < ^until)
      |> order_by([event], desc: event.occurred_at)
      |> Repo.all()

    created = Enum.filter(events, &(&1.event_type == "created"))
    closed = Enum.filter(events, &(&1.event_type in ["marked_done", "deleted"]))

    updated =
      Todo
      |> where([todo], todo.user_id == ^user_id)
      |> where([todo], todo.updated_at >= ^since and todo.updated_at < ^until)
      |> where([todo], todo.inserted_at < ^since)
      |> order_by([todo], desc: todo.updated_at)
      |> select([todo], %{
        id: todo.id,
        title: todo.title,
        status: todo.status,
        updated_at: todo.updated_at
      })
      |> Repo.all()

    %{
      created: activity_bucket(created, &todo_event_item/1),
      closed: activity_bucket(closed, &todo_event_item/1),
      updated: activity_bucket(updated, & &1)
    }
  end

  defp todo_event_item(%ActivityEvent{} = event) do
    %{
      id: event.todo_id,
      title: event.todo_title,
      event_type: event.event_type,
      source: event.todo_source,
      occurred_at: event.occurred_at
    }
  end

  defp memories_activity(user_id, since, until) do
    items =
      MemoryItem
      |> where([item], item.user_id == ^user_id)
      |> where([item], item.inserted_at >= ^since and item.inserted_at < ^until)
      |> order_by([item], desc: item.inserted_at)
      |> select([item], %{
        id: item.id,
        kind: item.kind,
        title: item.title,
        inserted_at: item.inserted_at
      })
      |> Repo.all()

    by_kind =
      items
      |> Enum.group_by(&(&1.kind || "fact"))
      |> Map.new(fn {kind, group} -> {kind, length(group)} end)

    %{
      count: length(items),
      by_kind: by_kind,
      items: Enum.take(items, @notable_limit)
    }
  end

  defp people_activity(user_id, since, until) do
    created =
      Person
      |> where([person], person.user_id == ^user_id)
      |> where([person], person.inserted_at >= ^since and person.inserted_at < ^until)
      |> order_by([person], desc: person.inserted_at)
      |> select([person], %{
        id: person.id,
        display_name: person.display_name,
        inserted_at: person.inserted_at
      })
      |> Repo.all()

    enriched =
      Person
      |> where([person], person.user_id == ^user_id)
      |> where([person], person.updated_at >= ^since and person.updated_at < ^until)
      |> where([person], person.inserted_at < ^since)
      |> order_by([person], desc: person.updated_at)
      |> select([person], %{
        id: person.id,
        display_name: person.display_name,
        updated_at: person.updated_at
      })
      |> Repo.all()

    %{
      created: activity_bucket(created, & &1),
      enriched: activity_bucket(enriched, & &1)
    }
  end

  defp pings_activity(user_id, since, until) do
    receipts =
      PushReceipt
      |> where([receipt], receipt.user_id == ^user_id)
      |> where([receipt], receipt.decision in ["sent_now", "merged"])
      |> where([receipt], receipt.inserted_at >= ^since and receipt.inserted_at < ^until)
      |> order_by([receipt], desc: receipt.inserted_at)
      |> Repo.all()

    actions = sent_actions_for_join(user_id, since, until)
    items = Enum.map(receipts, &ping_item(&1, actions))

    activity_bucket(items, & &1)
  end

  defp holds_activity(user_id, since, until) do
    actions =
      Action
      |> where([action], action.user_id == ^user_id)
      |> where([action], action.event_type == "proactive.held")
      |> where([action], action.inserted_at >= ^since and action.inserted_at < ^until)
      |> order_by([action], desc: action.inserted_at)
      |> Repo.all()

    by_reason =
      actions
      |> Enum.group_by(&hold_reason/1)
      |> Map.new(fn {reason, group} -> {reason, length(group)} end)

    %{
      count: length(actions),
      by_reason: by_reason,
      items: Enum.take(Enum.map(actions, &hold_item/1), @notable_limit)
    }
  end

  defp hold_reason(%Action{} = action) do
    metadata = action.metadata || %{}
    Map.get(metadata, "hold_reason") || Map.get(metadata, "decision") || "unknown"
  end

  defp hold_item(%Action{} = action) do
    %{
      id: action.id,
      reason: hold_reason(action),
      why_now: redacted_string(action.model_summary),
      source_refs: redacted_map(action.result_object_refs),
      inserted_at: action.inserted_at
    }
  end

  defp sent_actions_for_join(user_id, since) do
    Action
    |> where([action], action.user_id == ^user_id)
    |> where([action], action.event_type == "proactive.sent")
    |> where([action], action.inserted_at >= ^since)
    |> Repo.all()
  end

  defp sent_actions_for_join(user_id, since, until) do
    Action
    |> where([action], action.user_id == ^user_id)
    |> where([action], action.event_type == "proactive.sent")
    |> where([action], action.inserted_at >= ^since and action.inserted_at < ^until)
    |> Repo.all()
  end

  defp ping_item(%PushReceipt{} = receipt, actions) do
    action = Enum.find(actions, &matches_receipt?(&1, receipt))

    %{
      receipt_id: receipt.id,
      dedupe_key: receipt.dedupe_key,
      origin_type: receipt.origin_type,
      origin_id: receipt.origin_id,
      decision: receipt.decision,
      why_now: action && redacted_string(action.model_summary),
      source_refs: action && redacted_map(action.result_object_refs),
      inserted_at: receipt.inserted_at
    }
  end

  defp matches_receipt?(%Action{} = action, %PushReceipt{} = receipt) do
    source_evidence = action.source_evidence || %{}
    result_object_refs = action.result_object_refs || %{}

    (Map.get(source_evidence, "dedupe_key") || Map.get(result_object_refs, "dedupe_key")) ==
      receipt.dedupe_key
  end

  defp maybe_filter_topic(items, nil), do: items

  defp maybe_filter_topic(items, topic) do
    needle = String.downcase(topic)

    Enum.filter(items, fn item ->
      [Map.get(item, :why_now), Map.get(item, :origin_id), Map.get(item, :dedupe_key)]
      |> Enum.reject(&is_nil/1)
      |> Enum.any?(&String.contains?(String.downcase(to_string(&1)), needle))
    end)
  end

  defp normalize_topic(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_topic(_value), do: nil

  defp activity_bucket(rows, item_fn) do
    %{count: length(rows), items: rows |> Enum.map(item_fn) |> Enum.take(@notable_limit)}
  end

  defp empty_activity_summary do
    %{
      period: %{label: "today", since: nil, until: nil},
      todos: %{created: empty_bucket(), closed: empty_bucket(), updated: empty_bucket()},
      memories: %{count: 0, by_kind: %{}, items: []},
      people: %{created: empty_bucket(), enriched: empty_bucket()},
      pings: empty_bucket(),
      holds: %{count: 0, by_reason: %{}, items: []}
    }
  end

  defp empty_bucket, do: %{count: 0, items: []}

  defp normalize_attrs(attrs) do
    %{
      user_id: read_string(attrs, :user_id),
      agent_id: read_string(attrs, :agent_id),
      surface: read_string(attrs, :surface, "system"),
      event_type: read_string(attrs, :event_type, "tool.executed"),
      status: read_string(attrs, :status, "completed"),
      source_evidence: read_map(attrs, :source_evidence),
      policy_decision: read_map(attrs, :policy_decision),
      model_summary: read_string(attrs, :model_summary),
      confirmation_state: read_string(attrs, :confirmation_state),
      result_object_refs: read_map(attrs, :result_object_refs),
      remediation_hint: read_string(attrs, :remediation_hint),
      metadata: read_map(attrs, :metadata)
    }
  end

  defp redact_attrs(attrs) do
    %{
      attrs
      | source_evidence: redacted_map(attrs.source_evidence),
        policy_decision: redacted_map(attrs.policy_decision),
        model_summary: redacted_string(attrs.model_summary),
        result_object_refs: redacted_map(attrs.result_object_refs),
        metadata: redacted_map(attrs.metadata)
    }
  end

  defp redacted_map(value) when is_map(value), do: value |> Redaction.redact() |> stringify_keys()
  defp redacted_map(_value), do: %{}

  defp redacted_string(nil), do: nil
  defp redacted_string(value) when is_binary(value), do: Redaction.redact_string(value)
  defp redacted_string(value), do: value |> to_string() |> Redaction.redact_string()

  defp read_string(attrs, key, default \\ nil),
    do: Normalization.read_string(attrs, key, default)

  defp read_map(attrs, key), do: Normalization.read_map(attrs, key)

  defp stringify_keys(value), do: Normalization.stringify_keys(value)

  defp normalize_limit(limit), do: Normalization.clamp_limit(limit, @default_limit, @max_limit)

  defp normalize_retention_days(days) when is_integer(days) and days > 0, do: days

  defp normalize_retention_days(days) when is_binary(days) do
    days
    |> Normalization.parse_integer()
    |> normalize_retention_days()
  end

  defp normalize_retention_days(_days), do: @default_retention_days
end
