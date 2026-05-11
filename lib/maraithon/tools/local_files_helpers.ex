defmodule Maraithon.Tools.LocalFilesHelpers do
  @moduledoc """
  Shared serialization and argument helpers for the macOS Files tool
  surface (`files_search`, `files_get`, `files_list_recent`).

  Output shaping rules:

    * Summary (`files_search`, `files_list_recent`) — exposes file
      metadata, path, and a short `text_content_snippet` capped at
      200 chars. Avoids the multi-KB body that would blow LLM context
      with no upside in a hit list.
    * Full (`files_get`) — exposes `text_content`, but capped at
      `@full_text_max` bytes so even oversized PDFs don't shred the
      assistant's context window.
  """

  alias Maraithon.LocalFiles.LocalFile

  @snippet_max 200
  @full_text_max 30 * 1024

  @doc """
  Compact summary for list/search results.
  """
  def serialize_summary(%LocalFile{} = file) do
    %{
      file_id: file.guid,
      guid: file.guid,
      filename: file.filename,
      path: file.path,
      extension: file.extension,
      mime_type: file.mime_type,
      byte_size: file.byte_size,
      text_content_snippet: snippet(file.text_content),
      text_truncated: file.text_truncated || false,
      created_at: iso8601(file.created_at),
      modified_at: iso8601(file.modified_at)
    }
  end

  def serialize_summary(file) when is_map(file), do: file

  @doc """
  Full record returned by `files_get`. Includes the extracted
  `text_content` capped at `@full_text_max` bytes — protects the
  caller's LLM context from a giant PDF body. When the text gets
  truncated for size, `text_truncated_for_response` flags it so the
  caller can ask the user whether to surface more.
  """
  def serialize_full(%LocalFile{} = file) do
    {text, response_truncated} = cap_full_text(file.text_content)

    %{
      file_id: file.guid,
      guid: file.guid,
      filename: file.filename,
      path: file.path,
      extension: file.extension,
      mime_type: file.mime_type,
      byte_size: file.byte_size,
      source: file.source,
      text_content: text,
      text_truncated: file.text_truncated || false,
      text_truncated_for_response: response_truncated,
      created_at: iso8601(file.created_at),
      modified_at: iso8601(file.modified_at)
    }
  end

  def serialize_full(file) when is_map(file), do: file

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

  @doc """
  Pull an optional string argument, returning `nil` for missing or
  empty values rather than `""`.
  """
  def optional_string(args, key) when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp parse_limit(value, default, max_limit) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed, max_limit)
      _ -> default
    end
  end

  defp snippet(nil), do: nil

  defp snippet(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= @snippet_max -> trimmed
      true -> String.slice(trimmed, 0, @snippet_max) <> "…"
    end
  end

  defp cap_full_text(nil), do: {nil, false}

  defp cap_full_text(text) when is_binary(text) do
    if byte_size(text) > @full_text_max do
      {binary_part(text, 0, @full_text_max), true}
    else
      {text, false}
    end
  end

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
