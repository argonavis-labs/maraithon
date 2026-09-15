defmodule MaraithonWeb.SettingsController do
  use MaraithonWeb, :controller

  alias Maraithon.Accounts
  alias Maraithon.CalendarLinks

  def index(conn, params) do
    render_settings(conn, assistant_settings_params: params)
  end

  def accounts(conn, _params) do
    render(conn, :accounts, page_title: "Account settings", current_path: ~p"/settings/accounts",
      current_user: conn.assigns.current_user,
      accounts: Maraithon.AccountCategories.list(conn.assigns.current_user.id))
  end

  def update_account_category(conn, %{"id" => id, "category" => category}) do
    result = with {id, ""} <- Integer.parse(id),
      do: Maraithon.AccountCategories.update(conn.assigns.current_user.id, id, category)
    conn = case result do
      {:ok, _} -> put_flash(conn, :info, "Account category saved.")
      _ -> put_flash(conn, :error, "Account category could not be saved.")
    end
    redirect(conn, to: ~p"/settings/accounts")
  end

  def assistant(conn, params) do
    render(conn, :assistant,
      page_title: "Assistant settings",
      current_path: ~p"/settings/assistant",
      current_user: conn.assigns.current_user,
      assistant_settings: MaraithonWeb.AssistantSettings.load(conn.assigns.current_user.id, params)
    )
  end

  def update_assistant_identity(conn, %{"assistant_identity" => attrs}),
    do: save_delegation_settings(conn, &MaraithonWeb.AssistantSettings.save_identity(&1, attrs))

  def update_delegation_preferences(conn, %{"delegation_preferences" => attrs}),
    do: save_delegation_settings(conn, &MaraithonWeb.AssistantSettings.save_preferences(&1, attrs))

  defp save_delegation_settings(conn, save) do
    result = case conn.assigns[:current_user] do
      %{id: id} -> save.(id)
      _ -> {:error, :not_signed_in}
    end
    conn = case result do
      {:ok, _} -> put_flash(conn, :info, "Assistant settings saved.")
      {:error, reason} -> put_flash(conn, :error, MaraithonWeb.DelegationCopy.error(reason))
    end
    redirect(conn, to: ~p"/settings/assistant")
  end

  def update_calendar_links(conn, %{"calendar_links" => %{"links" => links}}) do
    case settings_user(conn) do
      %{id: user_id} ->
        case CalendarLinks.replace_user_links(user_id, links) do
          {:ok, _links} ->
            conn
            |> put_flash(:info, "Calendar links saved.")
            |> redirect(to: ~p"/settings#calendar-links")

          {:error, reason} ->
            conn
            |> put_flash(:error, CalendarLinks.changeset_error_message(reason))
            |> render_settings(calendar_link_rows: CalendarLinks.settings_rows_from_params(links))
        end

      nil ->
        conn
        |> put_flash(:error, "Sign in as a workspace user before saving calendar links.")
        |> redirect(to: ~p"/settings#calendar-links")
    end
  end

  def update_calendar_links(conn, _params) do
    conn
    |> put_flash(:error, "Calendar links could not be saved.")
    |> redirect(to: ~p"/settings#calendar-links")
  end

  def update_assistant_model(conn, %{"assistant_model" => %{"model" => model}}) do
    case settings_user(conn) do
      %Accounts.User{} = user ->
        case Accounts.update_assistant_model(user, model) do
          {:ok, updated} ->
            conn
            |> put_flash(:info, assistant_model_saved_message(updated.assistant_model))
            |> redirect(to: ~p"/settings#assistant-model")

          {:error, _changeset} ->
            conn
            |> put_flash(
              :error,
              "That model id is not valid. Use a provider id such as meta/muse-spark-1.3-contributor."
            )
            |> redirect(to: ~p"/settings#assistant-model")
        end

      nil ->
        conn
        |> put_flash(:error, "Sign in as a workspace user before choosing a model.")
        |> redirect(to: ~p"/settings#assistant-model")
    end
  end

  def update_assistant_model(conn, _params) do
    conn
    |> put_flash(:error, "The model could not be saved.")
    |> redirect(to: ~p"/settings#assistant-model")
  end

  defp assistant_model_saved_message(nil),
    do: "Assistant model cleared. Maraithon uses the workspace default again."

  defp assistant_model_saved_message(model),
    do: "Assistant model set to #{model}. New chats, briefs, and check-ins use it from now on."

  defp render_settings(conn, extra_assigns) do
    current_user = conn.assigns.current_user
    settings_user = settings_user(conn)

    render(
      conn,
      :index,
      [
        page_title: "Settings",
        current_path: ~p"/settings",
        current_user: current_user,
        runtime_items: runtime_items(),
        security_items: security_items(),
        oauth_items: oauth_items(),
        settings_user: settings_user,
        assistant_model: settings_user && settings_user.assistant_model,
        assistant_settings: if(current_user, do: MaraithonWeb.AssistantSettings.load(current_user.id, Keyword.get(extra_assigns, :assistant_settings_params, %{})), else: %{enabled: false}),
        default_model: Maraithon.LLM.chat_model() || "not configured",
        calendar_link_rows:
          Keyword.get_lazy(extra_assigns, :calendar_link_rows, fn ->
            if settings_user do
              CalendarLinks.settings_rows(settings_user.id)
            else
              []
            end
          end)
      ] ++ extra_assigns
    )
  end

  defp settings_user(conn), do: conn.assigns[:current_user] || primary_admin_user()

  defp primary_admin_user do
    case Accounts.primary_admin_email() do
      nil -> nil
      email -> Accounts.get_user_by_email(email)
    end
  end

  defp runtime_items do
    runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    assistant_engine = Keyword.get(runtime, :llm_provider_name, "unconfigured")

    [
      %{name: "Workspace URL", value: MaraithonWeb.Endpoint.url()},
      %{name: "Assistant service", value: assistant_engine_label(assistant_engine)},
      %{
        name: "Assistant access",
        value: assistant_access_status(runtime, assistant_engine)
      },
      %{
        name: "Response engine",
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
        description: "Primary sign-in account for workspace administration.",
        required?: true,
        present?: present?(System.get_env("PRIMARY_ADMIN_EMAIL", ""))
      },
      %{
        name: "Sign-in email service",
        description: "Sends login links and account notifications.",
        required?: true,
        present?: present?(System.get_env("POSTMARK_SERVER_TOKEN", ""))
      },
      %{
        name: "Magic link sender",
        description: "Sets the sender shown on sign-in messages.",
        required?: true,
        present?: present?(System.get_env("AUTH_EMAIL_FROM", ""))
      },
      %{
        name: "Trusted access",
        description: "Lets approved companion apps and automations connect securely.",
        required?: true,
        present?: present?(Keyword.get(api_auth, :bearer_token))
      },
      %{
        name: "Backup admin username",
        description: "Optional fallback sign-in for emergency access.",
        required?: false,
        present?: present?(Keyword.get(admin_auth, :username))
      },
      %{
        name: "Backup admin password",
        description: "Required only when fallback admin sign-in is enabled.",
        required?: false,
        present?: present?(Keyword.get(admin_auth, :password))
      },
      %{
        name: "Encryption key",
        description: "Protects synced local source data at rest.",
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
  defp assistant_engine_label("unconfigured"), do: "Needs engine"
  defp assistant_engine_label(nil), do: "Needs engine"
  defp assistant_engine_label(""), do: "Needs engine"
  defp assistant_engine_label(_other), do: "Custom engine"

  defp assistant_access_status(_runtime, "mock"), do: "Local test engine"
  defp assistant_access_status(_runtime, "unconfigured"), do: "Needs access"
  defp assistant_access_status(_runtime, nil), do: "Needs access"
  defp assistant_access_status(_runtime, ""), do: "Needs access"

  defp assistant_access_status(runtime, "openai"),
    do: key_status(Keyword.get(runtime, :openai_api_key) || Keyword.get(runtime, :llm_api_key))

  defp assistant_access_status(runtime, "openrouter"),
    do:
      key_status(Keyword.get(runtime, :openrouter_api_key) || Keyword.get(runtime, :llm_api_key))

  defp assistant_access_status(runtime, "anthropic"),
    do: key_status(Keyword.get(runtime, :anthropic_api_key) || Keyword.get(runtime, :llm_api_key))

  defp assistant_access_status(runtime, _other),
    do: key_status(Keyword.get(runtime, :llm_api_key))

  defp key_status(value), do: if(present?(value), do: "Ready", else: "Needs access")

  defp reasoning_profile(runtime, "openai"),
    do: analysis_depth(Keyword.get(runtime, :openai_reasoning_effort))

  defp reasoning_profile(runtime, "openrouter"),
    do: analysis_depth(Keyword.get(runtime, :openrouter_reasoning_effort))

  defp reasoning_profile(_runtime, "anthropic"), do: "Default"
  defp reasoning_profile(_runtime, _engine), do: "Not set"

  defp analysis_depth(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> "Not set"
      "low" -> "Fast"
      "minimal" -> "Fast"
      "medium" -> "Standard"
      "standard" -> "Standard"
      "high" -> "Deep"
      "deep" -> "Deep"
      _other -> "Custom"
    end
  end

  defp analysis_depth(nil), do: "Not set"
  defp analysis_depth(_value), do: "Custom"

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
