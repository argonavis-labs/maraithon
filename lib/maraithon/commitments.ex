defmodule Maraithon.Commitments do
  @moduledoc """
  Source-of-truth context for user obligations the Chief of Staff should track.
  """

  import Ecto.Query

  alias Maraithon.Commitments.Commitment
  alias Maraithon.Insights
  alias Maraithon.Repo
  alias Maraithon.Todos

  @open_statuses ~w(open snoozed)

  def get_for_user(user_id, id) when is_binary(user_id) and is_binary(id) do
    Repo.get_by(Commitment, id: id, user_id: user_id)
  end

  def get_for_user(_user_id, _id), do: nil

  def list_open_for_user(user_id, opts \\ [])

  def list_open_for_user(user_id, opts) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 50)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Commitment
    |> where([c], c.user_id == ^user_id)
    |> where([c], c.status in ^@open_statuses)
    |> where([c], c.status != "snoozed" or is_nil(c.snoozed_until) or c.snoozed_until <= ^now)
    |> order_by([c], desc: c.priority, asc_nulls_last: c.due_at, desc: c.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_open_for_user(_user_id, _opts), do: []

  def upsert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("user_id", user_id)
      |> normalize_attrs()

    case attrs["source_id"] do
      source_id when is_binary(source_id) and source_id != "" ->
        upsert_by_source(user_id, attrs["source"], source_id, attrs)

      _ ->
        %Commitment{}
        |> Commitment.changeset(attrs)
        |> Repo.insert()
    end
  end

  def upsert(_user_id, _attrs), do: {:error, :invalid_commitment_attrs}

  def upsert_many(user_id, attrs_list) when is_binary(user_id) and is_list(attrs_list) do
    attrs_list
    |> Enum.reduce({:ok, []}, fn attrs, {:ok, acc} ->
      case upsert(user_id, attrs) do
        {:ok, commitment} -> {:ok, [commitment | acc]}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> case do
      {:ok, commitments} -> {:ok, Enum.reverse(commitments)}
      {:error, reason} -> {:error, reason}
    end
  end

  def upsert_many(_user_id, _attrs_list), do: {:error, :invalid_commitment_attrs}

  def mark_done(user_id, id, opts \\ [])

  def mark_done(user_id, id, opts) when is_binary(user_id) and is_binary(id) do
    update_status(user_id, id, "done", opts)
  end

  def mark_done(_user_id, _id, _opts), do: {:error, :not_found}

  def dismiss(user_id, id, opts \\ [])

  def dismiss(user_id, id, opts) when is_binary(user_id) and is_binary(id) do
    update_status(user_id, id, "dismissed", opts)
  end

  def dismiss(_user_id, _id, _opts), do: {:error, :not_found}

  def bucket_for_brief(user_id, opts \\ [])

  def bucket_for_brief(user_id, opts) when is_binary(user_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    offset_hours = Keyword.get(opts, :timezone_offset_hours, -5)
    timezone_label = Keyword.get(opts, :timezone_label, timezone_offset_label(offset_hours))
    commitments = list_open_for_user(user_id, limit: Keyword.get(opts, :limit, 50), now: now)
    fallback? = commitments == []

    raw_items =
      if fallback? do
        derived_open_commitments(user_id, now)
      else
        Enum.map(commitments, &commitment_to_map/1)
      end

    items = Enum.map(raw_items, &put_display_due(&1, offset_hours, timezone_label))

    %{
      "source" => if(fallback?, do: "derived_open_work", else: "commitments"),
      "active_count" => length(items),
      "overdue" => Enum.filter(items, &bucket_overdue?(&1, now, offset_hours)),
      "due_today" => Enum.filter(items, &bucket_due_today?(&1, now, offset_hours)),
      "coming_up" => Enum.filter(items, &bucket_coming_up?(&1, now, offset_hours)),
      "no_deadline" => Enum.filter(items, &is_nil(&1["due_at"]))
    }
  end

  def bucket_for_brief(_user_id, _opts) do
    %{
      "source" => "commitments",
      "active_count" => 0,
      "overdue" => [],
      "due_today" => [],
      "coming_up" => [],
      "no_deadline" => []
    }
  end

  defp upsert_by_source(user_id, source, source_id, attrs) do
    case Repo.get_by(Commitment, user_id: user_id, source: source, source_id: source_id) do
      nil ->
        %Commitment{}
        |> Commitment.changeset(attrs)
        |> Repo.insert()

      %Commitment{} = commitment ->
        commitment
        |> Commitment.changeset(Map.drop(attrs, ["user_id", "source", "source_id"]))
        |> Repo.update()
    end
  end

  defp update_status(user_id, id, status, opts) do
    note = Keyword.get(opts, :note)

    case get_for_user(user_id, id) do
      nil ->
        {:error, :not_found}

      %Commitment{} = commitment ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        metadata =
          (commitment.metadata || %{})
          |> maybe_put_resolution_note(note, status, now)

        commitment
        |> Commitment.changeset(%{
          status: status,
          closed_at: now,
          snoozed_until: nil,
          metadata: metadata
        })
        |> Repo.update()
    end
  end

  defp normalize_attrs(attrs) do
    %{
      "source" => read_string(attrs, "source", "maraithon"),
      "source_id" => read_string(attrs, "source_id", nil),
      "title" => read_string(attrs, "title", read_string(attrs, "name", "Open commitment")),
      "owed_to" => read_string(attrs, "owed_to", read_string(attrs, "person", nil)),
      "project" => read_string(attrs, "project", nil),
      "due_at" => read_datetime(attrs, "due_at", read_datetime(attrs, "due", nil)),
      "status" => read_string(attrs, "status", "open"),
      "priority" => clamp_integer(read_integer(attrs, "priority", 50), 0, 100),
      "evidence" => read_string_list(attrs, "evidence"),
      "metadata" => read_map(attrs, "metadata")
    }
    |> Map.put("user_id", attrs["user_id"])
  end

  defp derived_open_commitments(user_id, now) do
    todos =
      user_id
      |> Todos.list_open_for_user(limit: 20)
      |> Enum.map(fn todo ->
        %{
          "id" => "todo:#{todo.id}",
          "source" => "todo",
          "source_id" => todo.id,
          "title" => todo.title,
          "owed_to" => read_string(todo.metadata || %{}, "person", nil),
          "project" => read_string(todo.metadata || %{}, "project", nil),
          "due_at" => datetime_to_iso(todo.source_occurred_at),
          "status" => todo.status,
          "priority" => todo.priority,
          "evidence" => read_string_list(todo.metadata || %{}, "evidence"),
          "metadata" => Map.take(todo.metadata || %{}, ["source_insight_id", "record"])
        }
      end)

    insights =
      user_id
      |> Insights.list_open_act_now_for_user(limit: 20)
      |> Enum.map(fn insight ->
        record = read_map(insight.metadata || %{}, "record")

        %{
          "id" => "insight:#{insight.id}",
          "source" => "insight",
          "source_id" => insight.id,
          "title" => read_string(record, "commitment", insight.title),
          "owed_to" => read_string(record, "person", nil),
          "project" => read_string(insight.metadata || %{}, "project", nil),
          "due_at" => datetime_to_iso(insight.due_at),
          "status" => insight.status,
          "priority" => insight.priority,
          "evidence" => read_string_list(record, "evidence"),
          "metadata" => %{"insight_category" => insight.category, "source" => insight.source}
        }
      end)

    (todos ++ insights)
    |> Enum.uniq_by(&{&1["source"], &1["source_id"]})
    |> Enum.sort_by(&Map.get(&1, "priority", 0), :desc)
    |> Enum.take(30)
    |> Enum.map(&Map.put_new(&1, "snapshot_at", datetime_to_iso(now)))
  end

  defp commitment_to_map(%Commitment{} = commitment) do
    %{
      "id" => commitment.id,
      "source" => commitment.source,
      "source_id" => commitment.source_id,
      "title" => commitment.title,
      "owed_to" => commitment.owed_to,
      "project" => commitment.project,
      "due_at" => datetime_to_iso(commitment.due_at),
      "status" => commitment.status,
      "priority" => commitment.priority,
      "evidence" => commitment.evidence || [],
      "metadata" => commitment.metadata || {}
    }
  end

  defp put_display_due(item, offset_hours, timezone_label) when is_map(item) do
    if read_string(item, "display_due", nil) do
      item
    else
      case display_due_label(item["due_at"], offset_hours, timezone_label) do
        nil -> item
        label -> Map.put(item, "display_due", label)
      end
    end
  end

  defp put_display_due(item, _offset_hours, _timezone_label), do: item

  defp bucket_overdue?(%{"due_at" => nil}, _now, _offset_hours), do: false

  defp bucket_overdue?(item, now, offset_hours) do
    case parse_datetime(item["due_at"]) do
      nil ->
        false

      due_at ->
        Date.compare(local_date(due_at, offset_hours), local_date(now, offset_hours)) == :lt
    end
  end

  defp bucket_due_today?(%{"due_at" => nil}, _now, _offset_hours), do: false

  defp bucket_due_today?(item, now, offset_hours) do
    case parse_datetime(item["due_at"]) do
      nil ->
        false

      due_at ->
        Date.compare(local_date(due_at, offset_hours), local_date(now, offset_hours)) == :eq
    end
  end

  defp bucket_coming_up?(%{"due_at" => nil}, _now, _offset_hours), do: false

  defp bucket_coming_up?(item, now, offset_hours) do
    case parse_datetime(item["due_at"]) do
      nil ->
        false

      due_at ->
        today = local_date(now, offset_hours)
        due_date = local_date(due_at, offset_hours)
        days = Date.diff(due_date, today)
        days > 0 and days <= 7
    end
  end

  defp local_date(%DateTime{} = datetime, offset_hours) do
    datetime
    |> DateTime.add(offset_hours, :hour)
    |> DateTime.to_date()
  end

  defp display_due_label(nil, _offset_hours, _timezone_label), do: nil

  defp display_due_label(value, offset_hours, timezone_label) do
    case parse_datetime(value) do
      nil ->
        nil

      due_at ->
        due_at
        |> DateTime.add(offset_hours, :hour)
        |> Calendar.strftime("%b %-d, %Y at %-I:%M %p #{timezone_label}")
    end
  end

  defp timezone_offset_label(offset) when is_integer(offset) do
    sign = if offset < 0, do: "-", else: "+"
    hours = offset |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
    "UTC#{sign}#{hours}:00"
  end

  defp timezone_offset_label(_offset), do: "UTC"

  defp maybe_put_resolution_note(metadata, nil, _status, _now), do: metadata

  defp maybe_put_resolution_note(metadata, note, status, now) do
    Map.put(metadata, "resolution", %{
      "status" => status,
      "note" => note,
      "at" => DateTime.to_iso8601(now)
    })
  end

  defp stringify_keys(%_{} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_map(value) -> {to_string(key), stringify_keys(value)}
      {key, value} when is_list(value) -> {to_string(key), Enum.map(value, &stringify_keys/1)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_keys(value), do: value

  defp read_string(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end

  defp read_string(_map, _key, default), do: default

  defp read_integer(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _} -> parsed
          :error -> default
        end

      _ ->
        default
    end
  end

  defp read_map(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_map(value) -> stringify_keys(value)
      _ -> %{}
    end
  end

  defp read_map(_map, _key), do: %{}

  defp read_string_list(map, key) when is_map(map) do
    case Map.get(map, key) do
      values when is_list(values) ->
        values
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      value when is_binary(value) ->
        [value]

      _ ->
        []
    end
  end

  defp read_datetime(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      %DateTime{} = value -> value
      %NaiveDateTime{} = value -> DateTime.from_naive!(value, "Etc/UTC")
      value when is_binary(value) -> parse_datetime(value) || default
      _ -> default
    end
  end

  defp read_datetime(_map, _key, default), do: default

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp datetime_to_iso(nil), do: nil
  defp datetime_to_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_to_iso(value), do: to_string(value)

  defp clamp_integer(value, min, _max) when value < min, do: min
  defp clamp_integer(value, _min, max) when value > max, do: max
  defp clamp_integer(value, _min, _max), do: value
end
