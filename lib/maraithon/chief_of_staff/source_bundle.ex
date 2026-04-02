defmodule Maraithon.ChiefOfStaff.SourceBundle do
  @moduledoc """
  Normalized assistant-owned source bundle shared across one Chief of Staff cycle.
  """

  alias Maraithon.ChiefOfStaff.SourceScope

  def empty(context, source_scope \\ %{})

  def empty(context, source_scope) when is_map(context) do
    timestamp =
      context
      |> Map.get(:timestamp, DateTime.utc_now())
      |> truncate_datetime()

    %{
      "trigger" => normalize_trigger(Map.get(context, :trigger)),
      "fetched_at" => DateTime.to_iso8601(timestamp),
      "freshness" => %{},
      "gmail" => %{
        "messages" => [],
        "inbox_messages" => [],
        "sent_messages" => [],
        "messages_by_provider" => %{}
      },
      "calendar" => %{
        "events" => [],
        "events_by_provider" => %{}
      },
      "slack" => %{},
      "web_context" => nil,
      "source_scope" => SourceScope.normalize(source_scope)
    }
  end

  def empty(_context, source_scope), do: empty(%{}, source_scope)

  def put_gmail(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    messages = normalize_items(read_list(attrs, "messages"))
    inbox_messages = normalize_items(read_list(attrs, "inbox_messages"))
    sent_messages = normalize_items(read_list(attrs, "sent_messages"))
    messages_by_provider = normalize_grouped_items(read_map(attrs, "messages_by_provider"))

    freshness =
      build_freshness("gmail", attrs, %{
        "message_count" => length(messages),
        "provider_count" => map_size(messages_by_provider)
      })

    bundle
    |> Map.put("gmail", %{
      "messages" => messages,
      "inbox_messages" => inbox_messages,
      "sent_messages" => sent_messages,
      "messages_by_provider" => messages_by_provider
    })
    |> put_freshness("gmail", freshness)
  end

  def put_calendar(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    events = normalize_items(read_list(attrs, "events"))
    events_by_provider = normalize_grouped_items(read_map(attrs, "events_by_provider"))

    freshness =
      build_freshness("calendar", attrs, %{
        "event_count" => length(events),
        "provider_count" => map_size(events_by_provider)
      })

    bundle
    |> Map.put("calendar", %{
      "events" => events,
      "events_by_provider" => events_by_provider
    })
    |> put_freshness("calendar", freshness)
  end

  def mark_unavailable(bundle, source, reason, metadata \\ %{})
      when is_map(bundle) and is_binary(source) do
    put_freshness(bundle, source, %{
      "source" => source,
      "status" => "unavailable",
      "reason" => normalize_string(reason),
      "metadata" => stringify_keys(metadata)
    })
  end

  def gmail_messages(bundle), do: bundle |> read_map("gmail") |> read_list("messages")
  def gmail_inbox_messages(bundle), do: bundle |> read_map("gmail") |> read_list("inbox_messages")
  def gmail_sent_messages(bundle), do: bundle |> read_map("gmail") |> read_list("sent_messages")
  def calendar_events(bundle), do: bundle |> read_map("calendar") |> read_list("events")
  def freshness(bundle), do: read_map(bundle, "freshness")
  def source_scope(bundle), do: bundle |> read_map("source_scope") |> SourceScope.normalize()

  def fetched?(bundle, source) when is_map(bundle) and is_binary(source) do
    case get_in(bundle, ["freshness", source, "status"]) do
      "ready" -> true
      "partial" -> true
      _ -> false
    end
  end

  defp put_freshness(bundle, source, freshness) do
    Map.update(bundle, "freshness", %{source => freshness}, &Map.put(&1, source, freshness))
  end

  defp build_freshness(source, attrs, counts) do
    %{
      "source" => source,
      "status" => normalize_string(read_string(attrs, "status")) || "ready",
      "fetched_at" =>
        attrs
        |> read_datetime("fetched_at")
        |> truncate_datetime()
        |> DateTime.to_iso8601(),
      "providers" => read_list(attrs, "providers"),
      "counts" => counts
    }
    |> maybe_put("metadata", read_map(attrs, "metadata"))
  end

  defp normalize_trigger(nil), do: nil

  defp normalize_trigger(trigger) when is_map(trigger) do
    trigger
    |> stringify_keys()
    |> Enum.reject(fn {_key, value} -> is_map(value) or is_list(value) end)
    |> Map.new()
  end

  defp normalize_trigger(_trigger), do: nil

  defp normalize_grouped_items(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), normalize_items(value)}
    end)
  end

  defp normalize_grouped_items(_map), do: %{}

  defp normalize_items(items) when is_list(items) do
    Enum.map(items, &stringify_keys/1)
  end

  defp normalize_items(_items), do: []

  defp stringify_keys(%_{} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_map(value) -> {to_string(key), stringify_keys(value)}
      {key, value} when is_list(value) -> {to_string(key), Enum.map(value, &stringify_keys/1)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_keys(value), do: value

  defp read_map(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, to_existing_atom_if_loaded(key))) do
      value when is_map(value) -> stringify_keys(value)
      _ -> %{}
    end
  end

  defp read_map(_map, _key), do: %{}

  defp read_list(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, to_existing_atom_if_loaded(key))) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp read_list(_map, _key), do: []

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, to_existing_atom_if_loaded(key))) do
      value when is_binary(value) ->
        normalize_string(value)

      _ ->
        nil
    end
  end

  defp read_string(_map, _key), do: nil

  defp read_datetime(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, to_existing_atom_if_loaded(key))) do
      %DateTime{} = value -> value
      value when is_binary(value) -> parse_datetime(value)
      _ -> DateTime.utc_now()
    end
  end

  defp read_datetime(_map, _key), do: DateTime.utc_now()

  defp truncate_datetime(%DateTime{} = datetime), do: DateTime.truncate(datetime, :second)
  defp truncate_datetime(_value), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, %{}), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_existing_atom_if_loaded(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  defp to_existing_atom_if_loaded(key), do: key
end
