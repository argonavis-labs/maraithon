defmodule Maraithon.TelegramAssistant.SecretRequestGuard do
  @moduledoc false

  @credential_terms ~r/\b(api\s*key|apikey|access\s*key|private\s*key|bearer\s*token|refresh\s*token|access\s*token|token|secret|password|credential|credentials)\b/i
  @disclosure_terms ~r/\b(what'?s|what\s+is|show|send|give|display|print|tell|paste|copy|reveal|read|share)\b/i

  @providers [
    %{
      id: "openrouter",
      label: "OpenRouter",
      pattern: ~r/\bopen\s*router\b|\bopenrouter\b/i,
      keys: [:openrouter_api_key]
    },
    %{
      id: "openai",
      label: "OpenAI",
      pattern: ~r/\bopen\s*ai\b|\bopenai\b/i,
      keys: [:openai_api_key]
    },
    %{
      id: "anthropic",
      label: "Anthropic",
      pattern: ~r/\banthropic\b|\bclaude\b/i,
      keys: [:anthropic_api_key]
    }
  ]

  def reply(attrs) when is_map(attrs) do
    attrs
    |> Map.get(:text, Map.get(attrs, "text"))
    |> response(runtime_config())
  end

  def response(text, runtime \\ runtime_config())

  def response(text, runtime) when is_binary(text) and is_list(runtime) do
    if disclosure_request?(text) do
      provider = provider_for(text, runtime)
      configured? = credentials_configured?(provider, runtime)

      {:ok, response_text(provider, configured?),
       %{
         "reason" => "credential_disclosure_request",
         "provider" => provider_id(provider),
         "credential_status" => credential_status(configured?)
       }}
    else
      :pass
    end
  end

  def response(_text, _runtime), do: :pass

  def disclosure_request?(text) when is_binary(text) do
    Regex.match?(@disclosure_terms, text) and secret_reference?(text)
  end

  def disclosure_request?(_text), do: false

  defp secret_reference?(text) do
    Regex.match?(@credential_terms, text) or
      (provider_mentioned?(text) and Regex.match?(~r/\bkey\b/i, text))
  end

  defp provider_mentioned?(text) do
    Enum.any?(@providers, &Regex.match?(&1.pattern, text))
  end

  defp provider_for(text, runtime) do
    Enum.find(@providers, &Regex.match?(&1.pattern, text)) || active_provider(runtime)
  end

  defp active_provider(runtime) do
    provider_name = runtime |> Keyword.get(:llm_provider_name) |> normalize_provider_name()
    Enum.find(@providers, &(&1.id == provider_name))
  end

  defp credentials_configured?(nil, runtime) do
    present?(Keyword.get(runtime, :llm_api_key)) or
      Enum.any?(@providers, fn provider ->
        Enum.any?(provider.keys, &(runtime |> Keyword.get(&1) |> present?()))
      end)
  end

  defp credentials_configured?(provider, runtime) do
    provider_specific? =
      Enum.any?(provider.keys, &(runtime |> Keyword.get(&1) |> present?()))

    active_provider? =
      runtime
      |> Keyword.get(:llm_provider_name)
      |> normalize_provider_name()
      |> Kernel.==(provider.id)

    provider_specific? or (active_provider? and present?(Keyword.get(runtime, :llm_api_key)))
  end

  defp response_text(nil, true) do
    "Provider credentials are configured for this environment. I won't display API keys, tokens, passwords, or other credentials in chat. Rotate or update them from deployment secrets or Settings."
  end

  defp response_text(nil, false) do
    "Provider credentials do not look configured in this environment. I still won't display API keys, tokens, passwords, or other credentials in chat. Add or rotate them from deployment secrets or Settings."
  end

  defp response_text(%{label: label}, true) do
    "#{label} is configured for this environment. I won't display API keys, tokens, passwords, or other credentials in chat. Rotate or update it from deployment secrets or Settings."
  end

  defp response_text(%{label: label}, false) do
    "#{label} does not look configured in this environment. I still won't display API keys, tokens, passwords, or other credentials in chat. Add or rotate it from deployment secrets or Settings."
  end

  defp credential_status(true), do: "configured"
  defp credential_status(false), do: "not_configured"

  defp provider_id(nil), do: nil
  defp provider_id(%{id: id}), do: id

  defp normalize_provider_name(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
    |> case do
      "openrouter" -> "openrouter"
      "openai" -> "openai"
      "anthropic" -> "anthropic"
      _ -> nil
    end
  end

  defp normalize_provider_name(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp runtime_config do
    Application.get_env(:maraithon, Maraithon.Runtime, [])
  end
end
