defmodule Maraithon.Tools.LocalNotesHelpers do
  @moduledoc """
  Shared serialization and argument helpers for the macOS Notes tool
  surface (`notes_search`, `notes_get`, `notes_list_recent`).
  """

  alias Maraithon.LocalNotes.LocalNote

  @doc """
  Compact summary for list/search results. Includes `body_snippet` —
  the first 200 chars of the decoded note body — so search callers can
  preview hits without a second `notes_get` round-trip.
  """
  def serialize_summary(%LocalNote{} = note) do
    %{
      note_id: note.guid,
      guid: note.guid,
      title: note.title,
      snippet: truncate_snippet(note.snippet),
      body_snippet: body_snippet(note.body),
      folder: note.folder,
      modified_at: iso8601(note.modified_at)
    }
  end

  def serialize_summary(note) when is_map(note) do
    %{
      note_id: Map.get(note, :guid) || Map.get(note, "guid"),
      guid: Map.get(note, :guid) || Map.get(note, "guid"),
      title: Map.get(note, :title) || Map.get(note, "title"),
      snippet:
        truncate_snippet(Map.get(note, :snippet) || Map.get(note, "snippet")),
      body_snippet:
        body_snippet(Map.get(note, :body) || Map.get(note, "body")),
      folder: Map.get(note, :folder) || Map.get(note, "folder"),
      modified_at:
        iso8601(Map.get(note, :modified_at) || Map.get(note, "modified_at"))
    }
  end

  @doc """
  Full record returned by `notes_get`. Includes the full decoded
  `body` and the `body_format` marker so callers can render the note
  end-to-end without another query.
  """
  def serialize_full(%LocalNote{} = note) do
    %{
      note_id: note.guid,
      guid: note.guid,
      title: note.title,
      snippet: note.snippet,
      body: note.body,
      body_format: note.body_format,
      folder: note.folder,
      is_pinned: note.is_pinned,
      source: note.source,
      created_at: iso8601(note.created_at),
      modified_at: iso8601(note.modified_at)
    }
  end

  def serialize_full(note) when is_map(note), do: note

  @doc """
  Clamp an integer `limit` argument to `[1, max_limit]`, defaulting to
  `default` when the argument is missing or unparseable.
  """
  def normalize_limit(args, default, max_limit)
      when is_map(args) and is_integer(default) and is_integer(max_limit) do
    case Map.get(args, "limit") do
      value when is_integer(value) and value > 0 -> min(value, max_limit)
      value when is_binary(value) -> parse_limit(value, default, max_limit)
      _ -> default
    end
  end

  defp parse_limit(value, default, max_limit) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed, max_limit)
      _ -> default
    end
  end

  defp truncate_snippet(nil), do: nil

  defp truncate_snippet(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.length(trimmed) > 280 do
      String.slice(trimmed, 0, 280) <> "..."
    else
      trimmed
    end
  end

  defp truncate_snippet(_value), do: nil

  # First 200 chars of the decoded body, trimmed of leading/trailing
  # whitespace. Returns `nil` when the body is missing or empty so the
  # JSON payload omits the key entirely on body-less notes.
  defp body_snippet(nil), do: nil

  defp body_snippet(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) > 200 -> String.slice(trimmed, 0, 200) <> "..."
      true -> trimmed
    end
  end

  defp body_snippet(_value), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
