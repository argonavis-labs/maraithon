defmodule Maraithon.Tools.LocalVoiceMemosHelpers do
  @moduledoc """
  Shared serialization and argument helpers for the macOS Voice Memos
  tool surface (`voice_memos_search`, `voice_memos_get`,
  `voice_memos_list_recent`).
  """

  alias Maraithon.LocalVoiceMemos.LocalVoiceMemo

  @doc """
  Compact summary for list/search results.
  """
  def serialize_summary(%LocalVoiceMemo{} = memo) do
    %{
      memo_id: memo.guid,
      guid: memo.guid,
      title: memo.title,
      duration_seconds: memo.duration_seconds,
      file_size_bytes: memo.file_size_bytes,
      created_at: iso8601(memo.created_at)
    }
  end

  def serialize_summary(memo) when is_map(memo) do
    %{
      memo_id: Map.get(memo, :guid) || Map.get(memo, "guid"),
      guid: Map.get(memo, :guid) || Map.get(memo, "guid"),
      title: Map.get(memo, :title) || Map.get(memo, "title"),
      duration_seconds:
        Map.get(memo, :duration_seconds) || Map.get(memo, "duration_seconds"),
      file_size_bytes:
        Map.get(memo, :file_size_bytes) || Map.get(memo, "file_size_bytes"),
      created_at: iso8601(Map.get(memo, :created_at) || Map.get(memo, "created_at"))
    }
  end

  @doc """
  Full record returned by `voice_memos_get`.
  """
  def serialize_full(%LocalVoiceMemo{} = memo) do
    %{
      memo_id: memo.guid,
      guid: memo.guid,
      title: memo.title,
      snippet: memo.snippet,
      duration_seconds: memo.duration_seconds,
      file_size_bytes: memo.file_size_bytes,
      source: memo.source,
      created_at: iso8601(memo.created_at)
    }
  end

  def serialize_full(memo) when is_map(memo), do: memo

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

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
