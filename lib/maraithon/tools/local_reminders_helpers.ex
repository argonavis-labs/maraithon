defmodule Maraithon.Tools.LocalRemindersHelpers do
  @moduledoc """
  Shared serialization and argument helpers for the macOS Reminders
  tool surface (`reminders_open`, `reminders_due_soon`,
  `reminders_search`, `reminders_get`).
  """

  alias Maraithon.LocalReminders.LocalReminder

  @doc """
  Compact summary for list/search results. Carries enough fields for
  the assistant to surface a row without a follow-up `reminders_get`
  in the common case.
  """
  def serialize_summary(%LocalReminder{} = reminder) do
    %{
      reminder_id: reminder.guid,
      guid: reminder.guid,
      title: reminder.title,
      notes_snippet: notes_snippet(reminder.notes),
      list_name: reminder.list_name,
      list_color: reminder.list_color,
      priority: reminder.priority,
      priority_label: priority_label(reminder.priority),
      due_at: iso8601(reminder.due_at),
      completed_at: iso8601(reminder.completed_at),
      is_completed: reminder.is_completed,
      has_alarm: reminder.has_alarm,
      url_attachment: reminder.url_attachment,
      modified_at: iso8601(reminder.modified_at)
    }
  end

  def serialize_summary(reminder) when is_map(reminder), do: reminder

  @doc """
  Full record returned by `reminders_get`. Adds the full decoded
  `notes` body, `created_at`, and the source marker so callers can
  render a full row without another query.
  """
  def serialize_full(%LocalReminder{} = reminder) do
    %{
      reminder_id: reminder.guid,
      guid: reminder.guid,
      title: reminder.title,
      notes: reminder.notes,
      list_name: reminder.list_name,
      list_color: reminder.list_color,
      priority: reminder.priority,
      priority_label: priority_label(reminder.priority),
      due_at: iso8601(reminder.due_at),
      completed_at: iso8601(reminder.completed_at),
      is_completed: reminder.is_completed,
      has_alarm: reminder.has_alarm,
      url_attachment: reminder.url_attachment,
      source: reminder.source,
      created_at: iso8601(reminder.created_at),
      modified_at: iso8601(reminder.modified_at)
    }
  end

  def serialize_full(reminder) when is_map(reminder), do: reminder

  @doc """
  Clamp an integer `limit` argument to `[1, max_limit]`, defaulting to
  `default` when the argument is missing or unparseable.
  """
  def normalize_limit(args, default, max_limit)
      when is_map(args) and is_integer(default) and is_integer(max_limit) do
    case Map.get(args, "limit") do
      value when is_integer(value) and value > 0 -> min(value, max_limit)
      value when is_binary(value) -> parse_int(value, default, max_limit)
      _ -> default
    end
  end

  @doc """
  Clamp an integer `days_ahead` argument to `[1, max_days]`, defaulting
  to `default` when missing or unparseable.
  """
  def normalize_days_ahead(args, default, max_days)
      when is_map(args) and is_integer(default) and is_integer(max_days) do
    case Map.get(args, "days_ahead") do
      value when is_integer(value) and value > 0 -> min(value, max_days)
      value when is_binary(value) -> parse_int(value, default, max_days)
      _ -> default
    end
  end

  @doc """
  Maps the EventKit numeric priority to a human-readable bucket.
  Mirrors Apple's UI labels: `0` is the default "none", `1-4` is
  "high", `5` is "medium", `6-9` is "low".
  """
  def priority_label(0), do: "none"
  def priority_label(priority) when is_integer(priority) and priority in 1..4, do: "high"
  def priority_label(5), do: "medium"
  def priority_label(priority) when is_integer(priority) and priority in 6..9, do: "low"
  def priority_label(_), do: "none"

  defp parse_int(value, default, max_value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed, max_value)
      _ -> default
    end
  end

  defp notes_snippet(nil), do: nil

  defp notes_snippet(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) > 200 -> String.slice(trimmed, 0, 200) <> "..."
      true -> trimmed
    end
  end

  defp notes_snippet(_), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
