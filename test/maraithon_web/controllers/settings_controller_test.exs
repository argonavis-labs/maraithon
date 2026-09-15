defmodule MaraithonWeb.SettingsControllerTest do
  use MaraithonWeb.ConnCase, async: false

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
    end)

    :ok
  end

  test "a non-admin can manage only their own assistant settings", %{conn: conn} do
    user = "assistant-settings@example.invalid"
    other = "other-settings@example.invalid"
    conn = log_in_test_user(conn, user)
    {:ok, _} = Maraithon.Accounts.get_or_create_user_by_email(other)
    keys = [:delegations_enabled, :delegation_user_allowlist]
    previous = Map.new(keys, &{&1, Application.fetch_env(:maraithon, &1)})
    Application.put_env(:maraithon, :delegations_enabled, true)
    Application.put_env(:maraithon, :delegation_user_allowlist, [user])

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:maraithon, key, value)
        {key, :error} -> Application.delete_env(:maraithon, key)
      end)
    end)

    page = get(conn, "/settings/assistant")
    html = html_response(page, 200)
    assert html =~ "Connect your assistant"
    assert html =~ "/settings/assistant"
    refute html =~ "Assistant readiness"
    refute html =~ "Private access"

    saved =
      post(recycle(page), "/settings/delegation-preferences", %{
        "user_id" => other,
        "delegation_preferences" => %{"default_duration_min" => "45"}
      })

    assert redirected_to(saved) == "/settings/assistant"
    assert Maraithon.Delegations.Preferences.get(user)["default_duration_min"] == 45
    refute Maraithon.Delegations.Preferences.get(other)["default_duration_min"] == 45

    protected = get(recycle(saved), "/settings")
    assert redirected_to(protected) == "/dashboard"
  end

  test "assistant settings require a signed-in user", %{conn: conn} do
    assert redirected_to(get(conn, "/settings/assistant")) == "/"
    assert redirected_to(post(conn, "/settings/delegation-preferences", %{})) == "/"
  end

  test "settings shows assistant access status without exposing the key", %{conn: conn} do
    secret = "sk-or-secret-openrouter-key"

    Application.put_env(:maraithon, Maraithon.Runtime,
      llm_provider_name: "openrouter",
      llm_model: "qwen/qwen3.7-max",
      llm_api_key: secret,
      openrouter_api_key: secret,
      openrouter_reasoning_effort: "medium"
    )

    conn =
      conn
      |> log_in_admin_user("settings-openrouter@example.com")
      |> get("/settings")

    html = html_response(conn, 200)

    assert html =~ "Assistant service"
    assert html =~ "OpenRouter"
    assert html =~ "Assistant access"
    assert html =~ "Ready"
    assert html =~ "Standard"
    refute html =~ "Provider key"
    refute html =~ secret
    refute html =~ "OPENROUTER_API_KEY"
  end

  test "settings readiness copy avoids deployment internals", %{conn: conn} do
    conn =
      conn
      |> log_in_admin_user("settings-copy@example.com")
      |> get("/settings")

    html = html_response(conn, 200)

    assert html =~ "Sends login links and account notifications."
    assert html =~ "Trusted access"
    assert html =~ "Lets approved companion apps and automations connect securely."
    assert html =~ "Protects synced local source data at rest."
    assert html =~ "readiness"
    assert html =~ "App identity"
    assert html =~ "Private access"
    assert html =~ "Return link"
    assert html =~ "Needs engine"
    assert html =~ "Needs access"
    assert html =~ "needs attention"
    refute html =~ "Service access"
    refute html =~ "protected API endpoints"
    refute html =~ "App secret"
    refute html =~ "Return URL"
    refute html =~ "Setup needed"
    refute html =~ "needs setup"
    refute html =~ "POSTMARK_SERVER_TOKEN"
    refute html =~ "AUTH_EMAIL_FROM"
    refute html =~ "API_BEARER_TOKEN"
    refute html =~ "CLOAK_KEY"
    refute html =~ "ADMIN_PASSWORD"
  end
end
