defmodule Maraithon.Tools.LocalCalendarHelpers do
  @moduledoc """
  Shared serialization and argument helpers for the macOS Calendar tool
  surface (`calendar_events_around`, `calendar_events_for_person`,
  `calendar_search`, `calendar_event_get`).

  These tools read from `Maraithon.LocalCalendar`, the durable mirror of
  the user's local Calendar.app store. That store already aggregates
  every calendar account the user has added (iCloud, Exchange, Google
  via CalDAV, etc.), so the tool surface is the user's full picture.
  """

  alias Maraithon.LocalCalendar.LocalEvent

  @notes_snippet_max 280

  @doc """
  Compact summary for list/search/around results.
  """
  def serialize_summary(%LocalEvent{} = event) do
    %{
      event_id: event.guid,
      guid: event.guid,
      calendar_name: event.calendar_name,
      title: event.title,
      location: event.location,
      start_at: iso8601(event.start_at),
      end_at: iso8601(event.end_at),
      is_all_day: event.is_all_day || false,
      is_recurring: event.is_recurring || false,
      attendees_count: event.attendees_count || 0,
      organizer_email: event.organizer_email
    }
  end

  def serialize_summary(event) when is_map(event) do
    %{
      event_id: Map.get(event, :guid) || Map.get(event, "guid"),
      guid: Map.get(event, :guid) || Map.get(event, "guid"),
      calendar_name: Map.get(event, :calendar_name) || Map.get(event, "calendar_name"),
      title: Map.get(event, :title) || Map.get(event, "title"),
      location: Map.get(event, :location) || Map.get(event, "location"),
      start_at: iso8601(Map.get(event, :start_at) || Map.get(event, "start_at")),
      end_at: iso8601(Map.get(event, :end_at) || Map.get(event, "end_at")),
      is_all_day: Map.get(event, :is_all_day) || Map.get(event, "is_all_day") || false,
      is_recurring: Map.get(event, :is_recurring) || Map.get(event, "is_recurring") || false,
      attendees_count: Map.get(event, :attendees_count) || Map.get(event, "attendees_count") || 0,
      organizer_email: Map.get(event, :organizer_email) || Map.get(event, "organizer_email")
    }
  end

  @doc """
  Full record for `calendar_event_get`. Includes the notes body
  (clamped to `@notes_snippet_max` chars so we never blow context with
  a giant agenda body) and the attendee list.
  """
  def serialize_full(%LocalEvent{} = event) do
    %{
      event_id: event.guid,
      guid: event.guid,
      source: event.source,
      calendar_name: event.calendar_name,
      calendar_color: event.calendar_color,
      title: event.title,
      notes: notes_snippet(event.notes),
      location: event.location,
      start_at: iso8601(event.start_at),
      end_at: iso8601(event.end_at),
      is_all_day: event.is_all_day || false,
      is_recurring: event.is_recurring || false,
      organizer_email: event.organizer_email,
      attendees_count: event.attendees_count || 0,
      attendee_emails: event.attendee_emails || [],
      created_at: iso8601(event.created_at),
      modified_at: iso8601(event.modified_at)
    }
  end

  def serialize_full(event) when is_map(event), do: event

  @doc """
  Clamp an integer `limit` argument to `[1, max_limit]`, defaulting to
  `default` when missing or unparseable.
  """
  def normalize_limit(args, default, max_limit)
      when is_map(args) and is_integer(default) and is_integer(max_limit) do
    case Map.get(args, "limit") do
      value when is_integer(value) and value > 0 -> min(value, max_limit)
      value when is_binary(value) -> parse_limit(value, default, max_limit)
      _ -> default
    end
  end

  @doc """
  Parse an optional ISO-8601 datetime string. Returns `{:ok, datetime}`
  on success, `{:ok, nil}` when the arg is absent, and `{:error, ...}`
  for an unparseable string.
  """
  def parse_optional_datetime(args, key)
      when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :microsecond)}
          _ -> {:error, "#{key} must be ISO-8601"}
        end

      _ ->
        {:error, "#{key} must be ISO-8601"}
    end
  end

  defp parse_limit(value, default, max_limit) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed, max_limit)
      _ -> default
    end
  end

  defp notes_snippet(nil), do: nil

  defp notes_snippet(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= @notes_snippet_max -> trimmed
      true -> String.slice(trimmed, 0, @notes_snippet_max) <> "…"
    end
  end

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
