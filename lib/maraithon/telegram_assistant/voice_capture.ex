defmodule Maraithon.TelegramAssistant.VoiceCapture do
  @moduledoc """
  Downloads and transcribes an inbound Telegram voice/audio message before it
  reaches `TelegramRouter` (SPEC 02).

  `Maraithon.Connectors.Telegram.classify_message/1` already extracts
  `voice_id`/`audio_id` for voice notes and audio files, but nothing
  downstream ever read them — `TelegramRouter.handle_message/1` only looks
  at `text`, so these messages silently died. This module runs inside
  `Maraithon.TelegramAssistant.ChatWorker` (after the webhook has already
  acked) and, when it finds a voice/audio message with no `text`:

    1. Enforces a size/duration cap (`R6`) before spending any bandwidth.
    2. Downloads the file via the Telegram Bot API (`getFile` + the file
       CDN URL).
    3. Transcribes it via `Maraithon.Transcription`.
    4. Returns the inbound data with `text` set to the transcript and
       `input_mode: "voice"` so the turn can be tagged, feeding the
       existing, unchanged text pipeline (`R3`/`R4`).

  Ordinary text messages pass through untouched. Any failure — cap exceeded,
  download failure, or transcription failure — comes back as `{:error,
  reason}` so the caller can send a user-visible fallback reply (`R5`)
  instead of dropping the message silently.
  """

  alias Maraithon.Connectors.Telegram
  alias Maraithon.Transcription

  require Logger

  # R6: skip transcription for files over a sane cap, and tell the user why.
  @max_file_size_bytes 20 * 1_000_000
  @max_duration_seconds 10 * 60

  @doc """
  Given inbound Telegram message data (as passed to
  `TelegramRouter.handle_message/1`), returns:

    * `{:ok, data}` unchanged, for anything that isn't a textless
      voice/audio message.
    * `{:ok, data}` with `text` populated by the transcript and
      `input_mode: "voice"` set, when a voice/audio message was
      successfully transcribed.
    * `{:error, reason}` when a voice/audio message could not be processed.
      `reason` is one of `{:voice_too_large, max_mb}`,
      `{:voice_too_long, max_minutes}`, or `:voice_transcription_failed`.
  """
  @spec maybe_transcribe(map()) :: {:ok, map()} | {:error, term()}
  def maybe_transcribe(data) when is_map(data) do
    case voice_file(data) do
      nil -> {:ok, data}
      file -> transcribe_file(data, file)
    end
  end

  defp voice_file(data) do
    text = fetch(data, :text)

    cond do
      is_binary(text) and String.trim(text) != "" ->
        nil

      is_binary(fetch(data, :voice_id)) ->
        %{
          file_id: fetch(data, :voice_id),
          duration: fetch(data, :duration),
          mime_type: fetch(data, :mime_type) || "audio/ogg"
        }

      is_binary(fetch(data, :audio_id)) ->
        %{
          file_id: fetch(data, :audio_id),
          duration: fetch(data, :duration),
          mime_type: fetch(data, :mime_type) || "audio/mpeg"
        }

      true ->
        nil
    end
  end

  defp transcribe_file(data, %{file_id: file_id, duration: duration, mime_type: mime_type}) do
    if over_duration_cap?(duration) do
      {:error, {:voice_too_long, max_duration_minutes()}}
    else
      with {:ok, file_info} <- Telegram.get_file(file_id),
           :ok <- check_size(file_info),
           file_path when is_binary(file_path) <- read_file_path(file_info),
           {:ok, audio} <- Telegram.download_file(file_path),
           :ok <- check_size(%{"file_size" => byte_size(audio)}),
           {:ok, transcript} <-
             Transcription.transcribe(audio,
               filename: filename_for(file_path),
               content_type: mime_type
             ) do
        {:ok, apply_transcript(data, transcript)}
      else
        {:error, {:voice_too_large, _} = reason} ->
          {:error, reason}

        nil ->
          transcription_failed(file_id, :missing_file_path)

        {:error, reason} ->
          transcription_failed(file_id, reason)
      end
    end
  end

  defp transcription_failed(file_id, reason) do
    Logger.warning("[telegram_fallback] voice transcription failed",
      file_id: file_id,
      reason: inspect(reason)
    )

    {:error, :voice_transcription_failed}
  end

  defp check_size(file_info) do
    case read_file_size(file_info) do
      size when is_integer(size) and size > @max_file_size_bytes ->
        {:error, {:voice_too_large, max_file_size_mb()}}

      _ ->
        :ok
    end
  end

  defp over_duration_cap?(duration) when is_integer(duration),
    do: duration > @max_duration_seconds

  defp over_duration_cap?(_duration), do: false

  defp max_file_size_mb, do: div(@max_file_size_bytes, 1_000_000)
  defp max_duration_minutes, do: div(@max_duration_seconds, 60)

  defp apply_transcript(data, transcript) do
    data
    |> Map.put(:text, transcript)
    |> Map.put(:input_mode, "voice")
  end

  defp filename_for(file_path) when is_binary(file_path), do: Path.basename(file_path)
  defp filename_for(_file_path), do: "voice.ogg"

  defp read_file_path(%{"file_path" => path}) when is_binary(path), do: path
  defp read_file_path(_file_info), do: nil

  defp read_file_size(%{"file_size" => size}) when is_integer(size), do: size
  defp read_file_size(_file_info), do: nil

  defp fetch(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
