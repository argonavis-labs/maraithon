defmodule MaraithonWeb.AgentLibraryLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @user_email "library@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "renders template detail without setup jargon", %{conn: conn} do
    {:ok, view, html} = live(conn, "/agents/library/ai_chief_of_staff")

    assert has_element?(view, "h1", "Chief of Staff")
    assert html =~ "Built-in template"
    assert html =~ "Install it with recommended defaults."
    assert html =~ "fine-tune scope, cadence, and delivery"
    refute html =~ "spin it up"
    refute html =~ "prompt and budgets"
  end

  test "project manager template uses review-focused copy", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/agents/library/github_product_planner")

    assert html =~ "recommends the next 2-3 tickets"
    assert html =~ "New project tasks and ticket notes ready for review"
    refute html =~ "task surface"
    refute html =~ "project-memory"
    refute html =~ "Durable todos"
    refute html =~ "PM loop"
    refute html =~ "Telegram-ready"
  end

  test "engineering templates avoid runtime host language", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/agents/library/codebase_advisor")

    assert html =~ "which files are reviewed"
    assert html =~ "slower check interval for large repositories"
    refute html =~ "runtime host"
    refute html =~ "Primary artifact"
  end
end
