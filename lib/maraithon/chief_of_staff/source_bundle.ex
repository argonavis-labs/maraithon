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
      "calendar_local" => %{"events" => [], "counts" => %{}},
      "slack" => %{},
      "news" => %{"items" => [], "feeds" => []},
      "imessage" => %{"messages" => [], "chats" => [], "counts" => %{}},
      "notes" => %{"notes" => [], "counts" => %{}},
      "voice_memos" => %{"memos" => [], "counts" => %{}},
      "reminders" => %{"reminders" => [], "counts" => %{}},
      "files" => %{"files" => [], "counts" => %{}},
      "browser_history" => %{"visits" => [], "counts" => %{}},
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

  def put_slack(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    workspaces = normalize_items(read_list(attrs, "workspaces"))
    messages = workspaces |> Enum.flat_map(&read_workspace_messages/1)
    mentions = normalize_items(read_list(attrs, "mentions"))

    freshness =
      build_freshness("slack", attrs, %{
        "workspace_count" => length(workspaces),
        "message_count" => length(messages),
        "mention_count" => length(mentions)
      })

    bundle
    |> Map.put("slack", %{
      "workspaces" => workspaces,
      "messages" => messages,
      "mentions" => mentions
    })
    |> put_freshness("slack", freshness)
  end

  def put_news(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    items = normalize_items(read_list(attrs, "items"))
    feeds = normalize_items(read_list(attrs, "feeds"))

    freshness =
      build_freshness("news", attrs, %{
        "item_count" => length(items),
        "feed_count" => length(feeds)
      })

    bundle
    |> Map.put("news", %{
      "items" => items,
      "feeds" => feeds
    })
    |> put_freshness("news", freshness)
  end

  def put_weather(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    report =
      attrs
      |> Map.take([
        "source",
        "location",
        "latitude",
        "longitude",
        "units",
        "current",
        "today",
        "tomorrow"
      ])
      |> stringify_keys()

    freshness =
      build_freshness("weather", attrs, %{
        "location" => Map.get(report, "location")
      })

    bundle
    |> Map.put("weather", report)
    |> put_freshness("weather", freshness)
  end

  @doc """
  Stores a local-calendar (macOS Calendar.app via companion device) snapshot.

  This sits alongside `put_calendar/2` (Google). Callers can populate both;
  the brief pipeline prefers the local snapshot first because it aggregates
  iCloud / Exchange / Google / CalDAV in one place, and falls back to Google
  when no local events are present.
  """
  def put_calendar_local(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    events = normalize_items(read_list(attrs, "events"))
    counts = read_map(attrs, "counts")

    counts =
      if map_size(counts) == 0,
        do: %{"count" => length(events)},
        else: counts

    freshness = build_freshness("calendar_local", attrs, counts)

    bundle
    |> Map.put("calendar_local", %{"events" => events, "counts" => counts})
    |> put_freshness("calendar_local", freshness)
  end

  def put_imessage(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    messages = normalize_items(read_list(attrs, "messages"))
    chats = normalize_items(read_list(attrs, "chats"))
    counts = read_map(attrs, "counts")

    counts =
      if map_size(counts) == 0,
        do: %{"messages" => length(messages), "chats" => length(chats)},
        else: counts

    freshness = build_freshness("imessage", attrs, counts)

    bundle
    |> Map.put("imessage", %{"messages" => messages, "chats" => chats, "counts" => counts})
    |> put_freshness("imessage", freshness)
  end

  def put_notes(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    notes = normalize_items(read_list(attrs, "notes"))
    counts = read_map(attrs, "counts")

    counts =
      if map_size(counts) == 0,
        do: %{"count" => length(notes)},
        else: counts

    freshness = build_freshness("notes", attrs, counts)

    bundle
    |> Map.put("notes", %{"notes" => notes, "counts" => counts})
    |> put_freshness("notes", freshness)
  end

  def put_voice_memos(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    memos = normalize_items(read_list(attrs, "memos"))
    counts = read_map(attrs, "counts")

    counts =
      if map_size(counts) == 0,
        do: %{"count" => length(memos)},
        else: counts

    freshness = build_freshness("voice_memos", attrs, counts)

    bundle
    |> Map.put("voice_memos", %{"memos" => memos, "counts" => counts})
    |> put_freshness("voice_memos", freshness)
  end

  def put_reminders(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    reminders = normalize_items(read_list(attrs, "reminders"))
    counts = read_map(attrs, "counts")

    counts =
      if map_size(counts) == 0,
        do: %{"open" => length(reminders)},
        else: counts

    freshness = build_freshness("reminders", attrs, counts)

    bundle
    |> Map.put("reminders", %{"reminders" => reminders, "counts" => counts})
    |> put_freshness("reminders", freshness)
  end

  def put_files(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    files = normalize_items(read_list(attrs, "files"))
    counts = read_map(attrs, "counts")

    counts =
      if map_size(counts) == 0,
        do: %{"recent_count" => length(files)},
        else: counts

    freshness = build_freshness("files", attrs, counts)

    bundle
    |> Map.put("files", %{"files" => files, "counts" => counts})
    |> put_freshness("files", freshness)
  end

  def put_browser_history(bundle, attrs) when is_map(bundle) and is_map(attrs) do
    visits = normalize_items(read_list(attrs, "visits"))
    counts = read_map(attrs, "counts")

    counts =
      if map_size(counts) == 0,
        do: %{"count" => length(visits)},
        else: counts

    freshness = build_freshness("browser_history", attrs, counts)

    bundle
    |> Map.put("browser_history", %{"visits" => visits, "counts" => counts})
    |> put_freshness("browser_history", freshness)
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
  def slack_workspaces(bundle), do: bundle |> read_map("slack") |> read_list("workspaces")
  def slack_messages(bundle), do: bundle |> read_map("slack") |> read_list("messages")
  def slack_mentions(bundle), do: bundle |> read_map("slack") |> read_list("mentions")
  def news_items(bundle), do: bundle |> read_map("news") |> read_list("items")
  def news_feeds(bundle), do: bundle |> read_map("news") |> read_list("feeds")
  def weather(bundle), do: read_map(bundle, "weather")

  def calendar_local_events(bundle),
    do: bundle |> read_map("calendar_local") |> read_list("events")

  def imessage_messages(bundle), do: bundle |> read_map("imessage") |> read_list("messages")
  def imessage_chats(bundle), do: bundle |> read_map("imessage") |> read_list("chats")
  def notes(bundle), do: bundle |> read_map("notes") |> read_list("notes")
  def voice_memos(bundle), do: bundle |> read_map("voice_memos") |> read_list("memos")
  def reminders(bundle), do: bundle |> read_map("reminders") |> read_list("reminders")
  def files(bundle), do: bundle |> read_map("files") |> read_list("files")
  def browser_visits(bundle), do: bundle |> read_map("browser_history") |> read_list("visits")
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

  defp read_workspace_messages(workspace) when is_map(workspace) do
    workspace
    |> read_workspace_channels()
    |> Enum.flat_map(fn channel ->
      channel
      |> read_list("messages")
      |> Enum.map(fn message ->
        message
        |> stringify_keys()
        |> Map.put_new("team_id", Map.get(workspace, "team_id"))
        |> Map.put_new("team_name", Map.get(workspace, "team_name"))
        |> Map.put_new("channel_id", Map.get(channel, "id"))
        |> Map.put_new("channel_name", Map.get(channel, "name"))
      end)
    end)
  end

  defp read_workspace_messages(_workspace), do: []

  defp read_workspace_channels(workspace) when is_map(workspace) do
    case read_list(workspace, "channels") do
      [] -> read_list(workspace, "key_channels")
      channels -> channels
    end
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
