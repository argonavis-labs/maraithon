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
end
