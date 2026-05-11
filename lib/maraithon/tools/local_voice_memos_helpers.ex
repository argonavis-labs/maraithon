defmodule Maraithon.Tools.LocalVoiceMemosHelpers do
  @moduledoc """
  Shared serialization and argument helpers for the macOS Voice Memos
  tool surface (`voice_memos_search`, `voice_memos_get`,
  `voice_memos_list_recent`).

  v1.5 note: tool output exposes transcript text + audio metadata
  (`has_audio`, `audio_bytes_size`, `audio_truncated`, `audio_mime`) but
  never the raw audio bytes — they'd blow the LLM context with no
  upside. Callers that need the audio go through a dedicated download
  endpoint instead.
  """

  alias Maraithon.LocalVoiceMemos.LocalVoiceMemo

  @snippet_max 280

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
      created_at: iso8601(memo.created_at),
      transcript_snippet: transcript_snippet(memo.transcript),
      has_audio: not is_nil(memo.audio_bytes),
      audio_truncated: memo.audio_truncated || false
    }
  end

  def serialize_summary(memo) when is_map(memo) do
    %{
      memo_id: Map.get(memo, :guid) || Map.get(memo, "guid"),
      guid: Map.get(memo, :guid) || Map.get(memo, "guid"),
      title: Map.get(memo, :title) || Map.get(memo, "title"),
      duration_seconds: Map.get(memo, :duration_seconds) || Map.get(memo, "duration_seconds"),
      file_size_bytes: Map.get(memo, :file_size_bytes) || Map.get(memo, "file_size_bytes"),
      created_at: iso8601(Map.get(memo, :created_at) || Map.get(memo, "created_at"))
    }
  end

  @doc """
  Full record returned by `voice_memos_get`. Includes the transcript
  text and audio metadata, but NEVER the raw audio bytes — tool output
  feeds back into the assistant's context window and a 5 MB inline blob
  would shred it.
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
      created_at: iso8601(memo.created_at),
      transcript: memo.transcript,
      transcript_engine: memo.transcript_engine,
      transcript_lang: memo.transcript_lang,
      has_audio: not is_nil(memo.audio_bytes),
      audio_bytes_size: audio_byte_size(memo.audio_bytes),
      audio_truncated: memo.audio_truncated || false,
      audio_mime: memo.audio_mime
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

  defp transcript_snippet(nil), do: nil

  defp transcript_snippet(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= @snippet_max -> trimmed
      true -> String.slice(trimmed, 0, @snippet_max) <> "…"
    end
  end

  defp audio_byte_size(nil), do: 0
  defp audio_byte_size(bytes) when is_binary(bytes), do: byte_size(bytes)
  defp audio_byte_size(_), do: 0

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
