defmodule MaraithonWeb.SettingsControllerTest do
  use MaraithonWeb.ConnCase, async: false

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
    end)

    :ok
  end

  test "settings shows provider key status without exposing the key", %{conn: conn} do
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

    assert html =~ "Assistant provider"
    assert html =~ "OpenRouter"
    assert html =~ "Provider key"
    assert html =~ "Configured"
    refute html =~ secret
    refute html =~ "OPENROUTER_API_KEY"
  end
end
