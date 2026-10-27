defmodule Maraithon.Transcription do
  @moduledoc """
  Behaviour + facade for speech-to-text transcription of short audio clips
  (Telegram voice/audio message capture — SPEC 02).

  Kept swappable the same way `Maraithon.LLM` keeps chat providers swappable:
  the concrete implementation is resolved from application config
  (`config :maraithon, Maraithon.Transcription`) instead of being hard-coded,
  so a different provider can be dropped in without touching call sites.
  """

  @callback transcribe(audio :: binary(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Transcribes an audio binary to text using the configured provider.

  `opts` may include `:filename` and `:content_type`, used by providers that
  need to describe the upload (e.g. multipart form fields).
  """
  @spec transcribe(binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(audio, opts \\ []) when is_binary(audio) and is_list(opts) do
    provider().transcribe(audio, opts)
  end

  @doc """
  True when the configured provider reports itself as ready to transcribe
  (e.g. has an API key configured).
  """
  @spec configured? :: boolean()
  def configured? do
    module = provider()
    # `function_exported?/3` reports false for a module that hasn't been
    # loaded into the VM yet (as opposed to one that genuinely lacks the
    # function) — ensure it's loaded first so this check is meaningful the
    # first time it runs in a given process.
    Code.ensure_loaded(module)

    if function_exported?(module, :configured?, 0) do
      module.configured?()
    else
      true
    end
  end

  @doc false
  def provider do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:provider, Maraithon.Transcription.OpenAIWhisper)
  end
end
