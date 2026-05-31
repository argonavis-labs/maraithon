defmodule MaraithonWeb.SettingsControllerTest do
  use MaraithonWeb.ConnCase, async: false

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
    end)

    :ok
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
    refute html =~ "Service access"
    refute html =~ "protected API endpoints"
    refute html =~ "App secret"
    refute html =~ "Return URL"
    refute html =~ "POSTMARK_SERVER_TOKEN"
    refute html =~ "AUTH_EMAIL_FROM"
    refute html =~ "API_BEARER_TOKEN"
    refute html =~ "CLOAK_KEY"
    refute html =~ "ADMIN_PASSWORD"
  end
end
