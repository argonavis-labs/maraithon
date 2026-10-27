defmodule Maraithon.Transcription.OpenAIWhisper do
  @moduledoc """
  Speech-to-text via OpenAI's audio transcription API.

  Mirrors `Maraithon.LLM.OpenAIProvider`'s client style (direct `Req` call,
  bearer auth header, structured `{:error, tuple}` results) rather than
  `Maraithon.HTTP` — the JSON-only helper there doesn't support the
  multipart upload this endpoint requires.

  Reuses the same `OPENAI_API_KEY` already configured for the OpenAI LLM
  provider (see `Maraithon.LLM.openai_api_key/0`) unless a dedicated
  `TRANSCRIPTION_API_KEY` is set — see `config/runtime.exs`.
  """

  @behaviour Maraithon.Transcription

  require Logger

  @default_base_url "https://api.openai.com/v1/audio/transcriptions"
  @default_model "whisper-1"
  @default_receive_timeout_ms 60_000
  @default_filename "voice.ogg"
  @default_content_type "audio/ogg"

  @impl true
  def transcribe(audio, opts) when is_binary(audio) and is_list(opts) do
    case api_key() do
      value when is_binary(value) and value != "" ->
        do_transcribe(audio, opts, value)

      _ ->
        {:error, :transcription_not_configured}
    end
  end

  @doc """
  True when an API key is configured for transcription.
  """
  @spec configured? :: boolean()
  def configured? do
    case api_key() do
      value when is_binary(value) -> value != ""
      _ -> false
    end
  end

  defp do_transcribe(audio, opts, api_key) do
    filename = Keyword.get(opts, :filename) || @default_filename
    content_type = Keyword.get(opts, :content_type) || @default_content_type

    parts = [
      model: model(),
      file: {audio, filename: filename, content_type: content_type}
    ]

    case Req.post(base_url(),
           form_multipart: parts,
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: receive_timeout_ms()
         ) do
      {:ok, %{status: 200, body: %{"text" => text}}} when is_binary(text) ->
        {:ok, String.trim(text)}

      {:ok, %{status: 200, body: body}} ->
        Logger.warning("Transcription response missing text", body: inspect(body))
        {:error, :invalid_response}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Transcription API error", status: status, body: inspect(body))
        {:error, {:api_error, status, body}}

      {:error, %{reason: :timeout}} ->
        Logger.warning("Transcription API timeout")
        {:error, :timeout}

      {:error, reason} ->
        Logger.warning("Transcription network error", reason: inspect(reason))
        {:error, {:network_error, reason}}
    end
  end

  defp api_key do
    case Keyword.get(config(), :api_key) do
      value when is_binary(value) and value != "" -> value
      _ -> Maraithon.LLM.openai_api_key()
    end
  end

  defp model do
    Keyword.get(config(), :model, @default_model)
  end

  defp base_url do
    Keyword.get(config(), :base_url, @default_base_url)
  end

  defp receive_timeout_ms do
    Keyword.get(config(), :receive_timeout_ms, @default_receive_timeout_ms)
  end

  defp config do
    Application.get_env(:maraithon, __MODULE__, [])
  end
end
