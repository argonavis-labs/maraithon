defmodule MaraithonWeb.SettingsController do
  use MaraithonWeb, :controller

  def index(conn, _params) do
    render(conn, :index,
      page_title: "Settings",
      current_path: ~p"/settings",
      current_user: conn.assigns.current_user,
      runtime_items: runtime_items(),
      security_items: security_items(),
      oauth_items: oauth_items()
    )
  end

  defp runtime_items do
    runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    assistant_engine = Keyword.get(runtime, :llm_provider_name, "unconfigured")

    [
      %{name: "Workspace URL", value: MaraithonWeb.Endpoint.url()},
      %{name: "Assistant provider", value: assistant_engine_label(assistant_engine)},
      %{
        name: "Response quality",
        value: configured_value(Keyword.get(runtime, :llm_model))
      },
      %{
        name: "Analysis depth",
        value: reasoning_profile(runtime, assistant_engine)
      },
      %{
        name: "Action window",
        value: format_duration(Keyword.get(runtime, :tool_timeout_ms, 0))
      },
      %{
        name: "Check-in cadence",
        value: format_duration(Keyword.get(runtime, :heartbeat_interval_ms, 0))
      }
    ]
  end

  defp security_items do
    admin_auth = Application.get_env(:maraithon, :admin_auth, [])
    api_auth = Application.get_env(:maraithon, :api_auth, [])

    [
      %{
        name: "Account owner email",
        key: "PRIMARY_ADMIN_EMAIL",
        required?: true,
        present?: present?(System.get_env("PRIMARY_ADMIN_EMAIL", ""))
      },
      %{
        name: "Sign-in email service",
        key: "POSTMARK_SERVER_TOKEN",
        required?: true,
        present?: present?(System.get_env("POSTMARK_SERVER_TOKEN", ""))
      },
      %{
        name: "Magic link sender",
        key: "AUTH_EMAIL_FROM",
        required?: true,
        present?: present?(System.get_env("AUTH_EMAIL_FROM", ""))
      },
      %{
        name: "Service access",
        key: "API_BEARER_TOKEN",
        required?: true,
        present?: present?(Keyword.get(api_auth, :bearer_token))
      },
      %{
        name: "Backup admin username",
        key: "ADMIN_USERNAME",
        required?: false,
        present?: present?(Keyword.get(admin_auth, :username))
      },
      %{
        name: "Backup admin password",
        key: "ADMIN_PASSWORD",
        required?: false,
        present?: present?(Keyword.get(admin_auth, :password))
      },
      %{
        name: "Encryption key",
        key: "CLOAK_KEY",
        required?: true,
        present?: present?(Application.get_env(:maraithon, Maraithon.Vault)[:ciphers])
      }
    ]
  end

  defp oauth_items do
    [
      oauth_item(
        "Google",
        Application.get_env(:maraithon, :google, []),
        :client_id,
        :client_secret
      ),
      oauth_item(
        "GitHub",
        Application.get_env(:maraithon, :github, []),
        :client_id,
        :client_secret
      ),
      oauth_item(
        "Linear",
        Application.get_env(:maraithon, :linear, []),
        :client_id,
        :client_secret
      ),
      oauth_item(
        "Slack",
        Application.get_env(:maraithon, :slack, []),
        :client_id,
        :client_secret
      ),
      oauth_item(
        "Notion",
        Application.get_env(:maraithon, :notion, []),
        :client_id,
        :client_secret
      ),
      oauth_item(
        "Notaui",
        Application.get_env(:maraithon, :notaui, []),
        :client_id,
        :client_secret
      )
    ]
  end

  defp oauth_item(name, config, client_key, secret_key) do
    %{
      name: name,
      client_id_present?: present?(Keyword.get(config, client_key)),
      client_secret_present?: present?(Keyword.get(config, secret_key)),
      redirect_uri: Keyword.get(config, :redirect_uri, "")
    }
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(value), do: not is_nil(value)

  defp assistant_engine_label("openai"), do: "OpenAI"
  defp assistant_engine_label("openrouter"), do: "OpenRouter"
  defp assistant_engine_label("anthropic"), do: "Anthropic"
  defp assistant_engine_label("mock"), do: "Local test engine"
  defp assistant_engine_label("unconfigured"), do: "Setup needed"
  defp assistant_engine_label(nil), do: "Setup needed"
  defp assistant_engine_label(""), do: "Setup needed"
  defp assistant_engine_label(_other), do: "Custom engine"

  defp reasoning_profile(runtime, "openai"),
    do: setting_value(Keyword.get(runtime, :openai_reasoning_effort))

  defp reasoning_profile(runtime, "openrouter"),
    do: setting_value(Keyword.get(runtime, :openrouter_reasoning_effort))

  defp reasoning_profile(_runtime, "anthropic"), do: "Default"
  defp reasoning_profile(_runtime, _engine), do: "Not set"

  defp setting_value(value) when is_binary(value) do
    if String.trim(value) == "", do: "Not set", else: value
  end

  defp setting_value(nil), do: "Not set"
  defp setting_value(value), do: to_string(value)

  defp configured_value(value) when is_binary(value) do
    if String.trim(value) == "", do: "Not set", else: "Ready"
  end

  defp configured_value(nil), do: "Not set"
  defp configured_value(_value), do: "Ready"

  defp format_duration(ms) when is_integer(ms) and ms > 0 do
    cond do
      rem(ms, :timer.minutes(1)) == 0 ->
        count = div(ms, :timer.minutes(1))
        "#{count} #{ngettext("minute", "minutes", count)}"

      rem(ms, :timer.seconds(1)) == 0 ->
        count = div(ms, :timer.seconds(1))
        "#{count} #{ngettext("second", "seconds", count)}"

      true ->
        "#{ms} ms"
    end
  end

  defp format_duration(_ms), do: "Not set"
end
